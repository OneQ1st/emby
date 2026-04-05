#!/bin/bash
# ========================================
# Emby-Workers 自动化部署脚本 V4.2
# 修复：变量传递、证书检索、acme.sh 逻辑
# ========================================
set -e

# --- 基础配置 ---
REPO_RAW="https://raw.githubusercontent.com/OneQ1st/emby/main"
SSL_DIR="/etc/nginx/ssl"
CONF_TARGET="/etc/nginx/conf.d/emby.conf"
HTML_DIR="/var/www/emby-404"

# --- 自动检索证书函数 ---
check_existing_cert() {
    local d=$1
    echo "🔍 正在检索本地是否存在有效证书..."
    local paths=(
        "$HOME/.acme.sh/${d}_ecc/fullchain.cer"
        "/etc/letsencrypt/live/$d/fullchain.pem"
        "$SSL_DIR/$d/fullchain.pem"
    )
    for p in "${paths[@]}"; do
        if [[ -f "$p" ]]; then
            if openssl x509 -checkend 86400 -noout -in "$p" > /dev/null 2>&1; then
                echo "✅ 找到有效证书: $p"
                SSL_FULLCHAIN="$p"
                [[ "$p" == *".cer" ]] && SSL_KEY="${p/fullchain.cer/$d.key}" || SSL_KEY="${p/fullchain.pem/privkey.pem}"
                return 0
            fi
        fi
    done
    return 1
}

# --- 最稳妥申请函数 ---
apply_cert() {
    local d="$1"
    local mode="$2"
    
    if [ -z "$d" ]; then echo "❌ 错误: 域名变量为空！"; exit 1; fi

    echo "▶ 准备通过 acme.sh 申请证书，域名: $d"
    [[ ! -f ~/.acme.sh/acme.sh ]] && curl https://get.acme.sh | sh -s email=admin@$d
    
    # 显式指定 acme.sh 路径
    local ACME="$HOME/.acme.sh/acme.sh"

    if [[ "$mode" == "2" ]]; then
        echo "🌐 NAT 环境：使用 Cloudflare DNS API"
        read -p "请输入 CF_Token: " cf_token
        export CF_Token="$cf_token"
        "$ACME" --issue --dns dns_cf -d "$d" --force
    else
        echo "🖥️ 常规 VPS：使用 Standalone 模式"
        systemctl stop nginx || true
        "$ACME" --issue --standalone -d "$d" --force
    fi

    mkdir -p "$SSL_DIR/$d"
    "$ACME" --install-cert -d "$d" \
        --key-file "$SSL_DIR/$d/privkey.pem" \
        --fullchain-file "$SSL_DIR/$d/fullchain.pem" \
        --reloadcmd "systemctl restart nginx"

    SSL_FULLCHAIN="$SSL_DIR/$d/fullchain.pem"
    SSL_KEY="$SSL_DIR/$d/privkey.pem"
}

# --- 主安装函数 ---
install() {
    # 1. 交互输入 (确保变量在此阶段获取)
    read -p "请输入解析到此 VPS 的域名: " DOMAIN
    [[ -z "$DOMAIN" ]] && { echo "❌ 域名不能为空"; exit 1; }

    echo "选择网络模式: 1.常规VPS(80端口通) 2.NAT机(使用DNS验证)"
    read -p "选择 [1/2]: " NET_MODE
    NET_MODE=${NET_MODE:-1}

    read -p "请输入 HTTPS 监听端口 (默认 443): " HTTPS_PORT
    HTTPS_PORT=${HTTPS_PORT:-443}

    # 2. 证书逻辑
    if check_existing_cert "$DOMAIN"; then
        read -p "检测到有效证书，直接使用？(y/n): " use_old
        [[ "${use_old:-y}" != "y" ]] && apply_cert "$DOMAIN" "$NET_MODE"
    else
        apply_cert "$DOMAIN" "$NET_MODE"
    fi

    # 3. 部署 Nginx 配置文件
    echo "🚀 正在部署 Nginx 配置..."
    apt install -y nginx
    curl -sSL "$REPO_RAW/emby.conf" -o "$CONF_TARGET"
    
    # 使用 sed 替换占位符
    sed -i "s|{{SERVER_NAME}}|$DOMAIN|g" "$CONF_TARGET"
    sed -i "s|{{HTTPS_PORT}}|$HTTPS_PORT|g" "$CONF_TARGET"
    sed -i "s|{{SSL_CERTIFICATE}}|$SSL_FULLCHAIN|g" "$CONF_TARGET"
    sed -i "s|{{SSL_CERTIFICATE_KEY}}|$SSL_KEY|g" "$CONF_TARGET"

    # 4. 404 页面处理
    mkdir -p "$HTML_DIR"
    curl -sSL "$REPO_RAW/cyber-404.html" -o "$HTML_DIR/cyber-404.html" || echo "跳过404下载"

    nginx -t && systemctl restart nginx
    echo "✅ 部署完成！访问: https://$DOMAIN:$HTTPS_PORT"
}

# 运行主程序
install
