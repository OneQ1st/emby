#!/bin/bash
set -e

# --- 基础配置 (对齐你的 GitHub 路径) ---
REPO_RAW="https://raw.githubusercontent.com/OneQ1st/emby/main"
SSL_DIR="/etc/nginx/ssl"
CONF_TARGET="/etc/nginx/conf.d/emby.conf"
HTML_DIR="/var/www/emby-404"

# --- 证书检索函数 ---
check_cert() {
    local d=$1
    local p1="$HOME/.acme.sh/${d}_ecc/fullchain.cer"
    local p2="/etc/letsencrypt/live/$d/fullchain.pem"
    if [[ -f "$p1" ]]; then SSL_FULLCHAIN="$p1"; SSL_KEY="${p1/fullchain.cer/$d.key}"; return 0; fi
    if [[ -f "$p2" ]]; then SSL_FULLCHAIN="$p2"; SSL_KEY="${p2/fullchain.pem/privkey.pem}"; return 0; fi
    return 1
}

install() {
    apt update && apt install -y nginx curl openssl
    read -p "请输入解析到此 VPS 的域名: " DOMAIN
    [[ -z "$DOMAIN" ]] && exit 1
    
    echo "选择模式: 1.常规 2.NAT(DNS验证)"
    read -p "选择 [1/2]: " NET_MODE
    NET_MODE=${NET_MODE:-1}

    # 证书处理
    if ! check_cert "$DOMAIN"; then
        echo "▶ 正在申请新证书..."
        [[ ! -f ~/.acme.sh/acme.sh ]] && curl https://get.acme.sh | sh
        if [[ "$NET_MODE" == "2" ]]; then
            read -p "请输入 CF_Token: " cf_token
            export CF_Token="$cf_token"
            ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --force
        else
            systemctl stop nginx || true
            ~/.acme.sh/acme.sh --issue --standalone -d "$DOMAIN" --force
        fi
        mkdir -p "$SSL_DIR/$DOMAIN"
        ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$SSL_DIR/$DOMAIN/privkey.pem" --fullchain-file "$SSL_DIR/$DOMAIN/fullchain.pem"
        SSL_FULLCHAIN="$SSL_DIR/$DOMAIN/fullchain.pem"
        SSL_KEY="$SSL_DIR/$DOMAIN/privkey.pem"
    fi

    # --- 部署 Nginx 配置 ---
    echo "🚀 正在从 GitHub 拉取最新配置..."
    curl -sSL "$REPO_RAW/emby.conf" -o "$CONF_TARGET"
    sed -i "s|{{SERVER_NAME}}|$DOMAIN|g" "$CONF_TARGET"
    sed -i "s|{{SSL_CERTIFICATE}}|$SSL_FULLCHAIN|g" "$CONF_TARGET"
    sed -i "s|{{SSL_CERTIFICATE_KEY}}|$SSL_KEY|g" "$CONF_TARGET"
    # 默认端口 443
    sed -i "s|{{HTTPS_PORT}}|443|g" "$CONF_TARGET"

    # --- 关键：下载你的 emby-404.html ---
    echo "📂 正在下载自定义 404 页面..."
    mkdir -p "$HTML_DIR"
    # 这里对齐你的文件名 emby-404.html
    curl -sSL "$REPO_RAW/emby-404.html" -o "$HTML_DIR/emby-404.html"

    nginx -t && systemctl restart nginx
    echo "✅ 部署完成！"
    echo "🌐 网关地址: https://$DOMAIN"
}

install
