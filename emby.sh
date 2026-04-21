#!/bin/bash
set -e

# --- 基础定义 ---
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

# --- [阶段一] 环境初始化 (安装分离) ---
init_env() {
    echo -e "${CYAN}正在初始化基础环境 (Nginx, acme.sh, lsof)...${NC}"
    apt update && apt install -y nginx-full curl openssl sed socat cron wget lsof
    mkdir -p "$HTML_DIR" "$SSL_DIR" "/var/www/html"
    
    curl -sLo "$HTML_FILE" "$REPO_RAW_URL/emby-404.html" || echo "警告：404资源同步失败"
    
    cat > "$MAP_CONF" << EOF
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
map \$http_user_agent \$is_emby_client {
    default 0;
    "~*(Hills|yamby|Afuse|Capy|Fileball|Infuse|SenPlayer|VLC|VidHub|Emby|Android|iOS)" 1;
}
EOF
    [[ ! -f "$HOME/.acme.sh/acme.sh" ]] && curl https://get.acme.sh | sh -s email="admin@google.com"
    source "$HOME/.acme.sh/acme.sh.env" || true
    echo -e "${GREEN}环境初始化完成。${NC}"
}

# --- [阶段二] 证书资产三级预检 (防重复申请) ---
check_ssl_assets() {
    local DOMAIN=$1
    local TARGET_CERT="$SSL_DIR/$DOMAIN/fullchain.pem"
    local ACME_HOME_CERT="$HOME/.acme.sh/${DOMAIN}_ecc/fullchain.cer"
    
    echo -e "${CYAN}检查 VPS 本地资产...${NC}"

    # 1. 检查 Nginx 部署目录
    if [[ -f "$TARGET_CERT" ]]; then
        if openssl x509 -checkend 604800 -noout -in "$TARGET_CERT"; then
            echo -e "${GREEN}命中部署目录有效证书。${NC}"
            return 0
        fi
    fi

    # 2. 检查 acme.sh 家目录
    if [[ -f "$ACME_HOME_CERT" ]]; then
        if openssl x509 -checkend 604800 -noout -in "$ACME_HOME_CERT"; then
            echo -e "${YELLOW}命中 acme.sh 目录有效资产，正在同步安装...${NC}"
            mkdir -p "$SSL_DIR/$DOMAIN"
            "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" \
                --key-file "$SSL_DIR/$DOMAIN/privkey.pem" \
                --fullchain-file "$SSL_DIR/$DOMAIN/fullchain.pem" \
                --reloadcmd "systemctl reload nginx"
            return 0
        fi
    fi
    return 1
}

# --- [阶段三] NAT 适配申请逻辑 (支持自定义端口) ---
request_cert() {
    local DOMAIN=$1
    local ACME="$HOME/.acme.sh/acme.sh"

    echo -e "${YELLOW}进入联网申请模式 (NAT 适配)...${NC}"
    echo "1) HTTP Standalone (自定义端口模式 - 解决 80 占用)"
    echo "2) Cloudflare DNS (无需端口验证 - 推荐模式)"
    read -p "选择模式 [1-2]: " MODE

    if [[ "$MODE" == "2" ]]; then
        read -p "CF API Token: " CF_Token
        export CF_Token="$CF_Token"
        $ACME --issue --dns dns_cf -d "$DOMAIN" --force --debug
    else
        read -p "请输入映射到内网的验证端口 (默认 80): " HTTP_PORT
        HTTP_PORT=${HTTP_PORT:-80}
        
        echo -e "${CYAN}使用端口 $HTTP_PORT 进行申请...${NC}"
        # 如果是 80 端口，尝试释放；如果是非标端口，直接运行
        if [[ "$HTTP_PORT" == "80" ]]; then
            local PID=$(lsof -t -i:80 || true)
            [[ -n "$PID" ]] && systemctl stop nginx || true
        fi
        
        # 核心：使用 --httpport 参数适配 NAT 转发
        $ACME --issue -d "$DOMAIN" --standalone --httpport "$HTTP_PORT" --force --debug || {
            echo -e "${RED}申请失败！请检查 $HTTP_PORT 是否在 NAT 后台正确映射。${NC}"
            [[ "$HTTP_PORT" == "80" ]] && systemctl start nginx || true
            exit 1
        }
        [[ "$HTTP_PORT" == "80" ]] && systemctl start nginx || true
    fi

    # 安装证书
    mkdir -p "$SSL_DIR/$DOMAIN"
    $ACME --install-cert -d "$DOMAIN" \
        --key-file "$SSL_DIR/$DOMAIN/privkey.pem" \
        --fullchain-file "$SSL_DIR/$DOMAIN/fullchain.pem" \
        --reloadcmd "systemctl reload nginx"
}

# --- [阶段四] Nginx 部署 (严格对齐项目方参数) ---
deploy_nginx() {
    local TYPE=$1
    local DOMAIN=$2
    local CONF="/etc/nginx/conf.d/emby_${TYPE}_${DOMAIN}.conf"
    local PREFIX="/"
    [[ "$TYPE" == "universal" ]] && PREFIX="/custom"

    cat > "$CONF" << EOF
server {
    listen 80;
    listen 443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate $SSL_DIR/$DOMAIN/fullchain.pem;
    ssl_certificate_key $SSL_DIR/$DOMAIN/privkey.pem;

    if (\$scheme = http) { return 301 https://\$host\$request_uri; }

    error_page 404 /emby-404.html;
    location = /emby-404.html { root $HTML_DIR; internal; }

    location / {
        if (\$is_emby_client = 0) { return 404; }

        proxy_pass http://127.0.0.1:8080;
        
        # --- 项目要求 5 项 Header ---
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-Prefix $PREFIX;

        # --- 性能优化 ---
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
    # 万能反代路径正则注入
    [[ "$TYPE" == "universal" ]] && sed -i "/location \/ {/i \    location ~* \"^/(?<raw_proto>https?|wss?)://(?<raw_target>[a-zA-Z0-9\\\\.-]+)(?:[:/_](?<raw_port>\\\\d+))?(?<raw_path>/.*)?$\" { if (\$is_emby_client = 0) { return 404; } proxy_pass http://127.0.0.1:8080; proxy_set_header Host \$http_host; proxy_set_header X-Forwarded-Proto \$scheme; proxy_set_header X-Forwarded-Host \$http_host; proxy_set_header X-Forwarded-Prefix /custom; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \"upgrade\"; proxy_buffering off; proxy_max_temp_file_size 0; }" "$CONF"

    nginx -t && systemctl restart nginx
    echo -e "${GREEN}部署完成。${NC}"
}

# --- 后台服务管理 ---
setup_service() {
    curl -sLo "$PROXY_BIN" "$REPO_RAW_URL/emby-proxy"
    curl -sLo "$PROXY_CONF" "$REPO_RAW_URL/config.json"
    chmod +x "$PROXY_BIN"
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Emby Proxy Service
After=network.target
[Service]
Type=simple
WorkingDirectory=/usr/local/bin
ExecStart=$PROXY_BIN -config $PROXY_CONF
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable emby-proxy && systemctl restart emby-proxy
    echo -e "${GREEN}服务已拉取并启动。${NC}"
}

# --- 卸载 ---
uninstall() {
    systemctl stop emby-proxy || true
    rm -f "$SERVICE_FILE" "$PROXY_BIN" "$PROXY_CONF" /etc/nginx/conf.d/emby_*.conf "$MAP_CONF"
    rm -rf "$SSL_DIR" "$HTML_DIR"
    echo -e "${GREEN}项目已完整卸载。${NC}"
}

# --- 菜单 ---
while true; do
    clear
    echo -e "${CYAN}--- NAT Gateway Manager (Manual Port) ---${NC}"
    echo "1) 环境初始化"
    echo "2) 同步资源并启动服务"
    echo "3) 部署 [万能反代] (含预检+自定义端口)"
    echo "4) 部署 [单站反代] (含预检+自定义端口)"
    echo "5) 彻底卸载"
    echo "q) 退出"
    read -p "指令: " OPT
    case $OPT in
        1) init_env ;;
        2) setup_service ;;
        3|4) 
            read -p "域名: " D
            check_ssl_assets "$D" || request_cert "$D"
            [[ "$OPT" == "3" ]] && deploy_nginx "universal" "$D" || deploy_nginx "single" "$D"
            ;;
        5) uninstall ;;
        q) exit 0 ;;
    esac
    read -p "操作完成，按回车返回菜单..."
done
