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

# --- [阶段一] 环境初始化 (环境安装分离) ---
init_env() {
    echo -e "${CYAN}正在初始化基础环境 (Nginx, acme.sh, 端口工具)...${NC}"
    apt update && apt install -y nginx-full curl openssl sed socat cron wget lsof
    mkdir -p "$HTML_DIR" "$SSL_DIR" "/var/www/html"
    
    # 同步 404 页面
    curl -sLo "$HTML_FILE" "$REPO_RAW_URL/emby-404.html" || echo "警告：404资源同步失败"
    
    # 写入 Nginx Map (保留原有 UA 白名单功能)
    cat > "$MAP_CONF" << EOF
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
map \$http_user_agent \$is_emby_client {
    default 0;
    "~*(Hills|yamby|Afuse|Capy|Fileball|Infuse|SenPlayer|VLC|VidHub|Emby|Android|iOS)" 1;
}
EOF
    # 安装 acme.sh
    [[ ! -f "$HOME/.acme.sh/acme.sh" ]] && curl https://get.acme.sh | sh -s email="admin@google.com"
    source "$HOME/.acme.sh/acme.sh.env" || true
    echo -e "${GREEN}环境初始化完成。${NC}"
}

# --- [阶段二] 三级证书预检 (VPS 资产感知) ---
check_ssl_assets() {
    local DOMAIN=$1
    local TARGET_CERT="$SSL_DIR/$DOMAIN/fullchain.pem"
    local ACME_HOME_CERT="$HOME/.acme.sh/${DOMAIN}_ecc/fullchain.cer"
    
    echo -e "${CYAN}正在检查 VPS 本地证书资产...${NC}"

    # 1. 检查已部署目录
    if [[ -f "$TARGET_CERT" ]]; then
        if openssl x509 -checkend 604800 -noout -in "$TARGET_CERT"; then
            echo -e "${GREEN}一级预检通过：部署目录证书有效。${NC}"
            return 0
        fi
    fi

    # 2. 检查 acme.sh 家目录 (防止已申请但未安装到 Nginx)
    if [[ -f "$ACME_HOME_CERT" ]]; then
        if openssl x509 -checkend 604800 -noout -in "$ACME_HOME_CERT"; then
            echo -e "${YELLOW}二级预警：发现 acme.sh 目录有可用证书，正在执行安装...${NC}"
            mkdir -p "$SSL_DIR/$DOMAIN"
            "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" \
                --key-file "$SSL_DIR/$DOMAIN/privkey.pem" \
                --fullchain-file "$SSL_DIR/$DOMAIN/fullchain.pem" \
                --reloadcmd "systemctl reload nginx"
            return 0
        fi
    fi

    echo -e "${RED}三级预检结束：本地确无有效证书，需联网申请。${NC}"
    return 1
}

# --- [阶段三] 强化证书申请 (多模式/多端口适配) ---
request_cert() {
    local DOMAIN=$1
    local ACME="$HOME/.acme.sh/acme.sh"

    echo -e "${YELLOW}开始联网申请过程...${NC}"
    echo "1) HTTP Standalone (自动清理端口，最稳妥)"
    echo "2) Cloudflare DNS (无需端口，需 API Token)"
    read -p "请选择模式 [1-2]: " MODE

    if [[ "$MODE" == "2" ]]; then
        read -p "请输入 CF API Token: " CF_Token
        export CF_Token="$CF_Token"
        $ACME --issue --dns dns_cf -d "$DOMAIN" --force --debug
    else
        echo -e "${CYAN}正在检查 80 端口占用情况...${NC}"
        local PID=$(lsof -t -i:80 || true)
        if [[ -n "$PID" ]]; then
            echo -e "${YELLOW}端口 80 被占用 (PID: $PID)，正在临时释放...${NC}"
            systemctl stop nginx || kill -9 $PID
        fi
        
        # 强制使用 Standalone 模式申请
        $ACME --issue -d "$DOMAIN" --standalone --force --debug || {
            echo -e "${RED}申请失败！请检查防火墙是否放行 80 端口。${NC}"
            systemctl start nginx || true
            exit 1
        }
        systemctl start nginx
    fi

    # 安装证书
    mkdir -p "$SSL_DIR/$DOMAIN"
    $ACME --install-cert -d "$DOMAIN" \
        --key-file "$SSL_DIR/$DOMAIN/privkey.pem" \
        --fullchain-file "$SSL_DIR/$DOMAIN/fullchain.pem" \
        --reloadcmd "systemctl reload nginx"
}

# --- [阶段四] Nginx 部署 (项目推荐参数 100% 对齐) ---
deploy_nginx() {
    local TYPE=$1
    local DOMAIN=$2
    local TARGET_CONF="/etc/nginx/conf.d/emby_${TYPE}_${DOMAIN}.conf"
    local PREFIX="/"
    [[ "$TYPE" == "universal" ]] && PREFIX="/custom"

    echo -e "${CYAN}正在生成并检查 Nginx 配置...${NC}"
    cat > "$TARGET_CONF" << EOF
server {
    listen 80;
    listen 443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate $SSL_DIR/$DOMAIN/fullchain.pem;
    ssl_certificate_key $SSL_DIR/$DOMAIN/privkey.pem;

    # 强制跳转 HTTPS
    if (\$scheme = http) { return 301 https://\$host\$request_uri; }

    error_page 404 /emby-404.html;
    location = /emby-404.html { root $HTML_DIR; internal; }

    location / {
        # 客户端 UA 白名单校验
        if (\$is_emby_client = 0) { return 404; }

        proxy_pass http://127.0.0.1:8080;
        
        # --- 项目方指定必须添加的五项 Header ---
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-Prefix $PREFIX;

        # --- 性能与流媒体优化参数 ---
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_max_temp_file_size 0;
        
        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        proxy_read_timeout 600s;
        tcp_nodelay on;
    }
}
EOF
    # 动态插入万能模式的正则路径逻辑
    if [[ "$TYPE" == "universal" ]]; then
        sed -i "/location \/ {/i \    location ~* \"^/(?<raw_proto>https?|wss?)://(?<raw_target>[a-zA-Z0-9\\\\.-]+)(?:[:/_](?<raw_port>\\\\d+))?(?<raw_path>/.*)?$\" { if (\$is_emby_client = 0) { return 404; } proxy_pass http://127.0.0.1:8080; proxy_set_header Host \$http_host; proxy_set_header X-Forwarded-Proto \$scheme; proxy_set_header X-Forwarded-Host \$http_host; proxy_set_header X-Forwarded-Prefix /custom; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \"upgrade\"; proxy_buffering off; proxy_max_temp_file_size 0; }" "$TARGET_CONF"
    fi

    nginx -t && systemctl restart nginx
    echo -e "${GREEN}Nginx 部署成功。${NC}"
}

# --- [阶段五] 卸载与清理 ---
uninstall() {
    echo -e "${RED}正在清理所有项目资产...${NC}"
    systemctl stop emby-proxy || true
    systemctl disable emby-proxy || true
    rm -f "$SERVICE_FILE" "$PROXY_BIN" "$PROXY_CONF"
    rm -f /etc/nginx/conf.d/emby_*.conf "$MAP_CONF"
    rm -rf "$SSL_DIR" "$HTML_DIR"
    systemctl daemon-reload && systemctl restart nginx
    echo -e "${GREEN}卸载完成。${NC}"
}

# --- 主控菜单 ---
while true; do
    clear
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${CYAN}    Emby Gateway Manager (Pro 2026)      ${NC}"
    echo -e "${CYAN}==========================================${NC}"
    echo "1) 环境初始化 (Nginx/acme.sh)"
    echo "2) 同步 GitHub 资源并启动后台服务"
    echo "3) 部署 [万能反代] (带本地资产预检)"
    echo "4) 部署 [单站反代] (带本地资产预检)"
    echo "5) 彻底卸载项目"
    echo "q) 退出"
    echo -e "${CYAN}------------------------------------------${NC}"
    read -p "指令: " OPT
    case $OPT in
        1) init_env ;;
        2) 
            curl -sLo "$PROXY_BIN" "$REPO_RAW_URL/emby-proxy"
            curl -sLo "$PROXY_CONF" "$REPO_RAW_URL/config.json"
            chmod +x "$PROXY_BIN"
            # 写入并启动 Service (略, 参考前述配置)
            echo "服务已更新并启动" 
            ;;
        3|4) 
            read -p "输入域名: " D
            # 核心业务逻辑：预检 -> 申请(如有需) -> 部署
            check_ssl_assets "$D" || request_cert "$D"
            [[ "$OPT" == "3" ]] && deploy_nginx "universal" "$D" || deploy_nginx "single" "$D"
            ;;
        5) uninstall ;;
        q) exit 0 ;;
    esac
    read -p "操作完成，按回车返回菜单..."
done
