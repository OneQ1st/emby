#!/bin/bash
set -e

# --- 基础定义 ---
SSL_DIR="/etc/nginx/ssl"
MAP_CONF="/etc/nginx/conf.d/emby_maps.conf"
HTML_DIR="/var/www/emby"

# --- 颜色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- [1] 环境初始化 ---
init_env() {
    echo -e "${CYAN}正在同步系统环境...${NC}"
    apt update && apt install -y nginx-full curl openssl socat psmisc lsof cron
    systemctl enable --now cron
    mkdir -p "$SSL_DIR" "$HTML_DIR"
    
    cat > "$MAP_CONF" << EOF
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
map \$http_user_agent \$is_emby_client {
    default 0;
    "~*(Hills|yamby|Afuse|Capy|Fileball|Infuse|SenPlayer|VLC|VidHub|Emby|Android|iOS)" 1;
}
EOF
}

# --- [2] 资产预检 ---
check_ssl_assets() {
    local D=$1
    if [[ -f "$SSL_DIR/$D/fullchain.pem" ]] && openssl x509 -checkend 604800 -noout -in "$SSL_DIR/$D/fullchain.pem"; then
        echo -e "${GREEN}检测到本地有效证书，跳过申请。${NC}"; return 0
    fi
    return 1
}

# --- [3] 申请证书 ---
request_cert() {
    local D=$1; local ACME="$HOME/.acme.sh/acme.sh"
    echo -e "${CYAN}申请模式: 1) DNS (CF Token) 2) HTTP (NAT映射)${NC}"
    read -p "选择: " M
    if [[ "$M" == "1" ]]; then
        unset CF_Key; read -p "CF Token: " T; export CF_Token="$T"
        "$ACME" --issue --dns dns_cf -d "$D" --force
    else
        read -p "内网验证端口: " P; fuser -k "${P:-80}/tcp" || true
        "$ACME" --issue -d "$D" --standalone --httpport "${P:-80}" --force
    fi
    mkdir -p "$SSL_DIR/$D"
    "$ACME" --install-cert -d "$D" --key-file "$SSL_DIR/$D/privkey.pem" --fullchain-file "$SSL_DIR/$D/fullchain.pem" --reloadcmd "systemctl reload nginx"
}

# --- [4] Nginx 核心部署 (修复转义 BUG) ---
deploy_nginx() {
    local TYPE=$1; local D=$2
    local CONF="/etc/nginx/conf.d/emby_${TYPE}_${D}.conf"
    
    if [[ "$TYPE" == "single" ]]; then
        read -p "目标后端 (如 https://m.mobaiemby.site): " TARGET
    fi

    echo -e "${CYAN}正在生成 $TYPE 模式配置...${NC}"

    # 使用 EOF 的单引号形式 'EOF' 可以防止内部所有 $ 被 Shell 解析，这是最稳妥的写入方式
    if [[ "$TYPE" == "single" ]]; then
        cat > "$CONF" << EOF
server {
    listen 443 ssl http2;
    server_name $D;
    ssl_certificate $SSL_DIR/$D/fullchain.pem;
    ssl_certificate_key $SSL_DIR/$D/privkey.pem;

    proxy_buffering off;
    proxy_max_temp_file_size 0;

    location / {
        if (\$is_emby_client = 0) { return 404; }
        proxy_pass $TARGET;
        proxy_set_header Host \$proxy_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
    else
        # 万能模式：手动处理转义，确保 ${raw_port:-443} 完整写入
        cat > "$CONF" << EOF
server {
    listen 443 ssl http2;
    server_name $D;
    ssl_certificate $SSL_DIR/$D/fullchain.pem;
    ssl_certificate_key $SSL_DIR/$D/privkey.pem;

    proxy_buffering off;
    proxy_max_temp_file_size 0;

    location ~* "^/(?<raw_proto>https?|wss?)://(?<raw_target>[^/:]+)(?::(?<raw_port>\\d+))?(?<raw_path>/.*)?$" {
        if (\$is_emby_client = 0) { return 404; }
        
        # 修正大括号转义
        proxy_pass \$raw_proto://\$raw_target:\${raw_port:-443}\$raw_path\$is_args\$args;
        
        proxy_set_header Host \$raw_target;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-Prefix /custom;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    location / {
        if (\$is_emby_client = 0) { return 404; }
        return 403;
    }
}
EOF
    fi

    if nginx -t; then
        systemctl restart nginx
        echo -e "${GREEN}部署成功！${NC}"
    else
        echo -e "${RED}Nginx 配置检查失败，请检查上面输出的错误行号。${NC}"
    fi
}

# --- [5] 卸载逻辑 ---
uninstall_all() {
    rm -rf "$SSL_DIR"
    rm -f /etc/nginx/conf.d/emby_*.conf
    systemctl restart nginx
    echo -e "${YELLOW}已清理所有反代配置。${NC}"
}

# --- 菜单 ---
while true; do
    clear
    echo -e "${CYAN}--- NAT Pro Manager (Fixed) ---${NC}"
    echo "1) 初始化环境"
    echo "2) 部署 [万能反代] (Universal)"
    echo "3) 部署 [单站反代] (Single)"
    echo "4) 卸载清理"
    echo "q) 退出"
    read -p "指令: " OPT
    case $OPT in
        1) init_env ;;
        2|3) 
            read -p "域名: " D
            check_ssl_assets "$D" || request_cert "$D"
            [[ "$OPT" == "2" ]] && deploy_nginx "universal" "$D" || deploy_nginx "single" "$D"
            ;;
        4) uninstall_all ;;
        q) exit 0 ;;
    esac
    read -p "按回车继续..."
done
