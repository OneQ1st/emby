#!/bin/bash
set -e

# --- 基础配置 ---
REPO_RAW="https://raw.githubusercontent.com/OneQ1st/emby/main"
SSL_DIR="/etc/nginx/ssl"
CONF_TARGET="/etc/nginx/conf.d/emby.conf"
HTML_DIR="/var/www/emby-404"

# --- 自动检索证书 ---
check_existing_cert() {
    local d=$1
    echo "🔍 正在检索本地是否存在有效证书..."
    local paths=("$HOME/.acme.sh/${d}_ecc/fullchain.cer" "/etc/letsencrypt/live/$d/fullchain.pem" "$SSL_DIR/$d/fullchain.pem")
    for p in "${paths[@]}"; do
        if [[ -f "$p" ]] && openssl x509 -checkend 86400 -noout -in "$p" > /dev/null 2>&1; then
            echo "✅ 找到有效证书: $p"
            SSL_FULLCHAIN="$p"
            [[ "$p" == *".cer" ]] && SSL_KEY="${p/fullchain.cer/$d.key}" || SSL_KEY="${p/fullchain.pem/privkey.pem}"
            return 0
        fi
    done
    return 1
}

# --- 申请证书 ---
apply_cert() {
    local d="$1"
    local mode="$2"
    echo "▶ 准备申请证书，域名: $d"
    [[ ! -f ~/.acme.sh/acme.sh ]] && curl https://get.acme.sh | sh -s email=admin@$d
    local ACME="$HOME/.acme.sh/acme.sh"
    if [[ "$mode" == "2" ]]; then
        read -p "请输入 CF_Token: " cf_token
        export CF_Token="$cf_token"
        "$ACME" --issue --dns dns_cf -d "$d" --force
    else
        systemctl stop nginx || true
        "$ACME" --issue --standalone -d "$d" --force
    fi
    mkdir -p "$SSL_DIR/$d"
    "$ACME" --install-cert -d "$d" --key-file "$SSL_DIR/$d/privkey.pem" --fullchain-file "$SSL_DIR/$d/fullchain.pem" --reloadcmd "systemctl restart nginx"
    SSL_FULLCHAIN="$SSL_DIR/$d/fullchain.pem"
    SSL_KEY="$SSL_DIR/$d/privkey.pem"
}

# --- 主程序 ---
install() {
    apt update && apt install -y nginx curl openssl
    read -p "请输入解析到此 VPS 的域名: " DOMAIN
    [[ -z "$DOMAIN" ]] && exit 1
    echo "选择模式: 1.常规 2.NAT(DNS验证)"
    read -p "选择 [1/2]: " NET_MODE
    NET_MODE=${NET_MODE:-1}
    
    if check_existing_cert "$DOMAIN"; then
        read -p "检测到证书，直接使用？(y/n): " use_old
        [[ "${use_old:-y}" != "y" ]] && apply_cert "$DOMAIN" "$NET_MODE"
    else
        apply_cert "$DOMAIN" "$NET_MODE"
    fi

    echo "🚀 部署 Nginx 配置..."
    curl -sSL "$REPO_RAW/emby.conf" -o "$CONF_TARGET"
    sed -i "s|{{SERVER_NAME}}|$DOMAIN|g" "$CONF_TARGET"
    sed -i "s|{{SSL_CERTIFICATE}}|$SSL_FULLCHAIN|g" "$CONF_TARGET"
    sed -i "s|{{SSL_CERTIFICATE_KEY}}|$SSL_KEY|g" "$CONF_TARGET"
    # 默认端口设置
    sed -i "s|{{HTTP_PORT}}|80|g" "$CONF_TARGET"
    sed -i "s|{{HTTPS_PORT}}|443|g" "$CONF_TARGET"
    sed -i "s|{{WHITELIST}}||g" "$CONF_TARGET"

    mkdir -p "$HTML_DIR"
    curl -sSL "$REPO_RAW/cyber-404.html" -o "$HTML_DIR/cyber-404.html" || touch "$HTML_DIR/cyber-404.html"
    
    nginx -t && systemctl restart nginx
    echo "✅ 完成！访问: https://$DOMAIN"
}

install
