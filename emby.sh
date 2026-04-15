#!/bin/bash
set -e

# --- 路径与变量定义 ---
SSL_DIR="/etc/nginx/ssl"
CONF_TARGET="/etc/nginx/conf.d/emby.conf"
HTML_DIR="/var/www/emby"
HTML_FILE="$HTML_DIR/emby-404.html"
GITHUB_HTML_URL="https://raw.githubusercontent.com/OneQ1st/emby/main/emby-404.html"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 权限检查 ---
[[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 权限运行${NC}" && exit 1

# --- 检查证书函数 (保持原样) ---
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

# --- 彻底删除/卸载函数 (新增) ---
uninstall_emby() {
    echo -e "${YELLOW}正在彻底清理 Emby 代理相关配置...${NC}"
    
    # 1. 删除 Nginx 配置
    if [[ -f "$CONF_TARGET" ]]; then
        rm -f "$CONF_TARGET"
        echo -e "${CYAN}已删除 Nginx 配置文件: $CONF_TARGET${NC}"
    fi

    # 2. 删除 404 HTML 目录
    if [[ -d "$HTML_DIR" ]]; then
        rm -rf "$HTML_DIR"
        echo -e "${CYAN}已删除 HTML 目录: $HTML_DIR${NC}"
    fi

    # 3. 询问是否删除证书 (可选，默认不删以防其他业务使用)
    read -p "是否同时删除该域名相关的 SSL 证书目录? [y/N]: " DEL_CERT
    if [[ "$DEL_CERT" =~ ^[Yy]$ ]]; then
        read -p "输入要清理证书的域名: " DEL_DOMAIN
        rm -rf "$SSL_DIR/$DEL_DOMAIN"
        echo -e "${CYAN}已清理证书目录: $SSL_DIR/$DEL_DOMAIN${NC}"
    fi

    # 4. 重启 Nginx
    if nginx -t > /dev/null 2>&1; then
        systemctl restart nginx
        echo -e "${GREEN}卸载完成，Nginx 已重载。${NC}"
    else
        echo -e "${RED}Nginx 配置存在其他错误，请手动检查。${NC}"
    fi
    exit 0
}

# --- 核心安装逻辑 (保持原样) ---
install_emby_pro() {
    echo -e "${GREEN}正在同步基础环境...${NC}"
    apt update && apt install -y nginx-full curl openssl sed socat cron

    read -p "请输入反代域名: " DOMAIN
    [[ -z "$DOMAIN" ]] && exit 1

    if ! check_cert "$DOMAIN"; then
        echo -e "${YELLOW}证书未发现，请选择申请方式:${NC}"
        echo "1) 独立服务器模式 (Standalone - 需占用 80 端口)"
        echo "2) Cloudflare DNS 模式 (使用 API Token - 推荐)"
        read -p "选择 [1-2]: " CERT_MODE

        [[ ! -f "$HOME/.acme.sh/acme.sh" ]] && curl https://get.acme.sh | sh -s email=admin@$DOMAIN

        if [[ "$CERT_MODE" == "2" ]]; then
            read -p "请输入 Cloudflare API Token: " CF_TOKEN
            export CF_Token="$CF_TOKEN"
            "$HOME/.acme.sh/acme.sh" --issue --dns dns_cf -d "$DOMAIN" --force
        else
            "$HOME/.acme.sh/acme.sh" --issue --standalone -d "$DOMAIN" --force
        fi

        mkdir -p "$SSL_DIR/$DOMAIN"
        "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" \
            --key-file "$SSL_DIR/$DOMAIN/privkey.pem" \
            --fullchain-file "$SSL_DIR/$DOMAIN/fullchain.pem"
        SSL_FULLCHAIN="$SSL_DIR/$DOMAIN/fullchain.pem"
        SSL_KEY="$SSL_DIR/$DOMAIN/privkey.pem"
    fi

    echo -e "${YELLOW}同步 404 自定义页面...${NC}"
    mkdir -p "$HTML_DIR"
    curl -sLo "$HTML_FILE" "$GITHUB_HTML_URL"
    chown -R www-data:www-data "$HTML_DIR"

    echo -e "${YELLOW}生成增强版 Nginx 动态反代配置...${NC}"
    cat > "$CONF_TARGET" << 'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

map $http_user_agent $is_emby_client {
    default 0;
    "~*(Hills|yamby|Afuse|Capy|Fileball|Infuse|SenPlayer|VLC|VidHub|Emby|Android|iOS)" 1;
}

server {
    listen 80;
    listen 443 ssl http2;
    listen 40889 ssl http2;
    
    server_name {{DOMAIN}};

    ssl_certificate {{CERT}};
    ssl_certificate_key {{KEY}};

    merge_slashes off;
    resolver 1.1.1.1 8.8.8.8 ipv6=off valid=300s;
    resolver_timeout 5s;

    error_page 404 /emby-404.html;

    location = /emby-404.html {
        root {{HTML_ROOT}};
        internal;
    }

    location ~* "^/(?<raw_proto>https?|wss?)://(?<raw_target>[a-zA-Z0-9\.-]+)(?:[:/_](?<raw_port>\d+))?(?<raw_path>/.*)?$" {
        
        if ($is_emby_client = 0) { return 403 "Unauthorized Client"; }

        set $target_proto $raw_proto;
        set $target_port "";
        if ($raw_port != "") { set $target_port ":$raw_port"; }
        set $final_path $raw_path;
        if ($final_path = "") { set $final_path "/"; }

        proxy_pass $target_proto://$raw_target$target_port$final_path$is_args$args;

        proxy_set_header Accept-Encoding ""; 
        sub_filter_types *;
        sub_filter_once off;
        
        sub_filter ':"http' ':"$scheme://$http_host/http';
        sub_filter '\"http' '\"$scheme://$http_host/http';
        sub_filter 'http\:\/\/' '$scheme\:\/\/$http_host\/http\:\/\/';
        sub_filter 'https\:\/\/' '$scheme\:\/\/$http_host\/https\:\/\/';

        proxy_redirect ~*^https?://(?<re_host>[^/]+)(?<re_path>.*)$ $scheme://$http_host/https://$re_host$re_path;

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $raw_target;
        proxy_ssl_server_name on;
        proxy_ssl_name $raw_target;
        proxy_ssl_verify off;

        proxy_hide_header 'Access-Control-Allow-Origin';
        proxy_hide_header 'Access-Control-Allow-Methods';
        proxy_hide_header 'Access-Control-Allow-Headers';
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, RANGE' always;
        add_header 'Access-Control-Allow-Headers' '*' always;
        add_header 'Access-Control-Expose-Headers' 'Content-Length, Content-Range' always;

        if ($request_method = 'OPTIONS') { 
            add_header 'Access-Control-Max-Age' 1728000;
            add_header 'Content-Type' 'text/plain; charset=utf-8';
            add_header 'Content-Length' 0;
            return 204; 
        }

        proxy_buffering off;
        proxy_request_buffering off;
        proxy_set_header X-Accel-Buffering no;
        proxy_force_ranges on;
    }

    location / {
        return 404;
    }
}
EOF

    sed -i "s|{{DOMAIN}}|$DOMAIN|g" "$CONF_TARGET"
    sed -i "s|{{CERT}}|$SSL_FULLCHAIN|g" "$CONF_TARGET"
    sed -i "s|{{KEY}}|$SSL_KEY|g" "$CONF_TARGET"
    sed -i "s|{{HTML_ROOT}}|$HTML_DIR|g" "$CONF_TARGET"

    if nginx -t; then
        systemctl restart nginx
        echo -e "------------------------------------------------"
        echo -e "${GREEN}部署成功!${NC}"
        echo -e "代理域名: ${CYAN}https://$DOMAIN:port${NC}"
        echo -e "------------------------------------------------"
    else
        echo -e "${RED}配置有误，请检查日志${NC}"
        exit 1
    fi
}

# --- 主入口 ---
clear
echo -e "${CYAN}====================================${NC}"
echo -e "${CYAN}   Emby 万能动态反代自动化脚本      ${NC}"
echo -e "${CYAN}====================================${NC}"
echo -e "1) 安装/更新 反代配置"
echo -e "2) 彻底卸载 反代配置与目录"
echo -e "q) 退出"
read -p "请选择操作 [1-2/q]: " MAIN_CHOICE

case $MAIN_CHOICE in
    1) install_emby_pro ;;
    2) uninstall_emby ;;
    q) exit 0 ;;
    *) echo -e "${RED}输入错误${NC}" ; exit 1 ;;
esac
