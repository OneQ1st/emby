#!/bin/bash
set -e

# --- 基础路径 ---
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
    echo -e "${CYAN}正在配置系统环境...${NC}"
    apt update && apt install -y nginx-full curl openssl socat psmisc lsof cron
    systemctl enable --now cron
    mkdir -p "$SSL_DIR" "$HTML_DIR"
    
    # 写入 UA Map (使用单引号防止 $ 丢失)
    cat > "$MAP_CONF" << 'EOF'
map $http_upgrade $connection_upgrade { default upgrade; '' close; }
map $http_user_agent $is_emby_client {
    default 0;
    "~*(Hills|yamby|Afuse|Capy|Fileball|Infuse|SenPlayer|VLC|VidHub|Emby|Android|iOS)" 1;
}
EOF
}

# --- [2] 卸载与清理 ---
uninstall_all() {
    echo -e "${RED}正在执行卸载，清理所有反代配置与证书...${NC}"
    rm -rf "$SSL_DIR"
    rm -f /etc/nginx/conf.d/emby_*.conf
    rm -f "$MAP_CONF"
    systemctl restart nginx
    echo -e "${GREEN}卸载完成。${NC}"
}

# --- [3] Nginx 部署逻辑 (关键修复点) ---
deploy_nginx() {
    local TYPE=$1; local D=$2
    local CONF="/etc/nginx/conf.d/emby_${TYPE}_${D}.conf"
    
    # 确保目录存在
    mkdir -p "$SSL_DIR/$D"

    # 根据模式生成配置
    if [[ "$TYPE" == "single" ]]; then
        read -p "请输入后端目标 (例如 https://m.mobaiemby.site): " TARGET
        # 单站模式配置
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
        # 万能模式：使用 'EOF' 锁死，让 $raw_port 等变量原封不动写入
        cat > "$CONF" << 'EOF'
server {
    listen 443 ssl http2;
    server_name DOMAIN_HOLDER;
    ssl_certificate /etc/nginx/ssl/DOMAIN_HOLDER/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/DOMAIN_HOLDER/privkey.pem;

    proxy_buffering off;
    proxy_max_temp_file_size 0;
    client_max_body_size 0;

    # 万能反代正则提取
    location ~* "^/(?<raw_proto>https?|wss?)://(?<raw_target>[^/:]+)(?::(?<raw_port>\d+))?(?<raw_path>/.*)?$" {
        if ($is_emby_client = 0) { return 404; }
        
        # 核心转发逻辑
        proxy_pass $raw_proto://$raw_target:${raw_port:-443}$raw_path$is_args$args;
        
        proxy_set_header Host $raw_target;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $http_host;
        proxy_set_header X-Forwarded-Prefix /custom;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 600s;
    }

    location / {
        if ($is_emby_client = 0) { return 404; }
        return 403;
    }
}
EOF
        # 将占位符 DOMAIN_HOLDER 替换为实际域名
        sed -i "s|DOMAIN_HOLDER|$D|g" "$CONF"
    fi

    # 最后的安全检查
    if nginx -t; then
        systemctl restart nginx
        echo -e "${GREEN}部署成功！${NC}"
        echo -e "${YELLOW}访问地址: https://$D:40889${NC}"
    else
        echo -e "${RED}Nginx 配置存在语法错误，已尝试删除错误配置。${NC}"
        rm -f "$CONF"
        return 1
    fi
}

# --- 菜单控制 ---
while true; do
    clear
    echo -e "${CYAN}===================================${NC}"
    echo -e "${CYAN}   NAT Pro Manager (Fixed v3)      ${NC}"
    echo -e "${CYAN}===================================${NC}"
    echo "1) 初始化环境"
    echo "2) 部署 [万能反代] (解决 raw_port 报错)"
    echo "3) 部署 [单站反代]"
    echo "4) 彻底卸载清理"
    echo "q) 退出"
    read -p "指令: " OPT
    case $OPT in
        1) init_env ;;
        2|3) 
            read -p "请输入部署域名: " D
            # 简单检查证书
            if [[ ! -f "$SSL_DIR/$D/fullchain.pem" ]]; then
                echo -e "${RED}警告: 未找到证书 $SSL_DIR/$D/fullchain.pem${NC}"
                echo "请确保 acme.sh 已经把证书安装到该路径后再执行部署。"
                read -p "按回车尝试继续部署..."
            fi
            [[ "$OPT" == "2" ]] && deploy_nginx "universal" "$D" || deploy_nginx "single" "$D"
            ;;
        4) uninstall_all ;;
        q) exit 0 ;;
    esac
    read -p "按回车继续..."
done
