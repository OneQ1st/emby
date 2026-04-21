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

# --- [1] 强制环境初始化 (专门解决 Pre-check failed) ---
init_env() {
    echo -e "${CYAN}正在强制初始化环境...${NC}"
    
    # 强制解锁 apt
    rm -f /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock
    
    apt update
    # 核心：必须先装上 cron
    apt install -y cron nginx-full curl openssl socat psmisc lsof wget
    
    # 启动并激活 cron
    systemctl enable --now cron || echo -e "${YELLOW}警告: cron 启动失败，尝试手动补救...${NC}"

    mkdir -p "$HTML_DIR" "$SSL_DIR"
    
    # 强制安装 acme.sh，跳过 crontab 检查
    if [[ ! -f "$HOME/.acme.sh/acme.sh" ]]; then
        echo -e "${YELLOW}正在通过强制模式安装 acme.sh...${NC}"
        curl https://get.acme.sh | sh -s email="admin@google.com" --force
    fi
    
    # 立即加载环境变量
    [ -f "$HOME/.acme.sh/acme.sh.env" ] && source "$HOME/.acme.sh/acme.sh.env"
    
    # 写入 UA 白名单配置
    cat > "$MAP_CONF" << EOF
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
map \$http_user_agent \$is_emby_client {
    default 0;
    "~*(Hills|yamby|Afuse|Capy|Fileball|Infuse|SenPlayer|VLC|VidHub|Emby|Android|iOS)" 1;
}
EOF
    echo -e "${GREEN}环境强制初始化完成，请继续后续步骤。${NC}"
}

# --- [2] 资产三级预检 (VPS Check) ---
check_ssl_assets() {
    local DOMAIN=$1
    local TARGET_CERT="$SSL_DIR/$DOMAIN/fullchain.pem"
    local ACME_HOME_CERT="$HOME/.acme.sh/${DOMAIN}_ecc/fullchain.cer"
    
    echo -e "${CYAN}正在预检本地资产...${NC}"
    if [[ -f "$TARGET_CERT" ]] && openssl x509 -checkend 604800 -noout -in "$TARGET_CERT"; then
        echo -e "${GREEN}部署目录已有有效证书，跳过申请。${NC}"; return 0
    fi
    if [[ -f "$ACME_HOME_CERT" ]] && openssl x509 -checkend 604800 -noout -in "$ACME_HOME_CERT"; then
        echo -e "${YELLOW}acme.sh 目录发现资产，执行同步安装...${NC}"
        mkdir -p "$SSL_DIR/$DOMAIN"
        "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" --key-file "$SSL_DIR/$DOMAIN/privkey.pem" --fullchain-file "$TARGET_CERT" --reloadcmd "systemctl reload nginx"
        return 0
    fi
    return 1
}

# --- [3] 强化申请逻辑 ---
request_cert_pro() {
    local DOMAIN=$1
    local ACME="$HOME/.acme.sh/acme.sh"
    echo -e "${CYAN}选择申请模式:${NC}"
    echo "1) Cloudflare DNS (NAT机首选)"
    echo "2) HTTP Standalone (需公网 80 映射)"
    read -p "选择: " MODE

    if [[ "$MODE" == "1" ]]; then
        unset CF_Key; unset CF_Email;
        read -p "CF API Token: " USER_TOKEN
        export CF_Token="$USER_TOKEN"
        "$ACME" --issue --dns dns_cf -d "$DOMAIN" --force --debug
    else
        read -p "映射到本机的内网验证端口: " NAT_PORT
        NAT_PORT=${NAT_PORT:-80}
        fuser -k "${NAT_PORT}/tcp" || true
        "$ACME" --issue -d "$DOMAIN" --standalone --httpport "$NAT_PORT" --force --debug
    fi
    mkdir -p "$SSL_DIR/$DOMAIN"
    "$ACME" --install-cert -d "$DOMAIN" --key-file "$SSL_DIR/$DOMAIN/privkey.pem" --fullchain-file "$SSL_DIR/$DOMAIN/fullchain.pem" --reloadcmd "systemctl reload nginx"
}

# --- [4] Nginx 配置部署 (严格参数对齐) ---
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
    echo -e "${CYAN}--- NAT/Debian 强制修复脚本 ---${NC}"
    echo "1) 初始化环境 (强制安装依赖)"
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
