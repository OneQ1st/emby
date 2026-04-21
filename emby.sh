#!/bin/bash
set -e

# --- 基础定义 (请根据你的仓库修改 URL) ---
REPO_RAW_URL="https://raw.githubusercontent.com/OneQ1st/emby/main"
PROXY_BIN="/usr/local/bin/emby-proxy"
PROXY_CONF="/usr/local/bin/config.json"
SERVICE_FILE="/etc/systemd/system/emby-proxy.service"
SSL_DIR="/etc/nginx/ssl"
MAP_CONF="/etc/nginx/conf.d/emby_maps.conf"
HTML_DIR="/var/www/emby"
HTML_FILE="$HTML_DIR/emby-404.html"

# --- 颜色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 权限运行${NC}" && exit 1

# --- [1] 环境初始化 (环境安装分开) ---
init_env() {
    echo -e "${CYAN}正在初始化基础运行环境...${NC}"
    apt update && apt install -y nginx-full curl openssl sed socat cron wget
    mkdir -p "$HTML_DIR" "$SSL_DIR"
    
    # 下载 404 页面
    curl -sLo "$HTML_FILE" "$REPO_RAW_URL/emby-404.html"
    
    # 写入 Nginx Map 规则 (UA白名单 + WebSocket)
    cat > "$MAP_CONF" << EOF
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
map \$http_user_agent \$is_emby_client {
    default 0;
    "~*(Hills|yamby|Afuse|Capy|Fileball|Infuse|SenPlayer|VLC|VidHub|Emby|Android|iOS)" 1;
}
EOF
    # 安装 acme.sh
    [[ ! -f "$HOME/.acme.sh/acme.sh" ]] && curl https://get.acme.sh | sh -s email="admin@google.com"
    echo -e "${GREEN}基础环境准备完成。${NC}"
}

# --- [2] 从 GitHub 拉取并配置服务 ---
setup_service() {
    echo -e "${CYAN}正在从仓库下载二进制文件与配置...${NC}"
    curl -sLo "$PROXY_BIN" "$REPO_RAW_URL/emby-proxy"
    curl -sLo "$PROXY_CONF" "$REPO_RAW_URL/config.json"
    chmod +x "$PROXY_BIN"

    # 生成 Systemd 服务文件 (项目推荐参数注入)
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
    echo -e "${GREEN}后台服务已从仓库同步并启动。${NC}"
}

# --- [3] 证书申请业务 ---
handle_ssl() {
    local DOMAIN=$1
    local CERT_PATH="$SSL_DIR/$DOMAIN/fullchain.pem"
    local KEY_PATH="$SSL_DIR/$DOMAIN/privkey.pem"
    
    if [[ -f "$CERT_PATH" ]] && openssl x509 -checkend $(( 14 * 24 * 3600 )) -noout -in "$CERT_PATH"; then
        echo -e "${GREEN}本地证书有效，跳过申请。${NC}"
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

# --- [4] Nginx 部署 (项目推荐参数) ---
deploy_nginx() {
    local TYPE=$1
    local DOMAIN=$2
    local TARGET_CONF="/etc/nginx/conf.d/emby_${TYPE}_${DOMAIN}.conf"
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

        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-Prefix $PREFIX;

        proxy_buffering off;
        proxy_request_buffering off;
        proxy_max_temp_file_size 0;
        
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        proxy_read_timeout 600s;
        tcp_nodelay on;
    }
}
EOF
    # 万能模式额外注入正则逻辑
    [[ "$TYPE" == "universal" ]] && sed -i "/location \/ {/i \    location ~* \"^/(?<raw_proto>https?|wss?)://(?<raw_target>[a-zA-Z0-9\\\\.-]+)(?:[:/_](?<raw_port>\\\\d+))?(?<raw_path>/.*)?$\" { if (\$is_emby_client = 0) { return 404; } proxy_pass http://127.0.0.1:8080; proxy_set_header Host \$http_host; proxy_set_header X-Forwarded-Proto \$scheme; proxy_set_header X-Forwarded-Host \$http_host; proxy_set_header X-Forwarded-Prefix /custom; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \"upgrade\"; proxy_buffering off; proxy_max_temp_file_size 0; }" "$TARGET_CONF"

    nginx -t && systemctl restart nginx
    echo -e "${GREEN}Nginx 入口配置完成！${NC}"
}

# --- [5] 完整卸载 ---
uninstall_all() {
    echo -e "${RED}正在清理所有组件...${NC}"
    systemctl stop emby-proxy || true
    systemctl disable emby-proxy || true
    rm -f "$SERVICE_FILE" "$PROXY_BIN" "$PROXY_CONF"
    systemctl daemon-reload
    rm -f /etc/nginx/conf.d/emby_*.conf "$MAP_CONF"
    rm -rf "$SSL_DIR" "$HTML_DIR"
    echo -e "${YELLOW}所有数据已卸载。${NC}"
    sleep 1
}

# --- 主菜单 ---
while true; do
    clear
    echo -e "${CYAN}--- Emby Gateway & GitHub Sync Manager ---${NC}"
    echo "1) 安装/初始化 环境依赖"
    echo "2) 从 GitHub 下载并启动 emby-proxy 后台服务"
    echo "3) 部署 [万能反代] (含项目推荐 Header)"
    echo "4) 部署 [单站反代] (含项目推荐 Header)"
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
