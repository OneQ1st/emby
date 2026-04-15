#!/bin/bash
set -e

REPO_RAW="https://raw.githubusercontent.com/OneQ1st/emby/main"
SSL_DIR="/etc/nginx/ssl"
CONF_TARGET="/etc/nginx/conf.d/emby.conf"
HTML_DIR="/var/www/emby-404"
CF_CRED_FILE="/etc/letsencrypt/cloudflare.ini"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

ensure_deps() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null
    apt-get install -y nginx curl certbot python3-certbot-nginx python3-certbot-dns-cloudflare ca-certificates rsync apache2-utils openssl >/dev/null
}

nginx_self_heal_compat() {
    local main="/etc/nginx/nginx.conf"
    [[ -f "$main" ]] || return 0
    sed -i -E 's/^\s*(quic_bpf|http3|ssl_reject_handshake)\b/# \1/' "$main"
    grep -RIl '\$http3\b' /etc/nginx 2>/dev/null | xargs -I {} sed -i '/\$http3\b/s/^/# /' {} || true
    
    if grep -qE 'listen\s+443\s+ssl\s+default_server' "$main"; then
        awk '
            BEGIN{state=0;lvl=0;match=0;}
            {
              if (state==0 && $0 ~ /server[[:space:]]*\{/){ buf[0]=$0; n=1; state=1; lvl=1; match=0; next }
              if (state==1){
                buf[n++]=$0
                if ($0 ~ /listen[[:space:]]+443[[:space:]]+ssl[[:space:]]+default_server/) match=1
                if ($0 ~ /\{/) lvl++
                if ($0 ~ /\}/){
                  lvl--;
                  if (lvl==0){
                    if (match==1){
                      has_cert=0
                      for(i=0;i<n;i++){ if (buf[i] ~ /ssl_certificate[[:space:]]+/) has_cert=1 }
                      if (has_cert==0){ state=0; next }
                    }
                    for(i=0;i<n;i++) print buf[i]
                    state=0; next
                  }
                }
                next
              }
              if (state==0) print
            }
        ' "$main" > /tmp/nginx.conf.healed && mv /tmp/nginx.conf.healed "$main"
    fi

    if ! grep -qE 'include\s+/etc/nginx/conf\.d/\*\.conf;' "$main"; then
        sed -i '/http\s*{/a\    include /etc/nginx/conf.d/*.conf;' "$main"
    fi
    systemctl restart nginx || true
}

apply_cert_http() {
    local domain=$1
    nginx_self_heal_compat
    if certbot --nginx -d "$domain" --agree-tos -m "admin@$domain" --non-interactive --redirect; then
        echo -e "${GREEN}✅ HTTP 验证成功${NC}"
    else
        echo -e "${RED}❌ HTTP 验证失败${NC}"
        exit 1
    fi
}

apply_cert_dns_cf() {
    local domain=$1
    if [[ ! -f "$CF_CRED_FILE" ]]; then
        echo -e "${YELLOW}输入 Cloudflare API Token:${NC}"
        read -r CF_TOKEN
        mkdir -p "$(dirname "$CF_CRED_FILE")"
        echo "dns_cloudflare_api_token = $CF_TOKEN" > "$CF_CRED_FILE"
        chmod 600 "$CF_CRED_FILE"
    fi
    if certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$CF_CRED_FILE" \
        -d "$domain" -d "*.$domain" --agree-tos -m "admin@$domain" --non-interactive; then
        certbot install --nginx -d "$domain" --non-interactive
        echo -e "${GREEN}✅ DNS 验证成功${NC}"
    else
        echo -e "${RED}❌ DNS 验证失败${NC}"
        exit 1
    fi
}

uninstall_all() {
    read -p "请输入要卸载的域名: " DOMAIN
    [[ -z "$DOMAIN" ]] && exit 1
    
    echo -e "${YELLOW}正在清理配置与证书...${NC}"
    rm -f "$CONF_TARGET"
    rm -rf "$SSL_DIR" "$HTML_DIR"
    
    if command -v certbot >/dev/null 2>&1; then
        certbot delete --cert-name "$DOMAIN" || true
    fi
    
    rm -f "$CF_CRED_FILE"
    
    systemctl reload nginx || true
    echo -e "${GREEN}✅ 彻底卸载完成${NC}"
}

main() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}必须 root 运行${NC}" && exit 1

    echo -e "${YELLOW}=== Emby 反代管理工具 ===${NC}"
    echo "1) 安装 - HTTP 验证 (Nginx)"
    echo "2) 安装 - DNS 验证 (Cloudflare Token)"
    echo "3) 彻底卸载 (清理配置与证书)"
    echo "0) 退出"
    read -p "请选择: " MODE

    case "$MODE" in
        1)
            read -p "输入域名: " DOMAIN
            [[ -z "$DOMAIN" ]] && exit 1
            ensure_deps
            apply_cert_http "$DOMAIN"
            mkdir -p "$SSL_DIR" "$HTML_DIR"
            systemctl reload nginx
            echo -e "${GREEN}部署完成${NC}"
            ;;
        2)
            read -p "输入域名: " DOMAIN
            [[ -z "$DOMAIN" ]] && exit 1
            ensure_deps
            apply_cert_dns_cf "$DOMAIN"
            mkdir -p "$SSL_DIR" "$HTML_DIR"
            systemctl reload nginx
            echo -e "${GREEN}部署完成${NC}"
            ;;
        3)
            uninstall_all
            ;;
        0)
            exit 0
            ;;
        *)
            echo "无效选项"
            exit 1
            ;;
    esac
}

main
