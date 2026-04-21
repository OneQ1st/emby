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
    echo -e "${CYAN}同步系统依赖...${NC}"
    apt update && apt install -y nginx-full curl openssl socat psmisc lsof cron
    systemctl enable --now cron
    mkdir -p "$SSL_DIR" "$HTML_DIR"
    
    # 写入 UA Map
    cat > "$MAP_CONF" << 'EOF'
map $http_upgrade $connection_upgrade { default upgrade; '' close; }
map $http_user_agent $is_emby_client {
    default 0;
    "~*(Hills|yamby|Afuse|Capy|Fileball|Infuse|SenPlayer|VLC|VidHub|Emby|Android|iOS)" 1;
}
EOF
}

# --- [2] 卸载逻辑 (提前定义) ---
uninstall_all() {
    echo -e "${RED}正在清理配置...${NC}"
    rm -rf "$SSL_DIR"
    rm -f /etc/nginx/conf.d/emby_*.conf
    systemctl restart nginx
    echo -e "${GREEN}清理完成。${NC}"
}

# --- [3] Nginx 部署 (核心修复) ---
deploy_nginx() {
    local TYPE=$1; local D=$2
    local CONF="/etc/nginx/conf.d/emby_${TYPE}_${D}.conf"
    
    # 资产检查逻辑
    if [[ ! -f "$SSL_DIR/$D/fullchain.pem" ]]; then
        echo -e "${RED}错误: 未发现证书，请先执行环境初始化或确保证书已申请。${NC}"
        return 1
    fi

    echo -e "${CYAN}正在部署 $TYPE 模式配置...${NC}"

    if [[ "$TYPE" == "single" ]]; then
        read -p "输入目标后端 (如 https://m.mobaiemby.site): " TARGET
        # 写入单站配置
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
        # 写入万能配置：使用单引号 'EOF' 彻底杜绝转义问题
        cat > "$CONF" << 'EOF'
server {
    listen 443 ssl http2;
EOF
        # 这里需要把 D 变量写进去，所以分段写入
        echo "    server_name $D;" >> "$CONF"
        cat >> "$CONF" << 'EOF'
    ssl_certificate /etc/nginx/ssl/VARIABLE_D/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/VARIABLE_D/privkey.pem;

    proxy_buffering off;
    proxy_max_temp_file_size 0;

    location ~* "^/(?<raw_proto>https?|wss?)://(?<raw_target>[^/:]+)(?::(?<raw_port>\d+))?(?<raw_path>/.*)?$" {
        if ($is_emby_client = 0) { return 404; }
        
        # 现在的 ${raw_port:-443} 会被原样写入文件，不再报错
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
    }

    location / {
        if ($is_emby_client = 0) { return 404; }
        return 403;
    }
}
EOF
        # 替换占位符
        sed -i "s|VARIABLE_D|$D|g" "$CONF"
    fi

    if nginx -t; then
        systemctl restart nginx
        echo -e "${GREEN}部署成功！请通过 https://$D:40889 访问。${NC}"
    else
        echo -e "${RED}配置测试失败，已为您自动回滚。${NC}"
        rm -f "$CONF"
    fi
}

# --- 菜单 (保留全部核心功能) ---
while true; do
    clear
    echo -e "${CYAN}--- NAT Pro Manager (Final Fix) ---${NC}"
    echo "1) 初始化环境 (安装依赖)"
    echo "2) 部署 [万能反代] (Universal)"
    echo "3) 部署 [单站反代] (Single)"
    echo "4) 卸载清理"
    echo "q) 退出"
    read -p "指令: " OPT
    case $OPT in
        1) init_env ;;
        2|3) 
            read -p "域名: " D
            # 自动检查证书
            if [[ ! -f "$SSL_DIR/$D/fullchain.pem" ]]; then
                echo -e "${YELLOW}未检测到证书，请确认 acme.sh 已经把证书安装到了 $SSL_DIR/$D${NC}"
                read -p "按回车尝试手动申请..."
                # 这里的申请逻辑可以调用你之前的 acme 步骤
            fi
            [[ "$OPT" == "2" ]] && deploy_nginx "universal" "$D" || deploy_nginx "single" "$D"
            ;;
        4) uninstall_all ;;
        q) exit 0 ;;
    esac
    read -p "按回车继续..."
done
