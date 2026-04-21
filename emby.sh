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

# 权限检查
[[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 权限运行${NC}" && exit 1

# --- 证书检索功能 ---
find_existing_cert() {
    local d=$1
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

    # 准备 acme.sh 环境
    if [[ ! -f "$HOME/.acme.sh/acme.sh" ]]; then
        read -p "请输入证书通知邮箱 (如 admin@example.com): " USER_EMAIL
        USER_EMAIL=${USER_EMAIL:-"admin@$DOMAIN"}
        curl https://get.acme.sh | sh -s email="$USER_EMAIL"
    fi

    echo -e "${CYAN}选择证书申请方式:${NC}"
    echo "1) Webroot 模式 (通过 Nginx 80 端口验证，最稳妥)"
    echo "2) Cloudflare DNS 模式 (需 API Token，支持通配符)"
    read -p "选择 [1-2]: " SSL_MODE

    if [[ "$SSL_MODE" == "2" ]]; then
        read -p "请输入 Cloudflare API Token: " CF_Token
        export CF_Token="$CF_Token"
        "$HOME/.acme.sh/acme.sh" --issue --dns dns_cf -d "$DOMAIN" --force
    else
        echo -e "${YELLOW}确保域名 $DOMAIN 已解析到本服务器，且 80 端口未被防火墙拦截${NC}"
        # 临时创建验证目录
        local WEBROOT="/var/www/html"
        mkdir -p "$WEBROOT"
        
        # 临时创建 Nginx 80 端口配置用于验证
        cat > /etc/nginx/conf.d/temp_auth.conf << EOF
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root $WEBROOT; }
}
EOF
        systemctl reload nginx
        "$HOME/.acme.sh/acme.sh" --issue -d "$DOMAIN" --webroot "$WEBROOT" --force
        rm -f /etc/nginx/conf.d/temp_auth.conf
        systemctl reload nginx
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

# --- 1. 万能反代部署 ---
deploy_universal() {
    read -p "请输入万能反代域名: " D_UNI
    [[ -z "$D_UNI" ]] && return
    
    local SEARCH=$(grep -l "server_name .*$D_UNI" /etc/nginx/conf.d/*.conf 2>/dev/null || true)
    if [[ -n "$SEARCH" ]]; then
        echo -e "${YELLOW}提醒: 域名 $D_UNI 已在配置中定义: $SEARCH${NC}"
        read -p "是否覆盖现有配置并重新生成? [y/N]: " OVR
        [[ "${OVR,,}" != "y" ]] && return
    fi

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
        proxy_ssl_verify off;
        proxy_hide_header 'Access-Control-Allow-Origin';
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, RANGE' always;
        add_header 'Access-Control-Allow-Headers' '*' always;
        add_header 'Access-Control-Expose-Headers' 'Content-Length, Content-Range' always;
        if (\$request_method = 'OPTIONS') { return 204; }
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_force_ranges on;
        proxy_set_header Range \$http_range;
        proxy_set_header X-Accel-Buffering no;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        tcp_nodelay on;
      #  proxy_set_header Host \$http_host;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Host \$http_host;
    proxy_set_header X-Forwarded-Port \$server_port;
    }
    location / { return 404; }
}
EOF
    nginx -t && systemctl restart nginx && echo -e "${GREEN}万能反代部署完成！${NC}"
    sleep 2
}

# --- 2. 单站路径反代管理 ---
deploy_single() {
    while true; do
        clear
        echo -e "${CYAN}--- 单站路径反代管理 ---${NC}"
        local conf_files=(/etc/nginx/conf.d/emby_single_*.conf)
        echo -e "${YELLOW}当前已配置域名:${NC}"
        if [[ -e "${conf_files[0]}" ]]; then
            for conf in "${conf_files[@]}"; do
                local dom=$(basename "$conf" | sed 's/emby_single_//; s/\.conf//')
                echo -e "  - ${GREEN}$dom${NC}"
            done
        else
            echo "  (无)"
        fi

        echo -e "\n1) 添加/进入域名管理"
        echo "2) 删除指定域名配置"
        echo "q) 返回主菜单"
        read -p "请选择: " S_OPT
        
        if [[ "$S_OPT" == "q" ]]; then
            break
        elif [[ "$S_OPT" == "2" ]]; then
            read -p "请输入要删除的域名: " del_dom
            if [[ -f "/etc/nginx/conf.d/emby_single_$del_dom.conf" ]]; then
                rm -f "/etc/nginx/conf.d/emby_single_$del_dom.conf"
                nginx -s reload
                echo -e "${GREEN}域名 $del_dom 已删除${NC}"
            else
                echo -e "${RED}未找到配置${NC}"
            fi
            sleep 1.5
            continue
        elif [[ "$S_OPT" == "1" ]]; then
            read -p "请输入域名 (如 emby.test.com): " D_SIN
            [[ -z "$D_SIN" ]] && continue
        else
            continue
        fi

        local TARGET_CONF="/etc/nginx/conf.d/emby_single_${D_SIN}.conf"
        
        if [[ ! -f "$TARGET_CONF" ]]; then
            init_env
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
            nginx -t && systemctl restart nginx
        fi

        while true; do
            clear
            echo -e "${CYAN}--- [$D_SIN] 路径管理 ---${NC}"
            echo -e "${YELLOW}当前路径清单：${NC}"
            local paths=$(grep "location \^~ /" "$TARGET_CONF" | cut -d'/' -f2 | sed 's/\\//g')
            [[ -z "$paths" ]] && echo "  (无)" || (for p in $paths; do echo -e "  - /$p/"; done)

            echo -e "\n输入 [路径名] 添加或修改 (如: emos)"
            echo "输入 [q] 返回上一级"
            read -p "操作路径: " P_NAME
            [[ "$P_NAME" == "q" ]] && break
            [[ -z "$P_NAME" ]] && continue

            if grep -q "location \^~ /$P_NAME/" "$TARGET_CONF"; then
                echo -e "${YELLOW}路径 /$P_NAME/ 已存在：${NC}"
                echo "1) 覆盖修改后端地址"
                echo "2) 删除此路径"
                echo "3) 重命名路径"
                echo "4) 取消"
                read -p "选择: " P_OPT
                case $P_OPT in
                    1) sed -i "/location \^~ \/$P_NAME\//,/}/d" "$TARGET_CONF" ;;
                    2) sed -i "/location \^~ \/$P_NAME\//,/}/d" "$TARGET_CONF"; nginx -s reload; continue ;;
                    3) read -p "新名称: " NEW_P; sed -i "s|location \^~ /$P_NAME/|location \^~ /$NEW_P/|g" "$TARGET_CONF"; nginx -s reload; continue ;;
                    *) continue ;;
                esac
            fi

            read -p "后端地址 (如 http://1.2.3.4:8096): " P_URL
            [[ -z "$P_URL" ]] && continue
            P_PROTO=$(echo $P_URL | grep :// | sed -e 's|://.*||'); [[ -z "$P_PROTO" ]] && P_PROTO="http"
            P_HOST=$(echo $P_URL | sed -e 's|^.*://||' -e 's|/.*||')
            P_PURE_HOST=$(echo $P_HOST | cut -d: -f1)

            TMP_B=$(mktemp)
            cat > "$TMP_B" << EOF
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
        proxy_set_header Range \$http_range;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        tcp_nodelay on;
    }
EOF
            # 插入到 location / 前面
            sed -i "/location \/ {/i \\" "$TARGET_CONF"
            sed -i "/location \/ {/e cat $TMP_B" "$TARGET_CONF"
            rm -f "$TMP_B"
            nginx -s reload && echo -e "${GREEN}路径 /$P_NAME/ 已生效${NC}"
            sleep 1
        done
    done
}

# --- 主菜单 ---
while true; do
    clear
    echo -e "${CYAN}--- Emby Nginx Gateway Manager ---${NC}"
    echo "1) 部署/覆盖 [万能动态反代]"
    echo "2) 部署/管理 [单站路径反代] (多域名/增删改)"
    echo "3) 卸载全部网关配置"
    echo "q) 退出"
    read -p "选择: " OPT
    case $OPT in
        1) deploy_universal ;;
        2) deploy_single ;;
        3) rm -f /etc/nginx/conf.d/emby_*.conf; systemctl restart nginx; echo "配置已清理"; sleep 1.5 ;;
        q) exit 0 ;;
    esac
done
