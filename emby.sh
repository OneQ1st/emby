#!/bin/bash
set -e

# --- 基础路径定义 ---
SSL_DIR="/etc/nginx/ssl"
CONF_TARGET="/etc/nginx/conf.d/emby.conf"
HTML_DIR="/var/www/emby-404"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 权限检查 ---
[[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 权限运行${NC}" && exit 1

# --- 检查证书函数 ---
check_cert() {
    local d=$1
    local p1="$HOME/.acme.sh/${d}_ecc/fullchain.cer"
    local p2="/etc/letsencrypt/live/$d/fullchain.pem"
    local p3="$SSL_DIR/$d/fullchain.pem"
    if [[ -f "$p1" ]]; then SSL_FULLCHAIN="$p1"; SSL_KEY="${p1/fullchain.cer/$d.key}"; return 0; fi
    if [[ -f "$p2" ]]; then SSL_FULLCHAIN="$p2"; SSL_KEY="/etc/letsencrypt/live/$d/privkey.pem"; return 0; fi
    if [[ -f "$p3" ]]; then SSL_FULLCHAIN="$p3"; SSL_KEY="$SSL_DIR/$d/privkey.pem"; return 0; fi
    return 1
}

# --- 安装函数 ---
install_emby() {
    echo -e "${GREEN}正在准备环境 (安装 nginx-full 以确保支持内容抓取重写)...${NC}"
    apt update && apt install -y nginx-full curl openssl perl sed socat cron

    read -p "请输入你的反代域名 (如 auto2.oneq1st.dpdns.org): " DOMAIN
    [[ -z "$DOMAIN" ]] && exit 1

    # 证书处理
    if ! check_cert "$DOMAIN"; then
        echo -e "${YELLOW}未发现证书，开始自动申请...${NC}"
        [[ ! -f "$HOME/.acme.sh/acme.sh" ]] && curl https://get.acme.sh | sh -s email=admin@$DOMAIN
        $HOME/.acme.sh/acme.sh --issue --standalone -d "$DOMAIN" --force
        mkdir -p "$SSL_DIR/$DOMAIN"
        $HOME/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$SSL_DIR/$DOMAIN/privkey.pem" --fullchain-file "$SSL_DIR/$DOMAIN/fullchain.pem"
        SSL_FULLCHAIN="$SSL_DIR/$DOMAIN/fullchain.pem"; SSL_KEY="$SSL_DIR/$DOMAIN/privkey.pem"
    fi

    # ========================================================================
    # 核心：生成 Nginx 动态反代配置
    # ========================================================================
    echo -e "${YELLOW}正在注入万能动态反代逻辑...${NC}"
    
    cat > "$CONF_TARGET" << 'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

# 自动匹配主流播放器
map $http_user_agent $is_emby_client {
    default 0;
    "~*(Hills|yamby|Afuse|Capy|Fileball|Infuse|SenPlayer|VLC|VidHub|Emby|Android|iOS)" 1;
}

server {
    # 自动监听多个常用端口，你可以根据需要增减
    listen 80;
    listen 443 ssl http2;
    listen 40889 ssl http2; 
    
    server_name {{DOMAIN}};

    ssl_certificate {{CERT}};
    ssl_certificate_key {{KEY}};

    # 允许特殊 URL 格式，不合并斜杠
    merge_slashes off;

    # 动态解析必选
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;

    # ================== 万能抓取正则 ==================
    location ~* "^/(?<raw_proto>https?|wss?)://(?<raw_target>[a-zA-Z0-9\.-]+)(?:[:/_](?<raw_port>\d+))?(?<raw_path>/.*)?$" {
        
        # 如果不通，可以暂时注释掉下面这行校验
        if ($is_emby_client = 0) { return 403 "Unauthorized Client"; }

        set $target_proto $raw_proto;
        set $target_port "";
        if ($raw_port != "") { set $target_port ":$raw_port"; }
        set $final_path $raw_path;
        if ($final_path = "") { set $final_path "/"; }

        # 反代执行
        proxy_pass $target_proto://$raw_target$target_port$final_path$is_args$args;

        # 核心：内容全量抓取与重写
        proxy_set_header Accept-Encoding ""; 
        sub_filter_types *;
        sub_filter_once off;
        
        # 动态重写流地址，自动补全当前域名和端口 ($http_host)
        sub_filter ':"http' ':"$scheme://$http_host/http';
        sub_filter '\"http' '\"$scheme://$http_host/http';
        sub_filter 'http\:\/\/' '$scheme\:\/\/$http_host\/http\:\/\/';
        sub_filter 'https\:\/\/' '$scheme\:\/\/$http_host\/https\:\/\/';

        # 劫持重定向
        proxy_redirect ~*^https?://(?<re_host>[^/]+)(?<re_path>.*)$ $scheme://$http_host/https://$re_host$re_path;

        # 基础头部
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $raw_target;
        proxy_ssl_server_name on;
        proxy_ssl_name $raw_target;
        proxy_ssl_verify off;

        # 播放器跨域修正
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' '*' always;
        add_header 'Access-Control-Allow-Headers' '*' always;
        if ($request_method = 'OPTIONS') { return 204; }

        # 传输优化
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_set_header X-Accel-Buffering no;
        proxy_force_ranges on;
    }

    location / {
        return 404 "Invalid Proxy Path";
    }
}
EOF

    # 填充变量
    sed -i "s|{{DOMAIN}}|$DOMAIN|g" "$CONF_TARGET"
    sed -i "s|{{CERT}}|$SSL_FULLCHAIN|g" "$CONF_TARGET"
    sed -i "s|{{KEY}}|$SSL_KEY|g" "$CONF_TARGET"

    # 重启服务
    if nginx -t; then
        systemctl restart nginx
        echo -e "------------------------------------------------"
        echo -e "${GREEN}安装成功!${NC}"
        echo -e "代理域名: ${CYAN}https://$DOMAIN:40889${NC}"
        echo -e "用法示例: https://$DOMAIN:40889/https://目标域名:端口"
        echo -e "------------------------------------------------"
    else
        echo -e "${RED}Nginx 配置测试失败!${NC}"
        exit 1
    fi
}

# --- 执行 ---
install_emby
