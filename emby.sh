#!/bin/bash
set -e

# --- 基础定义 ---
SSL_DIR="/etc/nginx/ssl"
MAP_CONF="/etc/nginx/conf.d/emby_maps.conf"
HTML_DIR="/var/www/emby"
HTML_FILE="$HTML_DIR/emby-404.html"
GITHUB_HTML_URL="https://raw.githubusercontent.com/OneQ1st/emby/main/emby-404.html"

# --- 颜色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 权限运行${NC}" && exit 1

# --- 证书检查函数 ---
check_cert() {
    local d=$1
    local p1="$HOME/.acme.sh/${d}_ecc/fullchain.cer"
    local p2="/etc/letsencrypt/live/$d/fullchain.pem"
    local p3="$SSL_DIR/$d/fullchain.pem"
    if [[ -f "$p1" ]]; then echo "$p1" "${p1/fullchain.cer/$d.key}"; return 0; fi
    if [[ -f "$p2" ]]; then echo "$p2" "/etc/letsencrypt/live/$d/privkey.pem"; return 0; fi
    if [[ -f "$p3" ]]; then echo "$p3" "$SSL_DIR/$d/privkey.pem"; return 0; fi
    return 1
}

# --- 证书申请流程 ---
handle_ssl() {
    local DOMAIN=$1
    CERT_INFO=$(check_cert "$DOMAIN" || true)
    if [[ -z "$CERT_INFO" ]]; then
        echo -e "${YELLOW}未发现 $DOMAIN 的证书，开始申请...${NC}"
        echo "1) 独立模式 (Standalone - 占用80端口)"
        echo "2) Cloudflare Token 模式 (DNS验证)"
        read -p "选择 [1/2]: " SSL_MODE
        [[ ! -f "$HOME/.acme.sh/acme.sh" ]] && curl https://get.acme.sh | sh -s email=admin@$DOMAIN
        if [[ "$SSL_MODE" == "2" ]]; then
            [[ -z "$CF_Token" ]] && read -p "请输入 CF API Token: " CF_Token
            export CF_Token="$CF_Token"
            "$HOME/.acme.sh/acme.sh" --issue --dns dns_cf -d "$DOMAIN" --force
        else
            "$HOME/.acme.sh/acme.sh" --issue --standalone -d "$DOMAIN" --force
        fi
        mkdir -p "$SSL_DIR/$DOMAIN"
        "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" --key-file "$SSL_DIR/$DOMAIN/privkey.pem" --fullchain-file "$SSL_DIR/$DOMAIN/fullchain.pem"
        CUR_FULL="$SSL_DIR/$DOMAIN/fullchain.pem"; CUR_KEY="$SSL_DIR/$DOMAIN/privkey.pem"
    else
        echo -e "${GREEN}检测到 $DOMAIN 已存在证书。${NC}"
        CUR_FULL=$(echo $CERT_INFO | awk '{print $1}'); CUR_KEY=$(echo $CERT_INFO | awk '{print $2}')
    fi
}

# --- 初始化环境 ---
init_env() {
    apt update && apt install -y nginx-full curl openssl sed socat cron
    mkdir -p "$HTML_DIR"
    [[ ! -f "$HTML_FILE" ]] && curl -sLo "$HTML_FILE" "$GITHUB_HTML_URL"
    cat > "$MAP_CONF" << EOF
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
map \$http_user_agent \$is_emby_client {
    default 0;
    "~*(Hills|yamby|Afuse|Capy|Fileball|Infuse|SenPlayer|VLC|VidHub|Emby|Android|iOS)" 1;
}
EOF
}

# --- 1. 万能反代 (核心代码一字不动) ---
deploy_universal() {
    init_env
    read -p "请输入万能反代域名: " D_UNI
    [[ -z "$D_UNI" ]] && return
    handle_ssl "$D_UNI"
    
    local TARGET_CONF="/etc/nginx/conf.d/emby_universal.conf"
    cat > "$TARGET_CONF" << EOF
server {
    listen 80;
    listen 443 ssl http2;
    listen 40889 ssl http2;
    server_name $D_UNI;
    ssl_certificate $CUR_FULL;
    ssl_certificate_key $CUR_KEY;
    merge_slashes off;
    resolver 1.1.1.1 8.8.8.8 ipv6=off valid=300s;
    resolver_timeout 5s;
    error_page 404 /emby-404.html;
    location = /emby-404.html { root $HTML_DIR; internal; }

    location ~* "^/(?<raw_proto>https?|wss?)://(?<raw_target>[a-zA-Z0-9\.-]+)(?:[:/_](?<raw_port>\d+))?(?<raw_path>/.*)?$" {
        if (\$is_emby_client = 0) { return 403 "Unauthorized Client"; }
        set \$target_proto \$raw_proto;
        set \$target_port "";
        if (\$raw_port != "") { set \$target_port ":\$raw_port"; }
        set \$final_path \$raw_path;
        if (\$final_path = "") { set \$final_path "/"; }
        proxy_pass \$target_proto://\$raw_target\$target_port\$final_path\$is_args\$args;
        proxy_set_header Accept-Encoding ""; 
        sub_filter_types *;
        sub_filter_once off;
        sub_filter ':"http' ':"\$scheme://\$http_host/http';
        sub_filter '\"http' '\"\$scheme://\$http_host/http';
        sub_filter 'http\:\/\/' '\$scheme\:\/\/\$http_host\/http\:\/\/';
        sub_filter 'https\:\/\/' '\$scheme\:\/\/\$http_host\/https\:\/\/';
        proxy_redirect ~*^https?://(?<re_host>[^/]+)(?<re_path>.*)$ \$scheme://\$http_host/https://\$re_host\$re_path;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$raw_target;
        proxy_ssl_server_name on;
        proxy_ssl_name \$raw_target;
        proxy_ssl_verify off;
        proxy_hide_header 'Access-Control-Allow-Origin';
        proxy_hide_header 'Access-Control-Allow-Methods';
        proxy_hide_header 'Access-Control-Allow-Headers';
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, RANGE' always;
        add_header 'Access-Control-Allow-Headers' '*' always;
        add_header 'Access-Control-Expose-Headers' 'Content-Length, Content-Range' always;
        if (\$request_method = 'OPTIONS') { 
            add_header 'Access-Control-Max-Age' 1728000;
            add_header 'Content-Type' 'text/plain; charset=utf-8';
            add_header 'Content-Length' 0;
            return 204; 
        }
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_set_header X-Accel-Buffering no;
        proxy_force_ranges on;
    }
    location / { return 404; }
}
EOF
    nginx -t && systemctl restart nginx && echo -e "${GREEN}万能反代部署完成！${NC}"
}

# --- 2. 单站反代 (支持完整 URL 解析) ---
deploy_single() {
    init_env
    read -p "请输入单站反代域名: " D_SIN
    [[ -z "$D_SIN" ]] && return
    handle_ssl "$D_SIN"

    local TARGET_CONF="/etc/nginx/conf.d/emby_single.conf"
    cat > "$TARGET_CONF" << EOF
server {
    listen 80;
    listen 443 ssl http2;
    server_name $D_SIN;
    ssl_certificate $CUR_FULL;
    ssl_certificate_key $CUR_KEY;
    merge_slashes off;
    resolver 1.1.1.1 8.8.8.8 ipv6=off valid=300s;
    error_page 404 /emby-404.html;
    location = /emby-404.html { root $HTML_DIR; internal; }
EOF

    while true; do
        read -p "添加映射路径? (y/n): " YN
        [[ "$YN" != "y" ]] && break
        read -p "  路径后缀 (如 path1): " P_NAME
        read -p "  完整目标地址 (如 http://1.2.3.4:8096): " P_FULL_URL
        
        # --- 解析逻辑 ---
        # 提取协议 (默认 https)
        P_PROTO=$(echo $P_FULL_URL | grep :// | sed -e 's|://.*||')
        [[ -z "$P_PROTO" ]] && P_PROTO="https"
        
        # 提取主机部分 (域名+端口)
        P_HOST=$(echo $P_FULL_URL | sed -e 's|^.*://||' -e 's|/.*||')
        
        # 清洗 Host 用于 Header (去掉端口)
        P_PURE_HOST=$(echo $P_HOST | cut -d: -f1)

        cat >> "$TARGET_CONF" << EOF
    location ^~ /$P_NAME/ {
        proxy_pass $P_PROTO://$P_HOST/;
        proxy_set_header Host $P_PURE_HOST;
        proxy_ssl_name $P_PURE_HOST;
        proxy_ssl_server_name on;
        proxy_ssl_verify off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_hide_header 'Access-Control-Allow-Origin';
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' '*' always;
        add_header 'Access-Control-Allow-Headers' '*' always;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_force_ranges on;
    }
EOF
    done

    echo "    location / { return 404; } " >> "$TARGET_CONF"
    echo "}" >> "$TARGET_CONF"
    nginx -t && systemctl restart nginx && echo -e "${GREEN}单站反代部署完成！${NC}"
}

# --- 3. 卸载 ---
uninstall_all() {
    rm -f /etc/nginx/conf.d/emby_*.conf
    rm -rf "$HTML_DIR"
    systemctl restart nginx
    echo -e "${YELLOW}已清理所有配置。${NC}"
}

# --- 主菜单 ---
clear
echo "1) 部署 [万能动态反代]"
echo "2) 部署 [单站路径反代] (支持 HTTP/HTTPS 完整地址)"
echo "3) 卸载"
read -p "选择: " OPT
case $OPT in
    1) deploy_universal ;;
    2) deploy_single ;;
    3) uninstall_all ;;
    *) exit 0 ;;
esac
