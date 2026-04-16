#!/bin/bash
set -e

# --- 基础路径与配置 ---
SSL_DIR="/etc/nginx/ssl"
CONF_TARGET="/etc/nginx/conf.d/emby.conf"
HTML_DIR="/var/www/emby"
HTML_FILE="$HTML_DIR/emby-404.html"
GITHUB_HTML_URL="https://raw.githubusercontent.com/OneQ1st/emby/main/emby-404.html"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 权限检查 ---
[[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 权限运行${NC}" && exit 1

# --- 检查证书函数 (优先检查本地是否存在) ---
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

# --- 彻底删除函数 ---
uninstall_emby() {
    echo -e "${YELLOW}正在清理...${NC}"
    rm -f "$CONF_TARGET"
    rm -rf "$HTML_DIR"
    systemctl restart nginx
    echo -e "${GREEN}卸载完成。${NC}"
    exit 0
}

# --- 核心部署逻辑 ---
install_emby_pro() {
    apt update && apt install -y nginx-full curl openssl sed socat cron

    # 1. 域名输入
    read -p "请输入通用反代域名 (Domain A, 如 example1.domain.com): " DOMAIN_A
    read -p "请输入单站反代域名 (Domain B, 如 example2.domain.com): " DOMAIN_B
    [[ -z "$DOMAIN_A" || -z "$DOMAIN_B" ]] && exit 1

    # 2. 证书处理 (Domain A)
    echo -e "${CYAN}正在处理域名 A 证书...${NC}"
    CERT_A_INFO=$(check_cert "$DOMAIN_A" || true)
    if [[ -z "$CERT_A_INFO" ]]; then
        read -p "域名 A 证书未发现，是否使用 CF Token 申请? [y/N]: " REQ_A
        if [[ "$REQ_A" =~ ^[Yy]$ ]]; then
            read -p "请输入 CF API Token: " CF_TOKEN
            export CF_Token="$CF_TOKEN"
            [[ ! -f "$HOME/.acme.sh/acme.sh" ]] && curl https://get.acme.sh | sh -s email=admin@$DOMAIN_A
            "$HOME/.acme.sh/acme.sh" --issue --dns dns_cf -d "$DOMAIN_A" --force
            mkdir -p "$SSL_DIR/$DOMAIN_A"
            "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN_A" --key-file "$SSL_DIR/$DOMAIN_A/privkey.pem" --fullchain-file "$SSL_DIR/$DOMAIN_A/fullchain.pem"
            SSL_A_FULL="$SSL_DIR/$DOMAIN_A/fullchain.pem"; SSL_A_KEY="$SSL_DIR/$DOMAIN_A/privkey.pem"
        else
            echo -e "${RED}无证书，退出${NC}"; exit 1
        fi
    else
        SSL_A_FULL=$(echo $CERT_A_INFO | awk '{print $1}'); SSL_A_KEY=$(echo $CERT_A_INFO | awk '{print $2}')
    fi

    # 3. 证书处理 (Domain B)
    echo -e "${CYAN}正在处理域名 B 证书...${NC}"
    CERT_B_INFO=$(check_cert "$DOMAIN_B" || true)
    if [[ -z "$CERT_B_INFO" ]]; then
        [[ -z "$CF_Token" ]] && read -p "请输入 CF API Token: " CF_Token
        export CF_Token="$CF_Token"
        "$HOME/.acme.sh/acme.sh" --issue --dns dns_cf -d "$DOMAIN_B" --force
        mkdir -p "$SSL_DIR/$DOMAIN_B"
        "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN_B" --key-file "$SSL_DIR/$DOMAIN_B/privkey.pem" --fullchain-file "$SSL_DIR/$DOMAIN_B/fullchain.pem"
        SSL_B_FULL="$SSL_DIR/$DOMAIN_B/fullchain.pem"; SSL_B_KEY="$SSL_DIR/$DOMAIN_B/privkey.pem"
    else
        SSL_B_FULL=$(echo $CERT_B_INFO | awk '{print $1}'); SSL_B_KEY=$(echo $CERT_B_INFO | awk '{print $2}')
    fi

    # 4. 获取自定义 404
    mkdir -p "$HTML_DIR"
    curl -sLo "$HTML_FILE" "$GITHUB_HTML_URL" || echo -e "${RED}404 页面同步失败${NC}"

    # 5. 生成 Nginx 全局 Map
    cat > "$CONF_TARGET" << EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}
map \$http_user_agent \$is_emby_client {
    default 0;
    "~*(Hills|yamby|Afuse|Capy|Fileball|Infuse|SenPlayer|VLC|VidHub|Emby|Android|iOS)" 1;
}
EOF

    # 6. 注入 Domain A (原有代码，逻辑一字不差)
    cat >> "$CONF_TARGET" << EOF
server {
    listen 80;
    listen 443 ssl http2;
    listen 40889 ssl http2;
    server_name $DOMAIN_A;
    ssl_certificate $SSL_A_FULL;
    ssl_certificate_key $SSL_A_KEY;
    merge_slashes off;
    resolver 1.1.1.1 8.8.8.8 ipv6=off valid=300s;
    resolver_timeout 5s;
    error_page 404 /emby-404.html;
    location = /emby-404.html { root $HTML_DIR; internal; }

    # [原有正则逻辑开始]
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

    # 7. 注入 Domain B (单站分发逻辑)
    cat >> "$CONF_TARGET" << EOF
server {
    listen 80;
    listen 443 ssl http2;
    server_name $DOMAIN_B;
    ssl_certificate $SSL_B_FULL;
    ssl_certificate_key $SSL_B_KEY;
    merge_slashes off;
    resolver 1.1.1.1 8.8.8.8 ipv6=off valid=300s;
    resolver_timeout 5s;
    error_page 404 /emby-404.html;
    location = /emby-404.html { root $HTML_DIR; internal; }
EOF

    # 循环收集 Domain B 的路径
    while true; do
        read -p "是否为 Domain B 添加单站路径映射? (y/n): " ADD_PATH
        [[ "$ADD_PATH" != "y" ]] && break
        read -p "  路径名 (如 path1): " P_NAME
        read -p "  目标 Emby 地址 (如 emby1.com): " P_TARGET
        cat >> "$CONF_TARGET" << EOF
    location ^~ /$P_NAME/ {
        proxy_pass https://$P_TARGET:443/;
        proxy_set_header Host $P_TARGET;
        proxy_ssl_name $P_TARGET;
        proxy_ssl_server_name on;
        proxy_ssl_verify off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_hide_header 'Access-Control-Allow-Origin';
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' '*' always;
        add_header 'Access-Control-Allow-Headers' '*' always;
        add_header 'Access-Control-Expose-Headers' 'Content-Length, Content-Range' always;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_force_ranges on;
    }
EOF
    done

    # 闭合 Domain B
    cat >> "$CONF_TARGET" << EOF
    location / { return 404; }
}
EOF

    # 8. 完成部署
    if nginx -t; then
        systemctl restart nginx
        echo -e "${GREEN}部署成功!${NC}"
        echo -e "万能反代: https://$DOMAIN_A:40889/https://..."
        echo -e "单站反代: https://$DOMAIN_B/路径名/"
    else
        echo -e "${RED}Nginx 测试失败，请检查配置。${NC}"
        exit 1
    fi
}

# --- 执行选择 ---
clear
echo "1) 安装/更新 (双域名共存模式)"
echo "2) 彻底卸载"
read -p "选择操作: " OPT
case $OPT in
    1) install_emby_pro ;;
    2) uninstall_emby ;;
    *) exit 0 ;;
esac
