#!/bin/bash
set -e

# --- 基础定义 ---
REPO_RAW_URL="https://raw.githubusercontent.com/OneQ1st/emby/main"
PROXY_BIN="/usr/local/bin/emby-proxy"
SSL_DIR="/etc/nginx/ssl"
MAP_CONF="/etc/nginx/conf.d/emby_maps.conf"
NOT_FOUND_HTML="/etc/nginx/emby-404.html"
ACME="$HOME/.acme.sh/acme.sh"
LOG_FILE="/var/log/emby-proxy.log"
SERVICE_FILE="/etc/systemd/system/emby-proxy.service"

# --- 颜色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- [1] 初始化环境 ---
init_env() {
    echo -e "${CYAN}正在初始化环境并下载 emby-proxy 二进制... ${NC}"
    apt update && apt install -y nginx-full curl openssl socat psmisc lsof cron wget ca-certificates

    systemctl enable --now cron

    echo -e "${YELLOW}正在下载 emby-proxy 二进制文件... ${NC}"
    curl -sLo "$PROXY_BIN" "$REPO_RAW_URL/emby-proxy" && chmod +x "$PROXY_BIN"
    
    echo -e "${YELLOW}正在下载 emby-404.html... ${NC}"
    curl -sLo "$NOT_FOUND_HTML" "$REPO_RAW_URL/emby-404.html"

    cat > "$MAP_CONF" << 'EOF'
map $http_upgrade $connection_upgrade { default upgrade; '' close; }
map $http_user_agent $is_emby_client {
    default 0;
    "\~*(Hills|yamby|Afuse|Capy)" 1;
}
EOF

    echo -e "${GREEN}环境初始化完成。 ${NC}"
}

# --- 检查证书 ---
check_cert() {
    local D=$1
    if [[ -f "$SSL_DIR/$D/fullchain.pem" ]]; then
        echo -e "${GREEN}检测到域名 \( D 已存在证书。 \){NC}"
        return 0
    else
        echo -e "${YELLOW}未检测到域名 \( D 的证书，请先执行选项 2 申请。 \){NC}"
        return 1
    fi
}

# --- [2] 证书申请 ---
apply_cert() {
    local D=$1
    echo -e "${CYAN}选择证书申请模式: ${NC}"
    echo "1) Cloudflare DNS (推荐)"
    echo "2) HTTP Standalone (需 NAT 80 端口转发)"
    read -p "选择: " M
    
    if [[ "$M" == "1" ]]; then
        read -p "请输入 CF_Token: " CF_T
        export CF_Token="$CF_T"
        "$ACME" --issue --dns dns_cf -d "$D" --force
    else
        read -p "请输入 NAT 映射到本机的 80 验证端口: " P
        fuser -k "${P:-80}/tcp" || true
        "$ACME" --issue -d "\( D" --standalone --httpport " \){P:-80}" --force
    fi

    mkdir -p "$SSL_DIR/$D"
    "$ACME" --install-cert -d "$D" \
        --key-file "$SSL_DIR/$D/privkey.pem" \
        --fullchain-file "$SSL_DIR/$D/fullchain.pem" \
        --reloadcmd "systemctl reload nginx"
}

# --- [3] Nginx 部署（添加 40889 + Authorization + 自启动）---
deploy_nginx() {
    local TYPE=$1; local D=$2
    local CONF="/etc/nginx/conf.d/emby_\( {TYPE}_ \){D}.conf"
    local TARGET=""
    local PATH_SUFFIX=""

    if [[ "$TYPE" == "single" ]]; then
        read -p "请输入单站目标后端地址 (例如 https://m.mobaiemby.site): " TARGET
        [[ -z "$TARGET" ]] && TARGET="http://127.0.0.1:8080"
        
        read -p "请输入路径后缀（可选，例如 /emby，直接回车表示无后缀）: " PATH_SUFFIX
        [[ -z "$PATH_SUFFIX" ]] && PATH_SUFFIX="/"
        [[ "${PATH_SUFFIX:0:1}" != "/" ]] && PATH_SUFFIX="/$PATH_SUFFIX"
    fi

    cat > "$CONF.tmp" << 'EOF'
server {
    listen 443 ssl http2;
    listen 40889 ssl http2;   # 运营商映射的外部端口
    server_name __DOMAIN__;
    ssl_certificate /etc/nginx/ssl/__DOMAIN__/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/__DOMAIN__/privkey.pem;

    resolver 8.8.8.8 1.1.1.1 valid=30s;

    proxy_buffering off;
    proxy_request_buffering off;
    proxy_max_temp_file_size 0;

    error_page 403 /emby-404.html;

    if ($is_emby_client = 0) {
        return 403;
    }

    location = /emby-404.html {
        root /etc/nginx;
        internal;
    }

    location / {
EOF

    if [[ "$TYPE" == "universal" ]]; then
        cat >> "$CONF.tmp" << 'EOF'
        proxy_pass http://127.0.0.1:8080/;
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $http_host;
        proxy_set_header X-Forwarded-Port $server_port;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        # 传递 Basic Auth（解决 401）
        proxy_set_header Authorization $http_authorization;
EOF
    else
        cat >> "$CONF.tmp" << 'EOF'
        proxy_pass __TARGET____PATH_SUFFIX__;
        proxy_set_header Host $proxy_host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $http_host;
        proxy_set_header X-Forwarded-Port $server_port;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        proxy_set_header Authorization $http_authorization;
EOF
    fi

    cat >> "$CONF.tmp" << 'EOF'
    }
}
EOF

    sed "s|__DOMAIN__|$D|g" "$CONF.tmp" > "$CONF"

    if [[ "$TYPE" == "single" ]]; then
        sed -i "s|__TARGET__|$TARGET|g" "$CONF"
        sed -i "s|__PATH_SUFFIX__|$PATH_SUFFIX|g" "$CONF"
    fi

    rm -f "$CONF.tmp"

    # 启动 emby-proxy
    if [[ "$TYPE" == "universal" ]] && ! pgrep -f emby-proxy >/dev/null; then
        echo -e "${YELLOW}正在启动 emby-proxy (监听 :8080)... ${NC}"
        nohup "$PROXY_BIN" > "$LOG_FILE" 2>&1 &
        echo -e "${GREEN}emby-proxy 已后台启动。 ${NC}"
    fi

    # 创建 systemd 自启动服务
    if [[ ! -f "$SERVICE_FILE" ]]; then
        cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Emby Reverse Proxy Service
After=network.target

[Service]
Type=simple
ExecStart=$PROXY_BIN
WorkingDirectory=/usr/local/bin
Restart=always
RestartSec=5
User=root
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now emby-proxy.service
        echo -e "\( {GREEN}emby-proxy 已设置为开机自启动。 \){NC}"
    fi

    if nginx -t; then
        systemctl restart nginx
        echo -e "\( {GREEN}部署成功！ \){NC}"
    else
        echo -e "${RED}Nginx 配置测试失败！请检查 /etc/nginx/conf.d/ 下的配置。 ${NC}"
        rm -f "$CONF"
        return 1
    fi
}

# --- 菜单 ---
while true; do
    clear
    echo -e "${CYAN}--- NAT Pro Manager V5 (map_hash + root 已修复 + 自启动) --- ${NC}"
    echo "1) 环境初始化（必须先执行）"
    echo "2) 申请/重签证书"
    echo "3) 部署 [万能反代]"
    echo "4) 部署 [单站反代]"
    echo "5) 彻底卸载"
    read -p "指令: " OPT
    case $OPT in
        1) init_env ;;
        2) read -p "域名: " D; apply_cert "$D" ;;
        3) 
            D="auto2.oneq1st.dpdns.org"
            if [[ ! -f "$SSL_DIR/$D/fullchain.pem" ]]; then
                echo -e "${YELLOW}请先执行选项 2 申请证书。 ${NC}"
            else
                deploy_nginx "universal" "$D"
            fi
            ;;
        4) 
            read -p "单站反代域名: " D
            if [[ ! -f "$SSL_DIR/$D/fullchain.pem" ]]; then
                echo -e "${YELLOW}请先执行选项 2 申请证书。 ${NC}"
            else
                deploy_nginx "single" "$D"
            fi
            ;;
        5) 
            rm -rf "$SSL_DIR" "$PROXY_BIN" "$NOT_FOUND_HTML"
            rm -f /etc/nginx/conf.d/emby_*.conf
            systemctl stop emby-proxy.service 2>/dev/null || true
            systemctl disable emby-proxy.service 2>/dev/null || true
            rm -f "$SERVICE_FILE"
            pkill -f emby-proxy || true
            systemctl restart nginx 
            echo -e "${GREEN}卸载完成。 ${NC}"
            ;;
        *) exit 0 ;;
    esac
    read -p "回车继续..."
done
