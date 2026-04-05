#!/bin/bash
# ==========================================
# Emby-Workers 高性能安装脚本 V5.1
# ==========================================
set -e

REPO_RAW="https://raw.githubusercontent.com/OneQ1st/emby/main"
SSL_DIR="/etc/nginx/ssl"
CONF_TARGET="/etc/nginx/conf.d/emby.conf"
HTML_DIR="/var/www/emby-404"

# 证书检索逻辑
check_cert() {
    local d=$1
    local p1="$HOME/.acme.sh/${d}_ecc/fullchain.cer"
    local p2="/etc/letsencrypt/live/$d/fullchain.pem"
    if [[ -f "$p1" ]]; then SSL_FULLCHAIN="$p1"; SSL_KEY="${p1/fullchain.cer/$d.key}"; return 0; fi
    if [[ -f "$p2" ]]; then SSL_FULLCHAIN="$p2"; SSL_KEY="${p2/fullchain.pem/privkey.pem}"; return 0; fi
    return 1
}

install() {
    apt update && apt install -y nginx curl openssl git
    read -p "请输入解析到此 VPS 的域名: " DOMAIN
    [[ -z "$DOMAIN" ]] && exit 1
    
    echo "选择模式: 1.常规 2.NAT(DNS验证)"
    read -p "选择 [1/2]: " NET_MODE
    NET_MODE=${NET_MODE:-1}

    # 处理证书
    if ! check_cert "$DOMAIN"; then
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

    # 部署并渲染配置
    echo "🚀 正在下载并渲染高性能配置..."
    curl -sSL "$REPO_RAW/emby.conf" -o "$CONF_TARGET"
    
    # 渲染所有占位符
    sed -i "s|{{SERVER_NAME}}|$DOMAIN|g" "$CONF_TARGET"
    sed -i "s|{{SSL_CERTIFICATE}}|$SSL_FULLCHAIN|g" "$CONF_TARGET"
    sed -i "s|{{SSL_CERTIFICATE_KEY}}|$SSL_KEY|g" "$CONF_TARGET"
    sed -i "s|{{HTTP_PORT}}|80|g" "$CONF_TARGET"
    sed -i "s|{{HTTPS_PORT}}|443|g" "$CONF_TARGET"
    sed -i "s|{{WHITELIST}}||g" "$CONF_TARGET"

    # 同步 404 页面 (从 GitHub 获取 emby-404.html 保存为 cyber-404.html)
    echo "📂 同步静态资源..."
    mkdir -p "$HTML_DIR"
    curl -sSL "$REPO_RAW/emby-404.html" -o "$HTML_DIR/cyber-404.html"

    nginx -t && systemctl restart nginx
    echo "✅ 部署完成！"
    echo "🌐 你的万能网关地址: https://$DOMAIN"
}

install
