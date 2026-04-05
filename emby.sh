#!/bin/bash
set -e

# --- 核心配置 ---
REPO_RAW="https://raw.githubusercontent.com/OneQ1st/emby/main"
CONF_TARGET="/etc/nginx/conf.d/emby.conf"
SSL_DIR="/etc/nginx/ssl"
HTML_DIR="/var/www/emby-404"

# ================= 1. 自动检索证书逻辑 =================
find_existing_cert() {
    local domain=$1
    echo "🔍 正在自动检索本地证书..."
    
    # 定义可能的检索路径 (acme.sh, letsencrypt, 自定义)
    local paths=(
        "$HOME/.acme.sh/${domain}_ecc/fullchain.cer"
        "/etc/letsencrypt/live/$domain/fullchain.pem"
        "$SSL_DIR/$domain/fullchain.pem"
    )

    for p in "${paths[@]}"; do
        if [[ -f "$p" ]]; then
            # 检查证书是否在 3 天内过期
            if openssl x509 -checkend 259200 -noout -in "$p" > /dev/null 2>&1; then
                echo "✅ 发现有效证书: $p"
                SSL_FULLCHAIN="$p"
                # 尝试匹配私钥
                if [[ "$p" == *".cer" ]]; then
                    SSL_KEY="${p/fullchain.cer/$domain.key}"
                else
                    SSL_KEY="${p/fullchain.pem/privkey.pem}"
                fi
                return 0
            fi
        fi
    done
    return 1
}

# ================= 2. 申请证书逻辑 (acme.sh 方案) =================
apply_new_cert() {
    local domain=$1
    local mode=$2 # 1=普通, 2=NAT

    echo "▶ 准备通过 acme.sh 申请新证书 (最稳妥方案)..."
    [[ ! -f ~/.acme.sh/acme.sh ]] && curl https://get.acme.sh | sh -s email=admin@$domain
    
    # 强制加载环境
    source ~/.bashrc || true
    local ACME="$HOME/.acme.sh/acme.sh"

    if [[ "$mode" == "2" ]]; then
        echo "检测为 NAT 环境，需使用 Cloudflare DNS 验证:"
        read -p "请输入 Cloudflare API Token: " CF_Token
        export CF_Token="$CF_Token"
        $ACME --issue --dns dns_cf -d "$domain" --force
    else
        echo "常规环境，使用 Standalone 验证 (将临时停止 Nginx):"
        systemctl stop nginx || true
        $ACME --issue --standalone -d "$domain" --force
    fi

    # 安装证书到统一位置，方便 Nginx 引用
    mkdir -p "$SSL_DIR/$domain"
    $ACME --install-cert -d "$domain" \
        --key-file "$SSL_DIR/$domain/privkey.pem" \
        --fullchain-file "$SSL_DIR/$domain/fullchain.pem" \
        --reloadcmd "systemctl restart nginx"

    SSL_FULLCHAIN="$SSL_DIR/$domain/fullchain.pem"
    SSL_KEY="$SSL_DIR/$domain/privkey.pem"
}

# ================= 3. 安装主流程 =================
install() {
    read -p "输入解析到此 VPS 的域名: " DOMAIN
    [[ -z "$DOMAIN" ]] && exit 1

    echo "选择网络环境: 1.常规VPS  2.NAT机(80端口不通)"
    read -p "选择 [1/2]: " NET_MODE
    NET_MODE=${NET_MODE:-1}

    # 自动检索证书
    if find_existing_cert "$DOMAIN"; then
        read -p "检测到有效证书，是否直接使用？(y/n, 默认 y): " use_old
        [[ "${use_old:-y}" != "y" ]] && apply_new_cert "$DOMAIN" "$NET_MODE"
    else
        apply_new_cert "$DOMAIN" "$NET_MODE"
    fi

    # 部署 Nginx 配置 (此处会使用上面确定的 SSL_FULLCHAIN 变量)
    echo "4. 部署 Nginx 配置..."
    # ... (此处接你原有的 curl 和 sed 替换逻辑) ...
}

# ... (此处接 show_menu 和 while 循环) ...
