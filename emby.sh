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

# --- 证书检索功能 ---
find_existing_cert() {
    local d=$1
    # 搜索优先级: 1. 本脚本自定义目录 2. acme.sh 默认目录 3. certbot 默认目录
    local paths=(
        "$SSL_DIR/$d/fullchain.pem"
        "$HOME/.acme.sh/${d}_ecc/fullchain.cer"
        "/etc/letsencrypt/live/$d/fullchain.pem"
    )
    local keys=(
        "$SSL_DIR/$d/privkey.pem"
        "$HOME/.acme.sh/${d}_ecc/${d}.key"
        "/etc/letsencrypt/live/$d/privkey.pem"
    )

    for i in "${!paths[@]}"; do
        if [[ -f "${paths[$i]}" && -f "${keys[$i]}" ]]; then
            echo "${paths[$i]} ${keys[$i]}"
            return 0
        fi
    done
    return 1
}

# --- 证书申请逻辑 ---
handle_ssl() {
    local DOMAIN=$1
    echo -e "${CYAN}正在检查本地是否存在域名 $DOMAIN 的证书...${NC}"
    
    local EXIST_CERT=$(find_existing_cert "$DOMAIN" || true)
    
    if [[ -n "$EXIST_CERT" ]]; then
        CUR_FULL=$(echo $EXIST_CERT | awk '{print $1}')
        CUR_KEY=$(echo $EXIST_CERT | awk '{print $2}')
        echo -e "${GREEN}检测到现有证书:${NC}\nCert: $CUR_FULL\nKey: $CUR_KEY"
        read -p "是否直接使用现有证书? [Y/n]: " USE_EXIST
        [[ "${USE_EXIST,,}" != "n" ]] && return 0
    fi

    echo -e "${CYAN}选择证书申请方式:${NC}"
    echo "1) HTTP 模式 (可自定义端口，需防火墙放行)"
    echo "2) Cloudflare DNS 模式 (需 API Token)"
    read -p "选择 [1-2]: " SSL_MODE

    [[ ! -f "$HOME/.acme.sh/acme.sh" ]] && curl https://get.acme.sh | sh -s email=admin@$DOMAIN

    if [[ "$SSL_MODE" == "2" ]]; then
        read -p "请输入 Cloudflare API Token: " CF_Token
        export CF_Token="$CF_Token"
        "$HOME/.acme.sh/acme.sh" --issue --dns dns_cf -d "$DOMAIN" --force
    else
        read -p "请输入 HTTP 验证使用的端口 (默认 80): " HTTP_PORT
        HTTP_PORT=${HTTP_PORT:-80}
        "$HOME/.acme.sh/acme.sh" --issue --standalone -d "$DOMAIN" --httpport "$HTTP_PORT" --force
    fi

    mkdir -p "$SSL_DIR/$DOMAIN"
    "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" \
        --key-file "$SSL_DIR/$DOMAIN/privkey.pem" \
        --fullchain-file "$SSL_DIR/$DOMAIN/fullchain.pem"
    
    CUR_FULL="$SSL_DIR/$DOMAIN/fullchain.pem"
    CUR_KEY="$SSL_DIR/$DOMAIN/privkey.pem"
}

# --- 环境初始化 ---
init_env() {
    apt update && apt install -y nginx-full curl openssl sed socat cron
    mkdir -p "$HTML_DIR"
    mkdir -p "$SSL_DIR"
    [[ ! -f "$HTML_FILE" ]] && curl -sLo "$HTML_FILE" "$GITHUB_HTML_URL"
    cat > "$MAP_CONF" << EOF
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
map \$http_user_agent \$is_emby_client {
    default 0;
    "~*(Hills|yamby|Afuse|Capy|Fileball|Infuse|SenPlayer|VLC|VidHub|Emby|Android|iOS)" 1;
}
EOF
}

# --- 域名配置冲突检查 ---
check_domain_exists() {
    local DOMAIN=$1
    local SEARCH=$(grep -l "server_name .*$DOMAIN" /etc/nginx/conf.d/*.conf 2>/dev/null || true)
    
    if [[ -n "$SEARCH" ]]; then
        echo -e "${YELLOW}提醒: 域名 $DOMAIN 已在配置中定义: $SEARCH${NC}"
        echo "1) 覆盖并重新生成配置"
        echo "2) 进入路径管理 (仅限单站模式)"
        echo "3) 取消"
        read -p "选择 [1-3]: " EXIST_OPT
        case $EXIST_OPT in
            1) return 0 ;; 
            2) return 2 ;; 
            *) return 1 ;; 
        esac
    fi
    return 0
}

# --- 1. 万能反代 ---
deploy_universal() {
    read -p "请输入万能反代域名: " D_UNI
    [[ -z "$D_UNI" ]] && return
    check_domain_exists "$D_UNI" || return
    init_env
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
        # --- 转发真实IP ---
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        # --- End ---
        proxy_ssl_verify off;
        proxy_hide_header 'Access-Control-Allow-Origin';
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, RANGE' always;
        add_header 'Access-Control-Allow-Headers' '*' always;
        add_header 'Access-Control-Expose-Headers' 'Content-Length, Content-Range' always;
        if (\$request_method = 'OPTIONS') { return 204; }
        proxy_buffering off;
        proxy_request_buffering off;
        # ---新补充 ---
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        tcp_nodelay on; # 禁用 Nagle 算法，减少小包延迟（非常适合 WebSocket 握手）
        # --- end ---
        proxy_set_header X-Accel-Buffering no;
        proxy_force_ranges on;
        proxy_set_header Range \$http_range; # 新补充
    }
    location / { return 404; }
}
EOF
    nginx -t && systemctl restart nginx && echo -e "${GREEN}万能反代部署完成！${NC}"
}

# --- 2. 单站反代 ---
deploy_single() {
    read -p "请输入单站反代域名: " D_SIN
    [[ -z "$D_SIN" ]] && return
    local TARGET_CONF="/etc/nginx/conf.d/emby_single.conf"
    check_domain_exists "$D_SIN"
    local RET=$?
    [[ $RET -eq 1 ]] && return
    init_env
    if [[ $RET -eq 0 ]]; then
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
        echo -e "\n${CYAN}当前管理域名: $D_SIN${NC}"
        echo -e "${CYAN}当前已配置路径：${NC}"
        grep "location \^~ /" "$TARGET_CONF" | cut -d'/' -f2 | sed 's/\\//g' || echo "无"
        
        read -p "请输入操作路径 (如 emos, q 退出): " P_NAME
        [[ "$P_NAME" == "q" ]] && break
        
        if grep -q "location \^~ /$P_NAME/" "$TARGET_CONF"; then
            echo -e "${YELLOW}路径 /$P_NAME/ 已存在。${NC}"
            echo "1) 覆盖后端 2) 删除路径 3) 重构路径名 4) 取消"
            read -p "选择: " P_OPT
            case $P_OPT in
                2) sed -i "/location \^~ \/$P_NAME\//,/}/d" "$TARGET_CONF"; echo "已删除"; nginx -s reload; continue ;;
                3) read -p "新路径名: " NEW_P_NAME; sed -i "s|location ^~ /$P_NAME/|location ^~ /$NEW_P_NAME/|g" "$TARGET_CONF"; nginx -s reload; continue ;;
                4) continue ;;
            esac
            sed -i "/location \^~ \/$P_NAME\//,/}/d" "$TARGET_CONF"
        fi

        read -p "目标地址 (http://...): " P_FULL_URL
        [[ -z "$P_FULL_URL" ]] && continue
        P_PROTO=$(echo $P_FULL_URL | grep :// | sed -e 's|://.*||'); [[ -z "$P_PROTO" ]] && P_PROTO="https"
        P_HOST=$(echo $P_FULL_URL | sed -e 's|^.*://||' -e 's|/.*||')
        P_PURE_HOST=$(echo $P_HOST | cut -d: -f1)

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
        proxy_force_ranges on;
    }
EOF
        sed -i "/location \/ {/i \\" "$TARGET_CONF"
        sed -i "/location \/ {/e cat $TMP_BLOCK" "$TARGET_CONF"
        rm -f "$TMP_BLOCK"
        echo -e "${GREEN}路径 /$P_NAME/ 配置已更新${NC}"
        nginx -t && nginx -s reload
    done
}

# --- 菜单 ---
while true; do
    clear
    echo -e "${CYAN}--- Emby Nginx Gateway Manager ---${NC}"
    echo "1) 部署 [万能动态反代]"
    echo "2) 部署/管理 [单站路径反代] (增删改)"
    echo "3) 卸载全部配置"
    echo "q) 退出"
    read -p "选择: " OPT
    case $OPT in
        1) deploy_universal ;;
        2) deploy_single ;;
        3) rm -f /etc/nginx/conf.d/emby_*.conf; systemctl restart nginx; echo "已清理" ;;
        q) exit 0 ;;
    esac
done
