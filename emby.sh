#!/bin/bash
# ========================================
# Emby-Workers VPS 极简部署脚本 (V4.1)
# 增强：智能证书检索与 acme.sh 稳妥模式
# ========================================

set -e

# --- 核心路径 ---
SSL_DIR="/etc/nginx/ssl"
CONF_TARGET="/etc/nginx/conf.d/emby.conf"
REPO_RAW="https://raw.githubusercontent.com/OneQ1st/emby/main"

# ================= 智能证书检索函数 =================
check_existing_cert() {
    local domain=$1
    echo "🔍 正在检索系统内已存在的证书..."
    
    # 定义可能的检索路径
    local paths=(
        "/etc/letsencrypt/live/$domain/fullchain.pem"
        "$SSL_DIR/$domain/fullchain.pem"
        "$HOME/.acme.sh/${domain}_ecc/fullchain.cer"
    )

    for path in "${paths[@]}"; do
        if [[ -f "$path" ]]; then
            # 校验证书是否过期 (3天内过期视为无效)
            if openssl x509 -checkend 259200 -noout -in "$path" > /dev/null 2>&1; then
                echo "✅ 找到有效证书: $path"
                EXISTING_FULLCHAIN="$path"
                # 寻找配套私钥
                local key_path="${path/fullchain.pem/privkey.pem}"
                key_path="${key_path/fullchain.cer/$domain.key}"
                [[ -f "$key_path" ]] && EXISTING_KEY="$key_path"
                return 0
            else
                echo "⚠️ 找到证书但已过期或即将过期: $path"
            fi
        fi
    done
    return 1
}

# ================= 最稳妥证书申请函数 =================
handle_ssl() {
    local domain=$1
    local net_mode=$2 # 1=常规, 2=NAT

    # 1. 首先尝试自动检索
    if check_existing_cert "$domain"; then
        read -p "检测到有效证书，是否直接使用？(y/n, 默认 y): " use_old
        if [[ "${use_old:-y}" == "y" ]]; then
            SSL_FULLCHAIN="$EXISTING_FULLCHAIN"
            SSL_KEY="$EXISTING_KEY"
            return 0
        fi
    fi

    # 2. 准备 acme.sh 环境
    if [ ! -f ~/.acme.sh/acme.sh ]; then
        echo "正在安装 acme.sh..."
        apt-get update && apt-get install -y cron curl socat
        curl https://get.acme.sh | sh -s email=admin@$domain
        source ~/.bashrc || true
    fi
    local ACME="~/.acme.sh/acme.sh"

    # 3. 根据网络环境申请
    mkdir -p "$SSL_DIR/$domain"
    if [[ "$net_mode" == "2" ]]; then
        echo "▶ NAT 环境：使用 Cloudflare DNS API 模式 (最稳妥)"
        read -p "输入 CF_Token: " cf_token
        read -p "输入 CF_Account_ID (可选): " cf_aid
        export CF_Token="$cf_token"
        [[ -n "$cf_aid" ]] && export CF_Account_ID="$cf_aid"
        
        ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$domain" --force
    else
        echo "▶ 常规环境：使用 Standalone 模式 (不依赖 Nginx 运行状态)"
        systemctl stop nginx || true
        ~/.acme.sh/acme.sh --issue --standalone -d "$domain" --force
    fi

    # 4. 安装证书到统一目录 (解耦路径)
    ~/.acme.sh/acme.sh --install-cert -d "$domain" \
        --key-file "$SSL_DIR/$domain/privkey.pem" \
        --fullchain-file "$SSL_DIR/$domain/fullchain.pem" \
        --reloadcmd "systemctl restart nginx"

    SSL_FULLCHAIN="$SSL_DIR/$domain/fullchain.pem"
    SSL_KEY="$SSL_DIR/$domain/privkey.pem"
}

# ================= 主安装流程 =================
install() {
    # ... (省略域名和端口输入部分，保持与 V4.0 一致) ...

    # 调用 handle_ssl 进行智能处理
    handle_ssl "$DOMAIN" "$NET_MODE"

    # ... (后续同步 404 页面和渲染 emby.conf) ...
    # 注意：渲染时，SSL_CERTIFICATE 变量使用上面 handle_ssl 确定的路径
}
