#!/bin/bash
set -e

# --- 基础参数 ---
SSL_DIR="/etc/nginx/ssl"
CONF_TARGET="/etc/nginx/conf.d/emby.conf"
HTML_DIR="/var/www/emby-404"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 证书检查函数 ---
check_cert() {
    local d=$1
    local p1="$HOME/.acme.sh/${d}_ecc/fullchain.cer"
    local p2="/etc/letsencrypt/live/$d/fullchain.pem"
    local p3="$SSL_DIR/$d/fullchain.pem"
    
    if [[ -f "$p1" ]]; then 
        SSL_FULLCHAIN="$p1"; SSL_KEY="${p1/fullchain.cer/$d.key}"; return 0
    fi
    if [[ -f "$p2" ]]; then 
        SSL_FULLCHAIN="$p2"; SSL_KEY="/etc/letsencrypt/live/$d/privkey.pem"; return 0
    fi
    if [[ -f "$p3" ]]; then 
        SSL_FULLCHAIN="$p3"; SSL_KEY="$SSL_DIR/$d/privkey.pem"; return 0
    fi
    return 1
}

# --- 卸载函数 ---
uninstall_emby() {
    echo -e "${YELLOW}正在卸载 Emby 网关...${NC}"
    rm -f "$CONF_TARGET"
    rm -rf "$HTML_DIR"
    systemctl restart nginx && echo -e "${GREEN}卸载完成。${NC}"
}

# --- 安装函数 ---
install_emby() {
    echo -e "${GREEN}开始安装 Emby 核心反代网关...${NC}"
    apt update && apt install -y nginx curl openssl perl sed socat cron

    read -p "请输入解析后的域名: " DOMAIN
    [[ -z "$DOMAIN" ]] && { echo -e "${RED}域名不能为空${NC}"; exit 1; }

    # 白名单处理
    WHITE_LIST_CONTENT=""
    while true; do
        read -p "允许访问的 IP (直接回车跳过/结束): " USER_IP
        [[ -z "$USER_IP" ]] && break
        WHITE_LIST_CONTENT="${WHITE_LIST_CONTENT}    allow $USER_IP;\n"
    done
    [[ -n "$WHITE_LIST_CONTENT" ]] && WHITE_LIST_CONTENT="${WHITE_LIST_CONTENT}    deny all;"

    # 证书申请 (acme.sh 逻辑保持)
    if ! check_cert "$DOMAIN"; then
        echo -e "${YELLOW}尝试申请证书...${NC}"
        [[ ! -f "$HOME/.acme.sh/acme.sh" ]] && curl https://get.acme.sh | sh -s email=admin@$DOMAIN
        ACME="$HOME/.acme.sh/acme.sh"
        $ACME --set-default-ca --server letsencrypt
        systemctl stop nginx || true
        $ACME --issue --standalone -d "$DOMAIN" --force
        systemctl start nginx || true
        mkdir -p "$SSL_DIR/$DOMAIN"
        $ACME --install-cert -d "$DOMAIN" --key-file "$SSL_DIR/$DOMAIN/privkey.pem" --fullchain-file "$SSL_DIR/$DOMAIN/fullchain.pem"
        SSL_FULLCHAIN="$SSL_DIR/$DOMAIN/fullchain.pem"; SSL_KEY="$SSL_DIR/$DOMAIN/privkey.pem"
    fi

    # 生成 404 页面
    mkdir -p "$HTML_DIR"
    echo "<html><body style='background:#000;color:#0f0;text-align:center;padding-top:20%'><h1>404 ACCESS DENIED</h1><p>Emby Proxy Gateway</p></body></html>" > "$HTML_DIR/cyber-404.html"

    # ========================================================================
    # 核心：生成 Nginx 配置文件 (采用 'EOF' 避免变量提前解析)
    # ========================================================================
    echo -e "${YELLOW}正在生成高兼容性配置文件...${NC}"
    
    cat > "$CONF_TARGET" << 'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

map $raw_port $inferred_proto {
    "80"      "http";
    "8096"    "http";
    "8097"    "http";
    "8880"    "http";
    "2333"    "http";
    default   "https";
}

map $http_user_agent $is_emby_client {
    default 0;
    "~*(Hills|yamby|Afuse|Capy|Fileball|Infuse|SenPlayer|VLC|VidHub)" 1;
}

server {
    listen 80;
    server_name {{SERVER_NAME}};
    location / { return 301 https://$host$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name {{SERVER_NAME}};

    merge_slashes off;

{{WHITELIST}}

    ssl_certificate {{SSL_CERTIFICATE}};
    ssl_certificate_key {{SSL_CERTIFICATE_KEY}};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:20m;
    ssl_session_timeout 1h;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    client_max_body_size 0;

    resolver 1.1.1.1 8.8.8.8 valid=300s ipv6=off;
    resolver_timeout 5s;

    # 动态匹配正则 (带双引号，防止 PCRE2 报错)
    location ~* "^/(?:(?<raw_proto>https?|wss?)://)?(?<raw_target>[a-zA-Z0-9\.-]+)(?:(?:_|:)(?<raw_port>\d+))?(?<raw_path>/.*)?$" {
        
        if ($is_emby_client = 0) { rewrite ^ /static-404 last; }

        set $target_proto $inferred_proto;
        if ($raw_proto != "") { set $target_proto $raw_proto; }
        set $target_port "";
        if ($raw_port != "") { set $target_port ":$raw_port"; }
        set $final_path $raw_path;
        if ($final_path = "") { set $final_path "/"; }

        set $target_url "$target_proto://$raw_target$target_port$final_path$is_args$args";

        proxy_pass $target_url;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $raw_target;

        # 【核心】全自动推流重写逻辑
        proxy_set_header Accept-Encoding ""; 
        sub_filter_types application/json text/xml text/plain text/javascript;
        sub_filter_once off;
        sub_filter ':"http' ':"$scheme://$host/http';
        sub_filter '\"http' '\"$scheme://$host/http';
        sub_filter ':"https' ':"$scheme://$host/https';

        # 劫持重定向
        proxy_redirect ~*^https?://(?<re_host>[^/]+)(?<re_path>.*)$ $scheme://$host/$target_proto://$re_host$re_path;

        # SNI 与透传
        proxy_ssl_server_name on;
        proxy_ssl_name $raw_target;
        proxy_ssl_verify off;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Emby-Authorization $http_x_emby_authorization;

        # 视频传输流优化
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_set_header X-Accel-Buffering no;
        proxy_force_ranges on;
        
        # 跨域
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' '*' always;
        add_header 'Access-Control-Allow-Headers' '*' always;
        if ($request_method = 'OPTIONS') { return 204; }
    }

    location = /static-404 {
        root /var/www/emby-404;
        try_files /cyber-404.html =404;
    }

    location / { rewrite ^ /static-404 last; }
}
EOF

    # 变量替换
    sed -i "s|{{SERVER_NAME}}|$DOMAIN|g" "$CONF_TARGET"
    sed -i "s|{{SSL_CERTIFICATE}}|$SSL_FULLCHAIN|g" "$CONF_TARGET"
    sed -i "s|{{SSL_CERTIFICATE_KEY}}|$SSL_KEY|g" "$CONF_TARGET"
    perl -i -pe "s|\{\{WHITELIST\}\}|$WHITE_LIST_CONTENT|g" "$CONF_TARGET"

    # 测试并重启
    if nginx -t; then
        systemctl restart nginx
        echo -e "------------------------------------------------"
        echo -e "${GREEN}安装成功!${NC}"
        echo -e "代理域名: ${CYAN}https://$DOMAIN${NC}"
        echo -e "用法示例: https://$DOMAIN/http://你的EMBY地址:8096"
        echo -e "------------------------------------------------"
    else
        echo -e "${RED}Nginx 语法测试失败，请检查配置文件。${NC}"
        exit 1
    fi
}

# --- 入口 ---
clear
echo -e "${GREEN}Emby 全自动动态反代网关${NC}"
echo "1. 安装/更新"
echo "2. 卸载"
echo "3. 退出"
read -p "选择: " opt
case $opt in
    1) install_emby ;;
    2) uninstall_emby ;;
    *) exit 0 ;;
esac
