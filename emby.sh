#!/bin/bash
set -e

# --- [基础定义] 严禁丢行 ---
REPO_RAW_URL="https://raw.githubusercontent.com/OneQ1st/emby/main"
PROXY_BIN="/usr/local/bin/emby-proxy"
PROXY_CONF="/usr/local/bin/config.json"
SERVICE_FILE="/etc/systemd/system/emby-proxy.service"
SSL_DIR="/etc/nginx/ssl"
MAP_CONF="/etc/nginx/conf.d/emby_maps.conf"
HTML_DIR="/var/www/emby"
HTML_FILE="$HTML_DIR/emby-404.html"

# --- [颜色定义] ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 权限运行${NC}" && exit 1

# --- [1] 环境初始化 (修复 acme.sh 报错的核心) ---
init_env() {
    echo -e "${CYAN}正在初始化 Debian 环境并补全缺失组件...${NC}"
    apt update
    # 补全 cron, lsof, psmisc, socat 等核心依赖
    apt install -y nginx-full curl openssl socat psmisc lsof cron wget
    
    # 确保 cron 服务启动 (解决你刚刚遇到的 Pre-check failed)
    systemctl enable --now cron

    mkdir -p "$HTML_DIR" "$SSL_DIR" "/var/www/html"
    
    # 安装 acme.sh (强制模式)
    if [[ ! -f "$HOME/.acme.sh/acme.sh" ]]; then
        curl https://get.acme.sh | sh -s email="admin@google.com" || {
            echo "尝试强制安装 acme.sh..."
            cd /tmp && wget https://github.com/acmesh-official/acme.sh/archive/master.tar.gz
            tar zxvf master.tar.gz && cd acme.sh-master
            ./acme.sh --install --force --email "admin@google.com"
            cd .. && rm -rf acme.sh-master master.tar.gz
        }
    fi
    
    source "$HOME/.acme.sh/acme.sh.env" || true
    
    # 写入 Nginx Map (UA 白名单)
    cat > "$MAP_CONF" << EOF
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
map \$http_user_agent \$is_emby_client {
    default 0;
    "~*(Hills|yamby|Afuse|Capy|Fileball|Infuse|SenPlayer|VLC|VidHub|Emby|Android|iOS)" 1;
}
EOF
    echo -e "${GREEN}环境补全完成。${NC}"
}

# --- [2] 资产三级预检 (VPS 本地资产发现) ---
check_ssl_assets() {
    local DOMAIN=$1
    local TARGET_CERT="$SSL_DIR/$DOMAIN/fullchain.pem"
    local ACME_HOME_CERT="$HOME/.acme.sh/${DOMAIN}_ecc/fullchain.cer"
    
    echo -e "${CYAN}正在预检 VPS 本地证书资产...${NC}"
    if [[ -f "$TARGET_CERT" ]] && openssl x509 -checkend 604800 -noout -in "$TARGET_CERT"; then
        echo -e "${GREEN}命中部署目录资产，直接跳过申请。${NC}"; return 0
    fi
    if [[ -f "$ACME_HOME_CERT" ]] && openssl x509 -checkend 604800 -noout -in "$ACME_HOME_CERT"; then
        echo -e "${YELLOW}命中 acme.sh 资产，执行同步安装...${NC}"
        mkdir -p "$SSL_DIR/$DOMAIN"
        "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" --key-file "$SSL_DIR/$DOMAIN/privkey.pem" --fullchain-file "$TARGET_CERT" --reloadcmd "systemctl reload nginx"
        return 0
    fi
    return 1
}

# --- [3] 证书申请 (NAT & DNS 适配) ---
request_cert_pro() {
    local DOMAIN=$1
    local ACME="$HOME/.acme.sh/acme.sh"
    echo -e "${CYAN}选择申请模式:${NC}"
    echo "1) Cloudflare DNS (推荐，需 Token 权限全开)"
    echo "2) HTTP Standalone (需 NAT 80 端口转发)"
    read -p "选择: " MODE

    if [[ "$MODE" == "1" ]]; then
        unset CF_Key; unset CF_Email;
        read -p "CF API Token: " USER_TOKEN
        export CF_Token="$USER_TOKEN"
        "$ACME" --issue --dns dns_cf -d "$DOMAIN" --force --debug
    else
        read -p "内网验证端口 (NAT机映射端口): " NAT_PORT
        NAT_PORT=${NAT_PORT:-80}
        fuser -k "${NAT_PORT}/tcp" || true
        "$ACME" --issue -d "$DOMAIN" --standalone --httpport "$NAT_PORT" --force --debug
    fi
    mkdir -p "$SSL_DIR/$DOMAIN"
    "$ACME" --install-cert -d "$DOMAIN" --key-file "$SSL_DIR/$DOMAIN/privkey.pem" --fullchain-file "$SSL_DIR/$DOMAIN/fullchain.pem" --reloadcmd "systemctl reload nginx"
}

# --- [4] Nginx 配置 (严格参数对齐) ---
deploy_nginx_final() {
    local TYPE=$1; local DOMAIN=$2
    local CONF="/etc/nginx/conf.d/emby_${TYPE}_${DOMAIN}.conf"
    local PREFIX="/"; [[ "$TYPE" == "universal" ]] && PREFIX="/custom"

    cat > "$CONF" << EOF
server {
    listen 80;
    listen 443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate $SSL_DIR/$DOMAIN/fullchain.pem;
    ssl_certificate_key $SSL_DIR/$DOMAIN/privkey.pem;
    if (\$scheme = http) { return 301 https://\$host\$request_uri; }
    location / {
        if (\$is_emby_client = 0) { return 404; }
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-Prefix $PREFIX;
        proxy_buffering off;
        proxy_max_temp_file_size 0;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
    [[ "$TYPE" == "universal" ]] && sed -i "/location \/ {/i \    location ~* \"^/(?<raw_proto>https?|wss?)://(?<raw_target>[a-zA-Z0-9\\\\.-]+)(?:[:/_](?<raw_port>\\\\d+))?(?<raw_path>/.*)?$\" { if (\$is_emby_client = 0) { return 404; } proxy_pass http://127.0.0.1:8080; proxy_set_header Host \$http_host; proxy_set_header X-Forwarded-Proto \$scheme; proxy_set_header X-Forwarded-Host \$http_host; proxy_set_header X-Forwarded-Prefix /custom; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \"upgrade\"; proxy_buffering off; proxy_max_temp_file_size 0; }" "$CONF"
    nginx -t && systemctl restart nginx
}

# --- 菜单控制 ---
while true; do
    clear
    echo -e "${CYAN}--- NAT/Debian 终极部署脚本 ---${NC}"
    echo "1) 初始化环境 (修复 Cron/acme.sh)"
    echo "2) 同步服务文件"
    echo "3) 部署 [万能反代]"
    echo "4) 部署 [单站反代]"
    echo "5) 卸载"
    read -p "执行: " OPT
    case $OPT in
        1) init_env ;;
        2) curl -sLo "$PROXY_BIN" "$REPO_RAW_URL/emby-proxy" && chmod +x "$PROXY_BIN" ;;
        3|4) read -p "域名: " D; check_ssl_assets "$D" || request_cert_pro "$D"; [[ "$OPT" == "3" ]] && deploy_nginx_final "universal" "$D" || deploy_nginx_final "single" "$D" ;;
        5) rm -rf "$SSL_DIR" /etc/nginx/conf.d/emby_*.conf ;;
    esac
    read -p "回车继续..."
done
