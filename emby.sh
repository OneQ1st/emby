#!/bin/bash
# 开启“报错即退出”模式，防止错误扩大
set -e

# --- 1. 配置路径 ---
REPO_RAW="https://raw.githubusercontent.com/OneQ1st/emby/main"
SSL_DIR="/etc/nginx/ssl"
CONF_TARGET="/etc/nginx/conf.d/emby.conf"

# --- 2. 自动检索证书 (核心新功能) ---
check_existing_cert() {
    local domain=$1
    echo "🔍 正在检索本地是否存在有效证书..."
    
    # 检索路径：acme.sh 默认路径、Certbot 路径、脚本自定义路径
    local paths=(
        "$HOME/.acme.sh/${domain}_ecc/fullchain.cer"
        "/etc/letsencrypt/live/$domain/fullchain.pem"
        "$SSL_DIR/$domain/fullchain.pem"
    )

    for p in "${paths[@]}"; do
        if [[ -f "$p" ]]; then
            # 检查证书有效期 (是否在3天内过期)
            if openssl x509 -checkend 259200 -noout -in "$p" > /dev/null 2>&1; then
                echo "✅ 找到有效证书: $p"
                SSL_FULLCHAIN="$p"
                # 智能匹配私钥路径
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

# --- 3. 最稳妥申请方式 (acme.sh DNS/Standalone) ---
apply_cert() {
    local domain=$1
    local mode=$2

    echo "▶ 准备通过 acme.sh 申请证书..."
    # 确保环境中有 acme.sh
    if [ ! -f ~/.acme.sh/acme.sh ]; then
        curl https://get.acme.sh | sh -s email=admin@$domain
    fi
    
    # 强制重新加载环境
    source ~/.bashrc || true
    local ACME="$HOME/.acme.sh/acme.sh"

    if [[ "$mode" == "2" ]]; then
        echo "🌐 NAT机环境：使用 Cloudflare DNS API 模式 (最稳)"
        read -p "请输入 CF_Token: " cf_token
        export CF_Token="$cf_token"
        $ACME --issue --dns dns_cf -d "$domain" --force
    else
        echo "🖥️ 常规VPS：使用 Standalone 模式"
        systemctl stop nginx || true
        $ACME --issue --standalone -d "$domain" --force
    fi

    # 统一安装到 Nginx 目录，解耦路径
    mkdir -p "$SSL_DIR/$domain"
    $ACME --install-cert -d "$domain" \
        --key-file "$SSL_DIR/$domain/privkey.pem" \
        --fullchain-file "$SSL_DIR/$domain/fullchain.pem" \
        --reloadcmd "systemctl restart nginx"

    SSL_FULLCHAIN="$SSL_DIR/$domain/fullchain.pem"
    SSL_KEY="$SSL_DIR/$domain/privkey.pem"
}

# --- 4. 主安装逻辑 ---
install() {
    # ... (省略域名和端口输入) ...

    # 证书处理流程
    if check_existing_cert "$DOMAIN"; then
        read -p "检测到有效证书，是否直接使用？(y/n, 默认y): " use_old
        [[ "${use_old:-y}" != "y" ]] && apply_cert "$DOMAIN" "$NET_MODE"
    else
        apply_cert "$DOMAIN" "$NET_MODE"
    fi

    # 部署 Nginx 配置文件 (注意：这里使用上面确定的 SSL_FULLCHAIN 变量进行 sed 替换)
    # ... (此处执行 curl 下载 emby.conf 并替换 {{SSL_CERTIFICATE}} 等占位符) ...
}

# --- 脚本结尾必须有触发函数 ---
install
