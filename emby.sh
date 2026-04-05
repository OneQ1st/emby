#!/bin/bash
# ==========================================
# Emby-Workers 高性能安装脚本 V5.2 (带 IP 白名单)
# ==========================================
set -e

REPO_RAW="https://raw.githubusercontent.com/OneQ1st/emby/main"
SSL_DIR="/etc/nginx/ssl"
CONF_TARGET="/etc/nginx/conf.d/emby.conf"
HTML_DIR="/var/www/emby-404"

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
    
    # --- [新增] 交互式 IP 白名单逻辑 ---
    echo "------------------------------------------"
    echo "🛡️  配置 IP 白名单 (直接回车跳过, 允许所有 IP)"
    echo "提示: 输入具体的 IP (如 1.2.3.4) 或段 (如 1.2.3.0/24)"
    WHITE_LIST_CONTENT=""
    while true; do
        read -p "请输入要允许的 IP: " USER_IP
        if [[ -z "$USER_IP" ]]; then break; fi
        WHITE_LIST_CONTENT="${WHITE_LIST_CONTENT}    allow $USER_IP;\n"
    done

    if [[ -n "$WHITE_LIST_CONTENT" ]]; then
        # 如果设置了白名单，最后必须加上 deny all
        WHITE_LIST_CONTENT="${WHITE_LIST_CONTENT}    deny all;"
    fi
    # ------------------------------------------

    echo "选择模式: 1.常规 2.NAT(DNS验证)"
    read -p "选择 [1/2]: " NET_MODE
    NET_MODE=${NET_MODE:-1}

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

    echo "🚀 正在拉取并注入高性能配置..."
    curl -sSL "$REPO_RAW/emby.conf" -o "$CONF_TARGET"
    
    # 渲染变量
    sed -i "s|{{SERVER_NAME}}|$DOMAIN|g" "$CONF_TARGET"
    sed -i "s|{{SSL_CERTIFICATE}}|$SSL_FULLCHAIN|g" "$CONF_TARGET"
    sed -i "s|{{SSL_CERTIFICATE_KEY}}|$SSL_KEY|g" "$CONF_TARGET"
    sed -i "s|{{HTTP_PORT}}|80|g" "$CONF_TARGET"
    sed -i "s|{{HTTPS_PORT}}|443|g" "$CONF_TARGET"
    
    # 注入白名单内容
    # 注意: sed 使用 @ 作为分隔符防止路径中的 / 冲突，但在处理 \n 时需要特殊处理
    perl -i -pe "s|\{\{WHITELIST\}\}|$WHITE_LIST_CONTENT|g" "$CONF_TARGET"

    echo "📂 同步静态资源..."
    mkdir -p "$HTML_DIR"
    curl -sSL "$REPO_RAW/emby-404.html" -o "$HTML_DIR/cyber-404.html"

    nginx -t && systemctl restart nginx
    echo "✅ 部署完成！"
    [[ -n "$WHITE_LIST_CONTENT" ]] && echo "🔒 已启用 IP 白名单保护。"
}

install
