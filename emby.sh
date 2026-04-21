#!/bin/bash
set -e

# --- 基础定义 ---
PROXY_BIN="/usr/local/bin/emby-proxy"
PROXY_CONF="/usr/local/bin/config.json"
SERVICE_FILE="/etc/systemd/system/emby-proxy.service"
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

# --- [1] 环境初始化 ---
init_env() {
    echo -e "${CYAN}正在初始化环境...${NC}"
    apt update && apt install -y nginx-full curl openssl sed socat cron wget
    mkdir -p "$HTML_DIR" "$SSL_DIR"
    [[ ! -f "$HTML_FILE" ]] && curl -sLo "$HTML_FILE" "$GITHUB_HTML_URL"
    
    # 写入 Nginx Map 规则 (白名单 + WebSocket)
    cat > "$MAP_CONF" << EOF
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
map \$http_user_agent \$is_emby_client {
    default 0;
    "~*(Hills|yamby|Afuse|Capy|Fileball|Infuse|SenPlayer|VLC|VidHub|Emby|Android|iOS)" 1;
}
EOF
    [[ ! -f "$HOME/.acme.sh/acme.sh" ]] && curl https://get.acme.sh | sh -s email="admin@google.com"
    echo -e "${GREEN}环境准备完成。${NC}"
}

# --- [2] Systemd 服务配置 ---
setup_service() {
    echo -e "${CYAN}正在配置后台服务...${NC}"
    if [[ ! -f "$PROXY_BIN" ]]; then
        echo -e "${RED}错误: $PROXY_BIN 不存在，请先上传并命名。${NC}"
        return 1
    fi
    chmod +x "$PROXY_BIN"

    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Emby Reverse Proxy Go Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/bin
ExecStart=$PROXY_BIN -config $PROXY_CONF
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable emby-proxy
    systemctl restart emby-proxy
    echo -e "${GREEN}后台服务已启动。${NC}"
}

# --- [3] 稳妥证书申请 ---
handle_ssl() {
    local DOMAIN=$1
    local CERT_PATH="$SSL_DIR/$DOMAIN/fullchain.pem"
    local KEY_PATH="$SSL_DIR/$DOMAIN/privkey.pem"
    
    if [[ -f "$CERT_PATH" ]] && openssl x509 -checkend $(( 14 * 24 * 3600 )) -noout -in "$CERT_PATH"; then
        echo -e "${GREEN}证书有效期内，跳过申请。${NC}"
        CUR_FULL="$CERT_PATH"; CUR_KEY="$KEY_PATH"; return 0
    fi

    echo -e "${CYAN}选择证书申请模式: 1)HTTP 2)Cloudflare DNS${NC}"
    read -p "选择: " SSL_MODE
    if [[ "$SSL_MODE" == "2" ]]; then
        read -p "CF API Token: " CF_Token
        export CF_Token="$CF_Token"
        "$HOME/.acme.sh/acme.sh" --issue --dns dns_cf -d "$DOMAIN" --force
    else
        mkdir -p "/var/www/html"
        cat > /etc/nginx/conf.d/acme_temp.conf << EOF
server { listen 80; server_name $DOMAIN; location /.well-known/acme-challenge/ { root /var/www/html; } }
EOF
        systemctl reload nginx
        "$HOME/.acme.sh/acme.sh" --issue -d "$DOMAIN" --webroot /var/www/html --force
        rm -f /etc/nginx/conf.d/acme_temp.conf
    fi
    mkdir -p "$SSL_DIR/$DOMAIN"
    "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" --key-file "$KEY_PATH" --fullchain-file "$CERT_PATH" --reloadcmd "systemctl reload nginx"
    CUR_FULL="$CERT_PATH"; CUR_KEY="$KEY_PATH"
}

# --- [4] Nginx 部署 (整合项目推荐配置) ---
deploy_nginx() {
    local TYPE=$1
    local DOMAIN=$2
    local TARGET_CONF="/etc/nginx/conf.d/emby_${TYPE}_${DOMAIN}.conf"
    
    # 动态前缀处理：单站默认为空，万能模式默认为 /custom (可根据需要调整)
    local PREFIX="/"
    [[ "$TYPE" == "universal" ]] && PREFIX="/custom"

    cat > "$TARGET_CONF" << EOF
server {
    listen 80;
    listen 443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate $CUR_FULL;
    ssl_certificate_key $CUR_KEY;
    error_page 404 /emby-404.html;
    location = /emby-404.html { root $HTML_DIR; internal; }

    location / {
        if (\$is_emby_client = 0) { return 404; }

        # --- 项目推荐的核心配置 ---
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-Prefix $PREFIX;

        # 优化与推流稳定性
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_max_temp_file_size 0;
        
        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # 超时设置
        proxy_read_timeout 600s;
        tcp_nodelay on;
    }
}
EOF
    # 万能模式下的路径正则支持
    if [[ "$TYPE" == "universal" ]]; then
        sed -i "/location \/ {/i \    location ~* \"^/(?<raw_proto>https?|wss?)://(?<raw_target>[a-zA-Z0-9\\\\.-]+)(?:[:/_](?<raw_port>\\\\d+))?(?<raw_path>/.*)?$\" { if (\$is_emby_client = 0) { return 404; } proxy_pass http://127.0.0.1:8080; proxy_set_header Host \$http_host; proxy_set_header X-Forwarded-Proto \$scheme; proxy_set_header X-Forwarded-Host \$http_host; proxy_set_header X-Forwarded-Prefix /custom; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \"upgrade\"; proxy_buffering off; proxy_max_temp_file_size 0; }" "$TARGET_CONF"
    fi

    nginx -t && systemctl restart nginx
    echo -e "${GREEN}配置已生成并检查通过。${NC}"
}

# --- [5] 完整卸载 ---
uninstall_all() {
    echo -e "${RED}正在卸载所有组件...${NC}"
    systemctl stop emby-proxy || true
    systemctl disable emby-proxy || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    rm -f /etc/nginx/conf.d/emby_*.conf "$MAP_CONF"
    rm -rf "$SSL_DIR" "$HTML_DIR"
    echo -e "${YELLOW}清理完成。${NC}"
    sleep 1
}

# --- 主菜单 ---
while true; do
    clear
    echo -e "${CYAN}--- Emby Gateway Manager (Enhanced) ---${NC}"
    echo "1) 环境初始化"
    echo "2) 启动 emby-proxy 后台服务 (需已放置在 /usr/local/bin)"
    echo "3) 部署 [万能反代] (带 Prefix 适配)"
    echo "4) 部署 [单站反代] (带 Prefix 适配)"
    echo "5) 完整卸载"
    echo "q) 退出"
    read -p "选择: " OPT
    case $OPT in
        1) init_env ;;
        2) setup_service ;;
        3) read -p "域名: " D; handle_ssl "$D"; deploy_nginx "universal" "$D" ;;
        4) read -p "域名: " D; handle_ssl "$D"; deploy_nginx "single" "$D" ;;
        5) uninstall_all ;;
        q) exit 0 ;;
    esac
done
