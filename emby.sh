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

# --- 证书与环境初始化 (同前，略作整合) ---
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

handle_ssl() {
    local DOMAIN=$1
    CERT_INFO=$(check_cert "$DOMAIN" || true)
    if [[ -z "$CERT_INFO" ]]; then
        echo -e "${YELLOW}申请证书中...${NC}"
        [[ ! -f "$HOME/.acme.sh/acme.sh" ]] && curl https://get.acme.sh | sh -s email=admin@$DOMAIN
        "$HOME/.acme.sh/acme.sh" --issue --standalone -d "$DOMAIN" --force
        mkdir -p "$SSL_DIR/$DOMAIN"
        "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" --key-file "$SSL_DIR/$DOMAIN/privkey.pem" --fullchain-file "$SSL_DIR/$DOMAIN/fullchain.pem"
        CUR_FULL="$SSL_DIR/$DOMAIN/fullchain.pem"; CUR_KEY="$SSL_DIR/$DOMAIN/privkey.pem"
    else
        CUR_FULL=$(echo $CERT_INFO | awk '{print $1}'); CUR_KEY=$(echo $CERT_INFO | awk '{print $2}')
    fi
}

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

# --- 1. 万能反代 ---
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
    error_page 404 /emby-404.html;
    location = /emby-404.html { root $HTML_DIR; internal; }
    location ~* "^/(?<raw_proto>https?|wss?)://(?<raw_target>[a-zA-Z0-9\.-]+)(?:[:/_](?<raw_port>\d+))?(?<raw_path>/.*)?$" {
        if (\$is_emby_client = 0) { return 403; }
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
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, RANGE' always;
        add_header 'Access-Control-Allow-Headers' '*' always;
        add_header 'Access-Control-Expose-Headers' 'Content-Length, Content-Range' always;
        if (\$request_method = 'OPTIONS') { return 204; }
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

# --- 2. 单站反代 (增强版) ---
deploy_single() {
    init_env
    read -p "请输入单站反代域名: " D_SIN
    [[ -z "$D_SIN" ]] && return
    local TARGET_CONF="/etc/nginx/conf.d/emby_single.conf"

    if [[ ! -f "$TARGET_CONF" ]]; then
        handle_ssl "$D_SIN"
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
    location / { return 404; }
}
EOF
    fi

    while true; do
        echo -e "\n${CYAN}当前已配置路径：${NC}"
        grep "location ^~ /" "$TARGET_CONF" | cut -d'/' -f2 | sed 's/\\//g' || echo "无"
        
        read -p "请输入操作路径 (如 emos, q 退出): " P_NAME
        [[ "$P_NAME" == "q" ]] && break
        
        # 路径存在时的处理
        if grep -q "location ^~ /$P_NAME/" "$TARGET_CONF"; then
            echo -e "${YELLOW}检测到路径 /$P_NAME/ 已存在。${NC}"
            echo "1) 覆盖后端地址"
            echo "2) 删除该路径"
            echo "3) 修改路径名 (重命名)"
            echo "4) 取消"
            read -p "请选择: " P_OPT
            case $P_OPT in
                2)
                    sed -i "/location \^~ \/$P_NAME\//,/}/d" "$TARGET_CONF"
                    echo -e "${RED}已删除路径 /$P_NAME/${NC}"; continue ;;
                3)
                    read -p "请输入新的路径名: " NEW_P_NAME
                    sed -i "s|location ^~ /$P_NAME/|location ^~ /$NEW_P_NAME/|g" "$TARGET_CONF"
                    echo -e "${GREEN}路径已由 /$P_NAME/ 重命名为 /$NEW_P_NAME/${NC}"; continue ;;
                4) continue ;;
            esac
            # 选1则先清理旧块
            sed -i "/location \^~ \/$P_NAME\//,/}/d" "$TARGET_CONF"
        fi

        # 新增/覆盖逻辑
        read -p "完整目标地址 (http://...): " P_FULL_URL
        P_PROTO=$(echo $P_FULL_URL | grep :// | sed -e 's|://.*||'); [[ -z "$P_PROTO" ]] && P_PROTO="https"
        P_HOST=$(echo $P_FULL_URL | sed -e 's|^.*://||' -e 's|/.*||')
        P_PURE_HOST=$(echo $P_HOST | cut -d: -f1)

        # 构建临时文件避免 sed 转义地狱
        TMP_BLOCK=$(mktemp)
        cat > "$TMP_BLOCK" << EOF
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
        add_header 'Access-Control-Expose-Headers' 'Content-Length, Content-Range' always;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_force_ranges on;  # 206状态支持 一般默认开启
    }
EOF
        # 在倒数第二行（即 location / { ... } 之前）插入
        sed -i "/location \/ {/i \\" "$TARGET_CONF"
        sed -i "/location \/ {/e cat $TMP_BLOCK" "$TARGET_CONF"
        rm -f "$TMP_BLOCK"
        echo -e "${GREEN}路径 /$P_NAME/ 配置成功！${NC}"
    done
    nginx -t && systemctl restart nginx
}

# --- 3. 卸载 ---
uninstall_all() {
    rm -f /etc/nginx/conf.d/emby_*.conf
    rm -rf "$HTML_DIR"
    systemctl restart nginx
    echo -e "${YELLOW}清理完成。${NC}"
}

# --- 菜单 ---
clear
echo "1) 部署 [万能动态反代]"
echo "2) 部署 [单站路径反代] (支持修改/重命名/删除)"
echo "3) 卸载"
read -p "选择: " OPT
case $OPT in
    1) deploy_universal ;;
    2) deploy_single ;;
    3) uninstall_all ;;
    *) exit 0 ;;
esac
