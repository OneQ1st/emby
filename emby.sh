#!/bin/bash
set -e

# --- 基础路径 (严格对齐项目) ---
REPO_RAW_URL="https://raw.githubusercontent.com/OneQ1st/emby/main"
PROXY_BIN="/usr/local/bin/emby-proxy"
SSL_DIR="/etc/nginx/ssl"
MAP_CONF="/etc/nginx/conf.d/emby_maps.conf"
HTML_DIR="/var/www/emby"
ACME="$HOME/.acme.sh/acme.sh"

# --- 颜色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- [1] 初始化环境 (从 GitHub 拉取所有资源) ---
init_env() {
    echo -e "${CYAN}正在同步 GitHub 资源并初始化环境...${NC}"
    apt update && apt install -y nginx-full curl openssl socat psmisc lsof cron wget ca-certificates
    systemctl enable --now cron
    mkdir -p "$SSL_DIR" "$HTML_DIR"
    
    # 1. 拉取 emby-proxy 二进制
    echo -e "${YELLOW}正在拉取 emby-proxy...${NC}"
    curl -sLo "$PROXY_BIN" "$REPO_RAW_URL/emby-proxy" && chmod +x "$PROXY_BIN"
    
    # 2. 从 GitHub 拉取 emby-404.html (不再手动生成)
    echo -e "${YELLOW}正在从 GitHub 拉取 emby-404.html...${NC}"
    curl -sLo "$HTML_DIR/emby-404.html" "$REPO_RAW_URL/emby-404.html"

    # 3. 安装 acme.sh
    if [[ ! -f "$ACME" ]]; then
        curl https://get.acme.sh | sh -s email="admin@google.com" --force
        [ -f "$HOME/.acme.sh/acme.sh.env" ] && source "$HOME/.acme.sh/acme.sh.env" || true
    fi

    # 4. 写入 UA Map
    cat > "$MAP_CONF" << 'EOF'
map $http_upgrade $connection_upgrade { default upgrade; '' close; }
map $http_user_agent $is_emby_client {
    default 0;
    "~*(Hills|yamby|Afuse|Capy|Fileball|Infuse|SenPlayer|VLC|VidHub|Emby|Android|iOS)" 1;
}
EOF
    echo -e "${GREEN}环境同步完成！${NC}"
}

# --- [2] 证书申请 ---
apply_cert() {
    local D=$1
    echo -e "${CYAN}证书申请: 1) CF DNS  2) NAT 80端口${NC}"
    read -p "选择: " M
    if [[ "$M" == "1" ]]; then
        read -p "CF_Token: " CF_T; export CF_Token="$CF_T"
        "$ACME" --issue --dns dns_cf -d "$D" --force
    else
        read -p "NAT 80验证端口: " P; fuser -k "${P:-80}/tcp" || true
        "$ACME" --issue -d "$D" --standalone --httpport "${P:-80}" --force
    fi
    mkdir -p "$SSL_DIR/$D"
    "$ACME" --install-cert -d "$D" --key-file "$SSL_DIR/$D/privkey.pem" --fullchain-file "$SSL_DIR/$D/fullchain.pem" --reloadcmd "systemctl reload nginx"
}

# --- [3] Nginx 部署 (极致语法检查) ---
deploy_nginx() {
    local TYPE=$1; local D=$2
    local CONF="/etc/nginx/conf.d/emby_${TYPE}_${D}.conf"
    
    [[ "$TYPE" == "single" ]] && read -p "目标后端 (如 https://m.mobaiemby.site): " TARGET

    # 锁死 'EOF'，确保 ~* 正则不被反斜杠破坏
    cat > "$CONF.tmp" << 'EOF'
server {
    listen 443 ssl http2;
    server_name __DOMAIN__;
    ssl_certificate /etc/nginx/ssl/__DOMAIN__/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/__DOMAIN__/privkey.pem;

    resolver 8.8.8.8 1.1.1.1 valid=30s;
    proxy_buffering off;
    proxy_max_temp_file_size 0;

    error_page 404 /emby-404.html;
    location = /emby-404.html { root /var/www/emby; internal; }

    # 万能反代逻辑 (修复 raw_port 变量与正则语法)
    location ~* ^/(?<raw_proto>https?|wss?)://(?<raw_target>[^/:]+)(?::(?<raw_port>\d+))?(?<raw_path>/.*)?$ {
        if ($is_emby_client = 0) { return 404; }
        
        set $p_proto $raw_proto;
        set $p_target $raw_target;
        set $p_port $raw_port;
        set $p_path $raw_path;
        if ($p_port = "") { set $p_port "443"; }
        if ($p_path = "") { set $p_path "/"; }

        rewrite ^ $p_path break;
        proxy_pass $p_proto://$p_target:$p_port;

        proxy_set_header Host $p_target;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Prefix /custom;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
    }

    location / {
        if ($is_emby_client = 0) { return 404; }
        proxy_pass __TARGET__;
        proxy_set_header Host $proxy_host;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
    }
}
EOF

    sed "s|__DOMAIN__|$D|g" "$CONF.tmp" > "$CONF"
    if [[ "$TYPE" == "single" ]]; then
        sed -i "s|__TARGET__|$TARGET|g" "$CONF"
    else
        sed -i "s|__TARGET__|http://127.0.0.1:8080|g" "$CONF"
    fi
    rm -f "$CONF.tmp"

    if nginx -t; then
        systemctl restart nginx
        echo -e "${GREEN}部署完成！NAT 40889 映射已激活。${NC}"
    else
        echo -e "${RED}Nginx 配置检查失败，已清理错误文件。${NC}"
        rm -f "$CONF"
    fi
}

# --- [4] 彻底卸载 ---
uninstall_all() {
    echo -e "${RED}正在彻底卸载所有组件与配置...${NC}"
    rm -rf "$SSL_DIR" "$PROXY_BIN" "$HTML_DIR"
    rm -f /etc/nginx/conf.d/emby_*.conf
    rm -f "$MAP_CONF"
    systemctl restart nginx
    echo -e "${GREEN}清理完成。${NC}"
}

# --- 菜单控制 ---
while true; do
    clear
    echo -e "${CYAN}--- NAT Pro Manager (GitHub Sync) ---${NC}"
    echo "1) 环境初始化 (同步组件 + 404 页面)"
    echo "2) 申请/重签证书"
    echo "3) 部署 [万能反代]"
    echo "4) 部署 [单站反代]"
    echo "5) 彻底卸载清理"
    echo "q) 退出"
    read -p "指令: " OPT
    case $OPT in
        1) init_env ;;
        2) read -p "域名: " D; apply_cert "$D" ;;
        3|4) 
            read -p "部署域名: " D
            if [[ ! -f "$SSL_DIR/$D/fullchain.pem" ]]; then
                echo -e "${YELLOW}未检测到证书，请执行选项 2。${NC}"
            else
                [[ "$OPT" == "3" ]] && deploy_nginx "universal" "$D" || deploy_nginx "single" "$D"
            fi
            ;;
        5) uninstall_all ;;
        q) exit 0 ;;
    esac
    read -p "按回车继续..."
done
