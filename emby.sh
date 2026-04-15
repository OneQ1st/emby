#!/bin/bash
set -e
REPO_RAW="https://raw.githubusercontent.com/OneQ1st/emby/main"
SSL_DIR="/etc/nginx/ssl"
CONF_TARGET="/etc/nginx/conf.d/emby.conf"
HTML_DIR="/var/www/emby-404"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

check_cert() {
    local d=$1
    local p1="$HOME/.acme.sh/${d}_ecc/fullchain.cer"
    local p2="/etc/letsencrypt/live/$d/fullchain.pem"
    local p3="$SSL_DIR/$d/fullchain.pem"
    if [[ -f "$p1" ]]; then 
        SSL_FULLCHAIN="$p1"
        SSL_KEY="${p1/fullchain.cer/$d.key}"
        return 0
    fi
    if [[ -f "$p2" ]]; then 
        SSL_FULLCHAIN="$p2"
        SSL_KEY="/etc/letsencrypt/live/$d/privkey.pem"
        return 0
    fi
    if [[ -f "$p3" ]]; then 
        SSL_FULLCHAIN="$p3"
        SSL_KEY="$SSL_DIR/$d/privkey.pem"
        return 0
    fi
    return 1
}

uninstall_emby() {
    rm -f "$CONF_TARGET"
    rm -rf "$HTML_DIR"
    read -p "Delete SSL? [y/N]: " del_ssl
    [[ "$del_ssl" == "y" ]] && rm -rf "$SSL_DIR"
    nginx -t && systemctl restart nginx
}

install_emby() {
    apt update && apt install -y nginx curl openssl perl
    read -p "Domain: " DOMAIN
    [[ -z "$DOMAIN" ]] && exit 1

    WHITE_LIST_CONTENT=""
    while true; do
        read -p "Allow IP (Enter to skip): " USER_IP
        [[ -z "$USER_IP" ]] && break
        WHITE_LIST_CONTENT="${WHITE_LIST_CONTENT}    allow $USER_IP;\n"
    done
    [[ -n "$WHITE_LIST_CONTENT" ]] && WHITE_LIST_CONTENT="${WHITE_LIST_CONTENT}    deny all;"

    if ! check_cert "$DOMAIN"; then
        [[ ! -f ~/.acme.sh/acme.sh ]] && curl https://get.acme.sh | sh
        ~/.acme.sh/acme.sh --register-account -m "admin@${DOMAIN}"
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        read -p "1.HTTP 2.DNS: " CM
        issue_func() {
            if [[ "$CM" == "2" ]]; then
                read -p "CF_Token: " tk && export CF_Token="$tk"
                ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --force
            else
                systemctl stop nginx || true
                ~/.acme.sh/acme.sh --issue --standalone -d "$DOMAIN" --force
                systemctl start nginx || true
            fi
        }
        if ! issue_func; then
            ~/.acme.sh/acme.sh --set-default-ca --server buypass
            issue_func
        fi
        mkdir -p "$SSL_DIR/$DOMAIN"
        ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$SSL_DIR/$DOMAIN/privkey.pem" --fullchain-file "$SSL_DIR/$DOMAIN/fullchain.pem"
        SSL_FULLCHAIN="$SSL_DIR/$DOMAIN/fullchain.pem"
        SSL_KEY="$SSL_DIR/$DOMAIN/privkey.pem"
    fi

    curl -sSL "$REPO_RAW/emby.conf" -o "$CONF_TARGET"
    mkdir -p "$HTML_DIR"
    curl -sSL "$REPO_RAW/emby-404.html" -o "$HTML_DIR/cyber-404.html"

    sed -i "s|{{SERVER_NAME}}|$DOMAIN|g" "$CONF_TARGET"
    sed -i "s|{{SSL_CERTIFICATE}}|$SSL_FULLCHAIN|g" "$CONF_TARGET"
    sed -i "s|{{SSL_CERTIFICATE_KEY}}|$SSL_KEY|g" "$CONF_TARGET"
    sed -i "s|{{HTTP_PORT}}|80|g" "$CONF_TARGET"
    sed -i "s|{{HTTPS_PORT}}|443|g" "$CONF_TARGET"
    perl -i -pe "s|\{\{WHITELIST\}\}|$WHITE_LIST_CONTENT|g" "$CONF_TARGET"

    nginx -t && systemctl restart nginx
}

clear
echo "1. Install"
echo "2. Uninstall"
read -p "Choice: " opt
case $opt in
    1) install_emby ;;
    2) uninstall_emby ;;
esac
