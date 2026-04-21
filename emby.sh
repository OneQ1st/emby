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

# --- 颜色输出 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 权限运行${NC}" && exit 1

# --- [阶段一] 环境初始化 (安装分离) ---
init_env() {
    echo -e "${CYAN}正在初始化基础环境 (Nginx, acme.sh, 依赖库)...${NC}"
    apt update && apt install -y nginx-full curl openssl sed socat cron wget
    mkdir -p "$HTML_DIR" "$SSL_DIR" "/var/www/html"
    
    # 静态资源同步
    curl -sLo "$HTML_FILE" "$REPO_RAW_URL/emby-404.html" || echo "警告：404页面同步失败"
    
    # Nginx 全局映射配置
    cat > "$MAP_CONF" << EOF
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
map \$http_user_agent \$is_emby_client {
    default 0;
    "~*(Hills|yamby|Afuse|Capy|Fileball|Infuse|SenPlayer|VLC|VidHub|Emby|Android|iOS)" 1;
}
EOF
    # 安装 acme.sh 并尝试载入环境
    [[ ! -f "$HOME/.acme.sh/acme.sh" ]] && curl https://get.acme.sh | sh -s email="admin@google.com"
    source "$HOME/.acme.sh/acme.sh.env" || true
    echo -e "${GREEN}环境初始化完成。${NC}"
}

# --- [阶段二] 证书业务核心：本地扫描与容错申请 ---
handle_ssl() {
    local DOMAIN=$1
    local CERT_PATH="$SSL_DIR/$DOMAIN/fullchain.pem"
    local KEY_PATH="$SSL_DIR/$DOMAIN/privkey.pem"
    local ACME="$HOME/.acme.sh/acme.sh"

    echo -e "${CYAN}--- 证书业务流程: $DOMAIN ---${NC}"

    # 1. 检查 VPS 本地是否已有证书 (无论是否由本脚本生成)
    if [[ -f "$CERT_PATH" && -f "$KEY_PATH" ]]; then
        echo -e "${YELLOW}检测到本地已存在证书文件，执行效期评估...${NC}"
        # 效期评估：14天 (1209600秒) 为阈值
        if openssl x509 -checkend 1209600 -noout -in "$CERT_PATH"; then
            echo -e "${GREEN}本地证书状态良好 (有效期 > 14天)，直接复用。${NC}"
            CUR_FULL="$CERT_PATH"
            CUR_KEY="$KEY_PATH"
            return 0
        else
            echo -e "${RED}警告：本地证书即将过期或已失效，准备触发续期/申请流程。${NC}"
        fi
    fi

    # 2. 申请流程 (提供降级方案)
    echo -e "${CYAN}请选择申请验证模式:${NC}"
    echo "1) HTTP Webroot (最稳妥，需域名 A 记录已解析到本 VPS)"
    echo "2) Cloudflare DNS (支持通配符，需 API Token)"
    read -p "选择 [1-2]: " SSL_MODE

    if [[ "$SSL_MODE" == "2" ]]; then
        read -p "CF API Token: " CF_Token
        export CF_Token="$CF_Token"
        "$ACME" --issue --dns dns_cf -d "$DOMAIN" --force
    else
        # 尝试通过临时 Nginx 规则申请
        cat > /etc/nginx/conf.d/acme_temp.conf << EOF
server { listen 80; server_name $DOMAIN; location /.well-known/acme-challenge/ { root /var/www/html; } }
EOF
        systemctl reload nginx
        "$ACME" --issue -d "$DOMAIN" --webroot /var/www/html --force || {
            echo -e "${YELLOW}Webroot 验证受阻，尝试 Standalone 模式 (需短暂停服务)...${NC}"
            systemctl stop nginx
            "$ACME" --issue -d "$DOMAIN" --standalone --force
            systemctl start nginx
        }
        rm -f /etc/nginx/conf.d/acme_temp.conf
    fi

    # 3. 安装证书并注册 Nginx 联动
    mkdir -p "$SSL_DIR/$DOMAIN"
    "$ACME" --install-cert -d "$DOMAIN" \
        --key-file "$KEY_PATH" \
        --fullchain-file "$CERT_PATH" \
        --reloadcmd "systemctl reload nginx"
    
    CUR_FULL="$CERT_PATH"
    CUR_KEY="$KEY_PATH"
    echo -e "${GREEN}证书业务处理成功。${NC}"
}

# --- [阶段三] Nginx 配置部署 (对齐项目参数) ---
deploy_nginx() {
    local TYPE=$1
    local DOMAIN=$2
    local TARGET_CONF="/etc/nginx/conf.d/emby_${TYPE}_${DOMAIN}.conf"
    local PREFIX="/"
    [[ "$TYPE" == "universal" ]] && PREFIX="/custom"

    echo -e "${CYAN}正在应用 Nginx 配置模板...${NC}"
    cat > "$TARGET_CONF" << EOF
server {
    listen 80;
    listen 443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate $CUR_FULL;
    ssl_certificate_key $CUR_KEY;
    
    # 强制安全连接
    if (\$scheme = http) { return 301 https://\$host\$request_uri; }

    error_page 404 /emby-404.html;
    location = /emby-404.html { root $HTML_DIR; internal; }

    location / {
        if (\$is_emby_client = 0) { return 404; }

        proxy_pass http://127.0.0.1:8080;
        
        # --- 项目核心参数对齐 ---
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-Prefix $PREFIX;

        # 稳定性优化 (禁用缓冲)
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_max_temp_file_size 0;
        
        # 协议升级 (WebSocket)
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        proxy_read_timeout 600s;
        tcp_nodelay on;
    }
}
EOF
    # 万能反代路径正则注入
    [[ "$TYPE" == "universal" ]] && sed -i "/location \/ {/i \    location ~* \"^/(?<raw_proto>https?|wss?)://(?<raw_target>[a-zA-Z0-9\\\\.-]+)(?:[:/_](?<raw_port>\\\\d+))?(?<raw_path>/.*)?$\" { if (\$is_emby_client = 0) { return 404; } proxy_pass http://127.0.0.1:8080; proxy_set_header Host \$http_host; proxy_set_header X-Forwarded-Proto \$scheme; proxy_set_header X-Forwarded-Host \$http_host; proxy_set_header X-Forwarded-Prefix /custom; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \"upgrade\"; proxy_buffering off; proxy_max_temp_file_size 0; }" "$TARGET_CONF"

    nginx -t && systemctl restart nginx
    echo -e "${GREEN}Nginx 部署完成。${NC}"
}

# --- [阶段四] 后台服务同步与自启动 ---
setup_service() {
    echo -e "${CYAN}同步资源并配置自启动服务...${NC}"
    curl -sLo "$PROXY_BIN" "$REPO_RAW_URL/emby-proxy"
    curl -sLo "$PROXY_CONF" "$REPO_RAW_URL/config.json"
    chmod +x "$PROXY_BIN"

    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Emby Reverse Proxy Service
After=network.target

[Service]
Type=simple
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
    echo -e "${GREEN}后台服务管理已生效。${NC}"
}

# --- [阶段五] 卸载选项 ---
uninstall() {
    echo -e "${RED}卸载所有组件与配置...${NC}"
    systemctl stop emby-proxy || true
    systemctl disable emby-proxy || true
    rm -f "$SERVICE_FILE" "$PROXY_BIN" "$PROXY_CONF" /etc/nginx/conf.d/emby_*.conf "$MAP_CONF"
    rm -rf "$SSL_DIR" "$HTML_DIR"
    systemctl daemon-reload && systemctl restart nginx
    echo -e "${GREEN}卸载完成。${NC}"
}

# --- 主控菜单 ---
while true; do
    clear
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${CYAN}   Emby Gateway 终极管理器 (全业务感知)  ${NC}"
    echo -e "${CYAN}==========================================${NC}"
    echo "1) 初始化环境 (安装依赖)"
    echo "2) 启动/更新后台服务 (GitHub 同步)"
    echo "3) 部署 [万能反代] (自动预检证书)"
    echo "4) 部署 [单站反代] (自动预检证书)"
    echo "5) 彻底卸载项目"
    echo "q) 退出"
    echo -e "${CYAN}------------------------------------------${NC}"
    read -p "请输入指令 [1-5/q]: " OPT
    case $OPT in
        1) init_env ;;
        2) setup_service ;;
        3) read -p "绑定域名: " D; handle_ssl "$D"; deploy_nginx "universal" "$D" ;;
        4) read -p "绑定域名: " D; handle_ssl "$D"; deploy_nginx "single" "$D" ;;
        5) uninstall ;;
        q) exit 0 ;;
        *) echo "无效指令" ;;
    esac
done
