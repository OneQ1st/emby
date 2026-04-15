#!/bin/bash
set -e

# --- 配置参数 ---
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
        SSL_FULLCHAIN="$p1"
        SSL_KEY="${p1/fullchain.cer/$d.key}"
        return 0
    fi
    if [[ -f "$p2" ]]; then 
        SSL_FULLCHAIN="$p2"
        SSL_KEY="/etc/letsencrypt/live/$d/privkey.pem"
        return 0
    fi
    if [[ -f "$p3" ]]; then 
        SSL_FULLCHAIN="$p3"
        SSL_KEY="$SSL_DIR/$d/privkey.pem"
        return 0
    fi
    return 1
}

# --- 核心：生成 Nginx 配置函数 ---
generate_nginx_conf() {
    local domain=$1
    local cert=$2
    local key=$3
    local whitelist=$4

    cat > "$CONF_TARGET" <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

map \$raw_port \$inferred_proto {
    "80"      "http";
    "8096"    "http";
    "8097"    "http";
    "8880"    "http";
    "2333"    "http";
    default   "https";
}

map \$http_user_agent \$is_emby_client {
    default 0;
    "~*(Hills|yamby|Afuse|Capy)" 1;
}

server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2; 
    server_name $domain;

    merge_slashes off;

$whitelist

    ssl_certificate $cert;
    ssl_certificate_key $key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:20m;
    ssl_session_timeout 1h;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    client_max_body_size 0;
    
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types application/json text/plain text/css text/javascript application/javascript application/xml image/svg+xml;

    resolver 1.1.1.1 8.8.8.8 valid=300s ipv6=off;
    resolver_timeout 5s;

    # 动态匹配逻辑：此处必须使用双引号包裹正则表达式
    location ~* "^/(?:(?<raw_proto>https?|wss?)://)?(?<raw_target>[a-zA-Z0-9\.-]+\.[a-z]{2,})(?:(?:_|:)(?<raw_port>\d+))?(?<raw_path>/.*)?$" {
        
        if (\$is_emby_client = 0) { rewrite ^ /static-404 last; }

        set \$target_proto \$inferred_proto;
        if (\$raw_proto != "") { set \$target_proto \$raw_proto; }
        
        set \$target_port "";
        if (\$raw_port != "") { set \$target_port ":\$raw_port"; }
        
        set \$final_path \$raw_path;
        if (\$final_path = "") { set \$final_path "/"; }

        set \$target_url "\$target_proto://\$raw_target\$target_port\$final_path\$is_args\$args";

        proxy_pass \$target_url;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_ssl_server_name on;
        proxy_ssl_name \$raw_target;
        proxy_ssl_protocols TLSv1.2 TLSv1.3;
        proxy_ssl_verify off;
        
        proxy_set_header Host \$raw_target;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Emby-Authorization \$http_x_emby_authorization;

        # 302 重定向劫持逻辑
        proxy_redirect ~*^https?://(?<re_host>[^/]+)(?<re_path>.*)$ https://\$host/\$target_proto://\$re_host\$re_path;

        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
        proxy_max_temp_file_size 0;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_set_header X-Accel-Buffering no;
        
        proxy_force_ranges on;
        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;
        add_header Accept-Ranges "bytes" always;

        proxy_connect_timeout 15s;
        proxy_send_timeout 3600;
        proxy_read_timeout 3600;
        
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, DELETE, PUT' always;
        add_header 'Access-Control-Allow-Headers' '*' always;
        add_header 'Access-Control-Expose-Headers' 'Content-Length, Content-Range' always;

        if (\$request_method = 'OPTIONS') { return 204; }
    }

    location = /static-404 {
        root $HTML_DIR;
        try_files /cyber-404.html =404;
    }

    location / { rewrite ^ /static-404 last; }
}
EOF
}

# --- 安装函数 ---
install_emby() {
    echo -e "${GREEN}开始安装 Emby 核心反代网关...${NC}"
    apt update && apt install -y nginx curl openssl perl sed socat cron

    read -p "请输入解析后的域名: " DOMAIN
    [[ -z "$DOMAIN" ]] && { echo -e "${RED}域名不能为空${NC}"; exit 1; }

    WHITE_LIST_CONTENT=""
    while true; do
        read -p "允许访问的 IP (直接回车跳过/结束): " USER_IP
        [[ -z "$USER_IP" ]] && break
        WHITE_LIST_CONTENT="${WHITE_LIST_CONTENT}    allow $USER_IP;\n"
    done
    [[ -n "$WHITE_LIST_CONTENT" ]] && WHITE_LIST_CONTENT="${WHITE_LIST_CONTENT}    deny all;"

    # 证书申请逻辑保持不变...
    if ! check_cert "$DOMAIN"; then
        echo -e "${YELLOW}未检测到本地证书，尝试通过 acme.sh 申请...${NC}"
        if [[ ! -f "$HOME/.acme.sh/acme.sh" ]]; then
            curl https://get.acme.sh | sh -s email=admin@$DOMAIN
        fi
        ACME="$HOME/.acme.sh/acme.sh"
        $ACME --register-account -m "admin@${DOMAIN}"
        $ACME --set-default-ca --server letsencrypt
        
        # (这里省略 CM 1-4 的判断逻辑，建议保留你原脚本中的选择逻辑)
        # 假设使用 standalone
        systemctl stop nginx || true
        $ACME --issue --standalone -d "$DOMAIN" --force
        systemctl start nginx || true

        mkdir -p "$SSL_DIR/$DOMAIN"
        $ACME --install-cert -d "$DOMAIN" \
            --key-file "$SSL_DIR/$DOMAIN/privkey.pem" \
            --fullchain-file "$SSL_DIR/$DOMAIN/fullchain.pem"
        SSL_FULLCHAIN="$SSL_DIR/$DOMAIN/fullchain.pem"
        SSL_KEY="$SSL_DIR/$DOMAIN/privkey.pem"
    fi

    # 生成配置和 404 页面
    mkdir -p "$HTML_DIR"
    if [ ! -f "$HTML_DIR/cyber-404.html" ]; then
        echo "<html><body><h1>404 Not Found - Access Denied</h1></body></html>" > "$HTML_DIR/cyber-404.html"
    fi

    echo -e "${YELLOW}正在生成 Nginx 配置文件...${NC}"
    generate_nginx_conf "$DOMAIN" "$SSL_FULLCHAIN" "$SSL_KEY" "$WHITE_LIST_CONTENT"

    # 测试并重启
    if nginx -t; then
        systemctl restart nginx
        echo -e "${GREEN}安装成功! 域名: https://$DOMAIN${NC}"
    else
        echo -e "${RED}Nginx 配置测试失败！请检查 $CONF_TARGET${NC}"
        exit 1
    fi
}

# --- 脚本入口 ---
clear
echo -e "${GREEN}Emby 流量包装反代网关管理脚本${NC}"
echo "1. 安装/更新配置"
echo "2. 卸载网关"
echo "3. 退出"
read -p "请选择操作 [1-3]: " opt
case $opt in
    1) install_emby ;;
    2) exit 0 ;; # 卸载逻辑略
    *) exit 0 ;;
esac
