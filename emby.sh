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
    if [[ -f "$p1" ]]; then SSL_FULLCHAIN="$p1"; SSL_KEY="${p1/fullchain.cer/$d.key}"; return 0; fi
    if [[ -f "$p2" ]]; then SSL_FULLCHAIN="$p2"; SSL_KEY="/etc/letsencrypt/live/$d/privkey.pem"; return 0; fi
    if [[ -f "$p3" ]]; then SSL_FULLCHAIN="$p3"; SSL_KEY="$SSL_DIR/$d/privkey.pem"; return 0; fi
    return 1
}

# --- 安装函数 ---
install_emby() {
    echo -e "${GREEN}开始安装 Emby 核心反代网关...${NC}"
    # 强制安装 nginx-full 以确保包含 sub_filter 模块
    apt update && apt install -y nginx-full curl openssl perl sed socat cron

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

    # 证书处理 (简化逻辑以便展示核心)
    if ! check_cert "$DOMAIN"; then
        echo -e "${YELLOW}未检测到证书，尝试 Standalone 申请...${NC}"
        [[ ! -f "$HOME/.acme.sh/acme.sh" ]] && curl https://get.acme.sh | sh -s email=admin@$DOMAIN
        $HOME/.acme.sh/acme.sh --issue --standalone -d "$DOMAIN" --force
        mkdir -p "$SSL_DIR/$DOMAIN"
        $HOME/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$SSL_DIR/$DOMAIN/privkey.pem" --fullchain-file "$SSL_DIR/$DOMAIN/fullchain.pem"
        SSL_FULLCHAIN="$SSL_DIR/$DOMAIN/fullchain.pem"; SSL_KEY="$SSL_DIR/$DOMAIN/privkey.pem"
    fi

    mkdir -p "$HTML_DIR"
    echo "404 Unauthorized" > "$HTML_DIR/cyber-404.html"

    # ================== 核心配置注入 ==================
    cat > "$CONF_TARGET" << 'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

# 协议推断
map $raw_port $inferred_proto {
    "80"      "http";
    "8096"    "http";
    "2333"    "http";
    default   "https";
}

# 客户端白名单 (UA 增强)
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
    
    # 动态 DNS 解析
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;

    # 核心：正则表达式使用引号包裹，修复 pcre2 报错
    location ~* "^/(?:(?<raw_proto>https?|wss?)://)?(?<raw_target>[a-zA-Z0-9\.-]+)(?:(?:_|:)(?<raw_port>\d+))?(?<raw_path>/.*)?$" {
        
        if ($is_emby_client = 0) { rewrite ^ /static-404 last; }

        set $target_proto $inferred_proto;
        if ($raw_proto != "") { set $target_proto $raw_proto; }
        set $target_port "";
        if ($raw_port != "") { set $target_port ":$raw_port"; }
        set $final_path $raw_path;
        if ($final_path = "") { set $final_path "/"; }

        # --- 抓取与改写逻辑 ---
        # 1. 强制禁用 Gzip 以便 Nginx 抓取 Body
        proxy_set_header Accept-Encoding ""; 
        
        # 2. sub_filter 全自动抓取并替换域名/IP
        sub_filter_types application/json text/xml text/plain text/javascript application/javascript;
        sub_filter_once off;
        
        # 抓取响应中的各种链接并套上代理前缀
        sub_filter ':"http://' ':"$scheme://$host/http://';
        sub_filter ':"https://' ':"$scheme://$host/https://';
        sub_filter '\"http://' '\"$scheme://$host/http://';
        sub_filter '\"https://' '\"$scheme://$host/https://';
        
        # 抓取转义格式的链接 (Emby 常用)
        sub_filter 'http\:\/\/' '$scheme\:\/\/$host\/http\:\/\/';
        sub_filter 'https\:\/\/' '$scheme\:\/\/$host\/https\:\/\/';

        # 3. 劫持 302 重定向
        proxy_redirect ~*^https?://(?<re_host>[^/]+)(?<re_path>.*)$ $scheme://$host/https://$re_host$re_path;

        # 4. 反代执行
        proxy_pass $target_proto://$raw_target$target_port$final_path$is_args$args;

        # 头部透传与 SSL 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $raw_target;
        proxy_ssl_server_name on;
        proxy_ssl_name $raw_target;
        proxy_ssl_verify off;
        
        # 优化传输
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_set_header X-Accel-Buffering no;
        proxy_force_ranges on;
        
        add_header 'Access-Control-Allow-Origin' '*' always;
    }

    location = /static-404 {
        root /var/www/emby-404;
        try_files /cyber-404.html =404;
    }

    location / { rewrite ^ /static-404 last; }
}
EOF

    # 变量替换逻辑
    sed -i "s|{{SERVER_NAME}}|$DOMAIN|g" "$CONF_TARGET"
    sed -i "s|{{SSL_CERTIFICATE}}|$SSL_FULLCHAIN|g" "$CONF_TARGET"
    sed -i "s|{{SSL_CERTIFICATE_KEY}}|$SSL_KEY|g" "$CONF_TARGET"
    perl -i -pe "s|\{\{WHITELIST\}\}|$WHITE_LIST_CONTENT|g" "$CONF_TARGET"

    if nginx -t; then
        systemctl restart nginx
        echo -e "${GREEN}安装成功!${NC} 请使用: https://$DOMAIN/http://真实IP:端口"
    else
        echo -e "${RED}Nginx 配置错误${NC}"
        exit 1
    fi
}

# --- 入口 ---
clear
echo "1. 安装/更新"
echo "2. 退出"
read -p "选择: " opt
[[ "$opt" == "1" ]] && install_emby || exit 0
