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

    if [[ ! -f "$ACME" ]]; then
        echo -e "\( {YELLOW}acme.sh 未检测到，正在重新安装... \){NC}"
        curl https://get.acme.sh | sh -s email="admin@example.com" --force
        sleep 2
    fi

    if [[ -f "$HOME/.acme.sh/acme.sh.env" ]]; then
        source "$HOME/.acme.sh/acme.sh.env" 2>/dev/null || true
    fi
    export PATH="$HOME/.acme.sh:$PATH"

    echo -e "\( {CYAN}选择证书申请模式: \){NC}"
    echo "1) Cloudflare DNS (推荐)"
    echo "2) HTTP Standalone"
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

    echo -e "\( {GREEN}证书申请/安装完成！ \){NC}"
}

# --- [3] Nginx 部署（仅在此处新增 systemd 自启动服务）---
deploy_nginx() {
    local TYPE=$1; local D=$2
    local CONF="/etc/nginx/conf.d/emby_\( {TYPE}_ \){D}.conf"

    cat > "$CONF.tmp" << 'EOF'
server {
    listen 443 ssl http2;
    server_name __DOMAIN__;
    ssl_certificate /etc/nginx/ssl/__DOMAIN__/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/__DOMAIN__/privkey.pem;

    resolver 8.8.8.8 1.1.1.1 valid=30s;

    proxy_buffering off;
    proxy_request_buffering off;
    proxy_max_temp_file_size 0;

    error_page 403 /emby-404.html;
    if ($is_emby_client = 0) { return 403; }

    location = /emby-404.html {
        root /etc/nginx;
        internal;
    }
EOF

    if [[ "$TYPE" == "universal" ]]; then
        cat >> "$CONF.tmp" << 'EOF'

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_max_temp_file_size 0;
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $http_host;
        proxy_set_header X-Forwarded-Port $server_port;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
    else
        echo -e "\( {CYAN}=== 单站多 Emby 服务配置（互动模式）=== \){NC}"
        echo "请逐个添加 Emby 服务，输入空路径前缀时结束。"

        local count=1
        while true; do
            echo -e "\n${YELLOW}第 \( {count} 个 Emby 服务 \){NC}"
            read -p "路径前缀 (例如 /emby1 或 /media，直接回车结束): " PREFIX
            [[ -z "$PREFIX" ]] && break
            [[ "${PREFIX:0:1}" != "/" ]] && PREFIX="/$PREFIX"

            read -p "目标后端地址 (例如 https://emby1.example.com): " TARGET

            cat >> "$CONF.tmp" << EOF

    location \~* ^${PREFIX}(/.*)?\$ {
        proxy_pass ${TARGET};
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_max_temp_file_size 0;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
EOF
            count=$((count + 1))
        done

        cat >> "$CONF.tmp" << 'EOF'

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_max_temp_file_size 0;
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $http_host;
        proxy_set_header X-Forwarded-Port $server_port;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
    fi

    sed "s|__DOMAIN__|$D|g" "$CONF.tmp" > "$CONF"
    rm -f "$CONF.tmp"

    # 启动 emby-proxy（如果未运行）
    if ! pgrep -f emby-proxy >/dev/null; then
        echo -e "\( {YELLOW}正在启动 emby-proxy... \){NC}"
        nohup "$PROXY_BIN" > "$LOG_FILE" 2>&1 &
        echo -e "\( {GREEN}emby-proxy 已启动。 \){NC}"
    fi

    # === 新增：创建 systemd 自启动服务 ===
    if [[ ! -f "$SERVICE_FILE" ]]; then
        echo -e "\( {YELLOW}正在创建 emby-proxy systemd 自启动服务... \){NC}"
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
        echo -e "\( {RED}Nginx 配置测试失败！ \){NC}"
        rm -f "$CONF"
        return 1
    fi
}

# --- 配置管理 ---
manage_config() {
    echo -e "\( {CYAN}=== 当前 emby 配置 === \){NC}"
    ls /etc/nginx/conf.d/emby_*.conf 2>/dev/null || echo "暂无配置"

    echo -e "\n1) 删除指定域名配置"
    echo "2) 添加/修改/覆盖域名"
    echo "3) 返回"
    read -p "选择: " MOPT

    case $MOPT in
        1)
            read -p "输入要删除的域名: " DEL_D
            rm -f /etc/nginx/conf.d/emby_*_"$DEL_D".conf
            echo -e "\( {GREEN}已删除。 \){NC}"
            ;;
        2)
            read -p "输入域名: " D
            if check_cert "$D"; then
                echo "1) 万能反代"
                echo "2) 单站反代（互动式）"
                read -p "选择: " T
                [[ "$T" == "1" ]] && deploy_nginx "universal" "$D" || deploy_nginx "single" "$D"
            fi
            ;;
    esac
}

# --- 菜单 ---
while true; do
    clear
    echo -e "\( {CYAN}--- NAT Pro Manager V5 (已集成 systemd 自启动) --- \){NC}"
    echo "1) 环境初始化"
    echo "2) 申请/重签证书"
    echo "3) 部署 [万能反代]"
    echo "4) 部署 [单站反代]（互动式多 Emby 服务）"
    echo "5) 配置管理（添加/修改/覆盖/删除）"
    echo "6) 彻底卸载"
    read -p "指令: " OPT
    case $OPT in
        1) init_env ;;
        2) read -p "域名: " D; apply_cert "$D" ;;
        3) 
            D="auto2.oneq1st.dpdns.org"
            if check_cert "$D"; then deploy_nginx "universal" "$D"; fi
            ;;
        4) 
            read -p "单站反代域名: " D
            if check_cert "$D"; then deploy_nginx "single" "$D"; fi
            ;;
        5) manage_config ;;
        6) 
            echo -e "\( {RED}正在彻底卸载... \){NC}"
            rm -rf "$SSL_DIR" "$PROXY_BIN" "$NOT_FOUND_HTML"
            rm -f /etc/nginx/conf.d/emby_*.conf
            systemctl stop emby-proxy.service 2>/dev/null || true
            systemctl disable emby-proxy.service 2>/dev/null || true
            rm -f "$SERVICE_FILE"
            pkill -f emby-proxy || true
            systemctl daemon-reload
            systemctl restart nginx
            echo -e "\( {GREEN}卸载完成。 \){NC}"
            ;;
        *) exit 0 ;;
    esac
    read -p "回车继续..."
done
