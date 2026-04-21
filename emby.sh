#!/bin/bash
set -e

# --- [基础定义] 100% 对齐项目路径 ---
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

# --- [1] 资产三级预检 (VPS Check 核心逻辑) ---
check_ssl_assets() {
    local DOMAIN=$1
    local TARGET_CERT="$SSL_DIR/$DOMAIN/fullchain.pem"
    local ACME_HOME_CERT="$HOME/.acme.sh/${DOMAIN}_ecc/fullchain.cer"
    
    echo -e "${CYAN}正在执行本地资产预检，防止无效申请...${NC}"

    # 1. 检查 Nginx 部署目录证书 (效期 > 7天)
    if [[ -f "$TARGET_CERT" ]]; then
        if openssl x509 -checkend 604800 -noout -in "$TARGET_CERT"; then
            echo -e "${GREEN}一级命中：VPS 部署目录已有有效证书，直接跳过验证流程。${NC}"
            return 0
        fi
    fi

    # 2. 检查 acme.sh 默认保存目录 (防止已申请未同步)
    if [[ -f "$ACME_HOME_CERT" ]]; then
        if openssl x509 -checkend 604800 -noout -in "$ACME_HOME_CERT"; then
            echo -e "${YELLOW}二级命中：acme.sh 目录发现有效资产，正在同步安装...${NC}"
            mkdir -p "$SSL_DIR/$DOMAIN"
            "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" \
                --key-file "$SSL_DIR/$DOMAIN/privkey.pem" \
                --fullchain-file "$TARGET_CERT" \
                --reloadcmd "systemctl reload nginx"
            return 0
        fi
    fi

    echo -e "${RED}三级预检结束：本地无可用资产，必须启动联网验证。${NC}"
    return 1
}

# --- [2] 强化申请逻辑 (NAT 映射与 DNS Token 防冲突) ---
request_cert_pro() {
    local DOMAIN=$1
    local ACME="$HOME/.acme.sh/acme.sh"
    
    echo -e "${CYAN}请根据 VPS 网络环境选择申请模式:${NC}"
    echo "1) Cloudflare DNS 模式 (NAT机首选，需 Token 具备 DNS编辑+区域读取权限)"
    echo "2) HTTP Standalone 模式 (需 NAT 面板将公网 80 转发至内网端口)"
    read -p "选择 [1-2]: " MODE

    if [[ "$MODE" == "1" ]]; then
        # 强制清理环境变量，防止 acme.sh 混淆 CF_Key 和 CF_Token
        unset CF_Key; unset CF_Email; unset CF_Account_ID;
        read -p "请输入 Cloudflare API Token: " USER_TOKEN
        export CF_Token="$USER_TOKEN"
        
        echo -e "${YELLOW}正在尝试 DNS 验证 (自动处理 Zone ID)...${NC}"
        "$ACME" --issue --dns dns_cf -d "$DOMAIN" --force --debug || {
            echo -e "${RED}申请失败！请检查 Token 权限是否包含：[Zone.DNS:Edit] 和 [Zone.Zone:Read]${NC}"
            exit 1
        }
    else
        read -p "请输入映射到公网 80 的内网端口 (例如 40890): " NAT_PORT
        NAT_PORT=${NAT_PORT:-80}
        
        # 强制清理端口占用，防止申请程序启动失败
        fuser -k "${NAT_PORT}/tcp" || true
        
        echo -e "${YELLOW}正在通过端口 $NAT_PORT 进行独立验证...${NC}"
        "$ACME" --issue -d "$DOMAIN" --standalone --httpport "$NAT_PORT" --force --debug || {
            echo -e "${RED}验证失败！请确保 NAT 面板已将 公网80 映射到本机的 $NAT_PORT${NC}"
            exit 1
        }
    fi

    # 证书申请成功，执行安装
    mkdir -p "$SSL_DIR/$DOMAIN"
    "$ACME" --install-cert -d "$DOMAIN" \
        --key-file "$SSL_DIR/$DOMAIN/privkey.pem" \
        --fullchain-file "$SSL_DIR/$DOMAIN/fullchain.pem" \
        --reloadcmd "systemctl reload nginx"
}

# --- [3] Nginx 配置生成 (严格对齐项目核心 Header) ---
deploy_nginx_final() {
    local TYPE=$1; local DOMAIN=$2
    local TARGET_CONF="/etc/nginx/conf.d/emby_${TYPE}_${DOMAIN}.conf"
    local PREFIX="/"; [[ "$TYPE" == "universal" ]] && PREFIX="/custom"

    echo -e "${CYAN}生成配置中，正在检查项目核心参数...${NC}"
    cat > "$TARGET_CONF" << EOF
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
        
        # --- 项目要求 5 项核心 Header ---
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-Prefix $PREFIX;

        # --- 性能优化 (推流核心) ---
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_max_temp_file_size 0;
        
        # --- WebSocket 支持 ---
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        proxy_read_timeout 600s;
        tcp_nodelay on;
    }
}
EOF
    # 万能模式正则路径动态插入 (严禁丢失)
    if [[ "$TYPE" == "universal" ]]; then
        sed -i "/location \/ {/i \    location ~* \"^/(?<raw_proto>https?|wss?)://(?<raw_target>[a-zA-Z0-9\\\\.-]+)(?:[:/_](?<raw_port>\\\\d+))?(?<raw_path>/.*)?$\" { if (\$is_emby_client = 0) { return 404; } proxy_pass http://127.0.0.1:8080; proxy_set_header Host \$http_host; proxy_set_header X-Forwarded-Proto \$scheme; proxy_set_header X-Forwarded-Host \$http_host; proxy_set_header X-Forwarded-Prefix /custom; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \"upgrade\"; proxy_buffering off; proxy_max_temp_file_size 0; }" "$TARGET_CONF"
    fi

    nginx -t && systemctl restart nginx
    echo -e "${GREEN}Nginx 配置已部署生效。${NC}"
}

# --- [4] 主控菜单 ---
while true; do
    clear
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${CYAN}   Emby Gateway 2026 (NAT/DNS 增强版)    ${NC}"
    echo -e "${CYAN}==========================================${NC}"
    echo "1) 初始化环境 (Nginx/acme.sh/Lsof)"
    echo "2) 同步 GitHub 服务组件"
    echo "3) 部署 [万能反代] (含资产预检+强申)"
    echo "4) 部署 [单站反代] (含资产预检+强申)"
    echo "5) 彻底卸载清理"
    echo "q) 退出"
    echo -e "${CYAN}------------------------------------------${NC}"
    read -p "指令: " OPT
    case $OPT in
        1) apt update && apt install -y nginx-full curl openssl socat psmisc lsof
           [[ ! -f "$HOME/.acme.sh/acme.sh" ]] && curl https://get.acme.sh | sh -s email="admin@google.com" ;;
        2) curl -sLo "$PROXY_BIN" "$REPO_RAW_URL/emby-proxy" && chmod +x "$PROXY_BIN" ;;
        3|4) 
            read -p "绑定域名: " D
            # 逻辑：检查本地资产 -> 命中则直接部署，不命中则联网申请
            check_ssl_assets "$D" || request_cert_pro "$D"
            [[ "$OPT" == "3" ]] && deploy_nginx_final "universal" "$D" || deploy_nginx_final "single" "$D"
            ;;
        5) rm -rf "$SSL_DIR" /etc/nginx/conf.d/emby_*.conf && systemctl restart nginx ;;
        q) exit 0 ;;
    esac
    read -p "按回车继续..."
done
