#!/bin/bash
set -e

# --- 基础定义 (严格对齐项目) ---
REPO_RAW_URL="https://raw.githubusercontent.com/OneQ1st/emby/main"
PROXY_BIN="/usr/local/bin/emby-proxy"
SSL_DIR="/etc/nginx/ssl"
MAP_CONF="/etc/nginx/conf.d/emby_maps.conf"
ACME="$HOME/.acme.sh/acme.sh"

# --- 颜色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- [1] 初始化环境 (安装 acme.sh + 拉取 emby-proxy) ---
init_env() {
    echo -e "\( {CYAN}正在初始化环境并同步 GitHub 组件... \){NC}"
    apt update && apt install -y nginx-full curl openssl socat psmisc lsof cron wget ca-certificates
    systemctl enable --now cron
    
    # 拉取 emby-proxy
    curl -sLo "$PROXY_BIN" "$REPO_RAW_URL/emby-proxy" && chmod +x "$PROXY_BIN"
    
    # 安装 acme.sh (如果不存在)
    if [[ ! -f "$ACME" ]]; then
        echo -e "\( {YELLOW}正在安装 acme.sh... \){NC}"
        curl https://get.acme.sh | sh -s email="admin@google.com" --force
        source "$HOME/.acme.sh/acme.sh.env" || true
    fi

    # 写入 UA Map
    cat > "$MAP_CONF" << 'EOF'
map $http_upgrade $connection_upgrade { default upgrade; '' close; }
map $http_user_agent $is_emby_client {
    default 0;
    "~*(Hills|yamby|Afuse|Capy|Fileball|Infuse|SenPlayer)" 1;
}
EOF
    echo -e "\( {GREEN}环境初始化完成。 \){NC}"
}

# --- [2] 证书申请逻辑 ---
apply_cert() {
    local D=$1
    echo -e "\( {CYAN}选择证书申请模式: \){NC}"
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

# --- [3] Nginx 部署 (已彻底修复 regex + proxy_pass 问题) ---
deploy_nginx() {
    local TYPE=$1; local D=$2
    local CONF="/etc/nginx/conf.d/emby_\( {TYPE}_ \){D}.conf"
    
    [[ "$TYPE" == "single" ]] && read -p "目标后端 (如 https://m.mobaiemby.site): " TARGET

    cat > "$CONF.tmp" << 'EOF'
server {
    listen 443 ssl http2;
    server_name __DOMAIN__;
    ssl_certificate /etc/nginx/ssl/__DOMAIN__/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/__DOMAIN__/privkey.pem;

    resolver 8.8.8.8 1.1.1.1 valid=30s;

    proxy_buffering off;
    proxy_max_temp_file_size 0;

    # 万能反代：支持 https?://target:port/path 格式
    location ~* ^/(?<raw_proto>https?|wss?)://(?<raw_target>[^/:]+)(?::(?<raw_port>\d+))?(?<raw_path>/.*)?$ {
        if ($is_emby_client = 0) { return 404; }

        set $p_proto $raw_proto;
        set $p_target $raw_target;
        set $p_port $raw_port;
        set $p_path $raw_path;

        if ($p_port = "") { set $p_port "443"; }
        if ($p_path = "") { set $p_path "/"; }

        # 使用 rewrite + proxy_pass 变量，避免 regex location 限制
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
        echo -e "${GREEN}部署完成！地址: https://\( D (建议通过域名 + 端口 443 访问，或根据需要添加 40889 等映射) \){NC}"
    else
        echo -e "\( {RED}Nginx 配置测试失败，请检查错误信息。配置未应用。 \){NC}"
        rm -f "$CONF"
        return 1
    fi
}

# --- 菜单 ---
while true; do
    clear
    echo -e "\( {CYAN}--- NAT Pro Manager V5 (Debian 优化版) --- \){NC}"
    echo "1) 环境初始化 (含 emby-proxy)"
    echo "2) 申请/重签证书"
    echo "3) 部署 [万能反代]"
    echo "4) 部署 [单站反代]"
    echo "5) 彻底卸载"
    read -p "指令: " OPT
    case $OPT in
        1) init_env ;;
        2) read -p "域名: " D; apply_cert "$D" ;;
        3|4) 
            read -p "域名: " D
            if [[ ! -f "$SSL_DIR/$D/fullchain.pem" ]]; then
                echo -e "\( {YELLOW}未检测到证书，请先执行选项 2 申请证书。 \){NC}"
            else
                [[ "$OPT" == "3" ]] && deploy_nginx "universal" "$D" || deploy_nginx "single" "$D"
            fi
            ;;
        5) rm -rf "$SSL_DIR" "$PROXY_BIN"; rm -f /etc/nginx/conf.d/emby_*.conf; systemctl restart nginx ;;
        *) exit 0 ;;
    esac
    read -p "回车继续..."
done
