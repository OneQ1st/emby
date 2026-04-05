#!/bin/bash
set -e

# --- 核心路径 ---
REPO_RAW="https://raw.githubusercontent.com/OneQ1st/emby/main"
CONF_TARGET="/etc/nginx/conf.d/emby.conf"
SSL_DIR="/etc/nginx/ssl"

# ================= 自动检索证书 =================
check_certs() {
    local d=$1
    echo "🔍 检查本地是否存在有效证书..."
    # 检索路径：acme.sh默认路径、letsencrypt路径、自定义路径
    local p1="$HOME/.acme.sh/${d}_ecc/fullchain.cer"
    local p2="/etc/letsencrypt/live/$d/fullchain.pem"
    local p3="$SSL_DIR/$d/fullchain.pem"

    for p in "$p1" "$p2" "$p3"; do
        if [[ -f "$p" ]]; then
            if openssl x509 -checkend 86400 -noout -in "$p"; then
                echo "✅ 发现有效证书: $p"
                SSL_FULLCHAIN="$p"
                # 匹配私钥
                SSL_KEY="${p/fullchain.cer/$d.key}"
                [[ "$p" == *".pem" ]] && SSL_KEY="${p/fullchain.pem/privkey.pem}"
                return 0
            fi
        fi
    done
    return 1
}

# ================= 稳妥申请逻辑 =================
request_cert() {
    local d=$1
    if check_certs "$d"; then
        read -p "是否直接使用现有证书? (y/n): " use_old
        [[ "${use_old:-y}" == "y" ]] && return 0
    fi

    echo "▶ 准备通过 acme.sh 申请新证书..."
    [[ ! -f ~/.acme.sh/acme.sh ]] && curl https://get.acme.sh | sh -s email=admin@$d
    
    # 强制使用 DNS 验证（针对 NAT 最稳妥）
    echo "请输入 Cloudflare API Token:"
    read -p "Token: " CF_Token
    export CF_Token="$CF_Token"
    
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$d" --force
    mkdir -p "$SSL_DIR/$d"
    ~/.acme.sh/acme.sh --install-cert -d "$d" \
        --key-file "$SSL_DIR/$d/privkey.pem" \
        --fullchain-file "$SSL_DIR/$d/fullchain.pem"
    
    SSL_FULLCHAIN="$SSL_DIR/$d/fullchain.pem"
    SSL_KEY="$SSL_DIR/$d/privkey.pem"
}

# ... (这里接你的 show_menu 和 install 函数) ...
# 注意：install 函数里记得调用 request_cert $DOMAIN
