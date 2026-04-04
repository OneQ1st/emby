#!/bin/bash
# ========================================
# Emby-Workers VPS 极简部署脚本 (V4.0)
# 新增功能：
#   • 自定义证书路径（LetsEncrypt / 自签名 / 手动指定）
#   • 自定义 Nginx 监听端口（HTTP/HTTPS）
#   • 支持无域名纯IP反代
#   • 白名单 IP 可自定义
#   • emby.conf 使用占位符模板（不影响原有逻辑）
# ========================================

set -e

# --- 核心配置 ---
REPO_RAW="https://raw.githubusercontent.com/OneQ1st/emby/main"
CONF_TARGET="/etc/nginx/conf.d/emby.conf"
HTML_DIR="/var/www/emby-404"
SSL_DIR="/etc/nginx/ssl"
WORKDIR=\( (cd " \)(dirname "$0")"; pwd)

show_menu() {
    clear
    echo "========================================"
    echo "    Emby-Workers 动态反代部署工具    "
    echo "               V4.0                  "
    echo "========================================"
    echo "1. 一键安装 / 更新配置"
    echo "2. 彻底卸载"
    echo "3. 退出"
    echo "========================================"
    read -p "选择 [1-3]: " opt
}

install() {
    # === 模式选择 ===
    read -p "请选择模式 (domain/ip，默认 domain): " MODE
    MODE=${MODE:-domain}

    if [[ "$MODE" == "domain" ]]; then
        read -p "输入解析到此 VPS 的域名: " DOMAIN
        [[ -z "$DOMAIN" ]] && { echo "域名不能为空"; exit 1; }
        SERVER_NAME="$DOMAIN"
        CERT_AUTO="letsencrypt"
    else
        read -p "输入服务器公网IP: " IP
        [[ -z "$IP" ]] && { echo "IP不能为空"; exit 1; }
        SERVER_NAME="$IP"
        CERT_AUTO="selfsigned"
    fi

    # === 端口自定义 ===
    read -p "HTTP 监听端口 (默认 80): " HTTP_PORT
    HTTP_PORT=${HTTP_PORT:-80}
    read -p "HTTPS 监听端口 (默认 443): " HTTPS_PORT
    HTTPS_PORT=${HTTPS_PORT:-443}

    # === 证书自定义 ===
    read -p "证书模式 (auto=自动/custom=手动指定，默认 auto): " CERT_MODE
    CERT_MODE=${CERT_MODE:-auto}

    if [[ "$CERT_MODE" == "custom" ]]; then
        read -p "请输入 fullchain.pem 完整路径: " SSL_FULLCHAIN
        read -p "请输入 privkey.pem 完整路径: " SSL_KEY
    else
        if [[ "$CERT_AUTO" == "letsencrypt" ]]; then
            SSL_FULLCHAIN="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
            SSL_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
        else
            SSL_FULLCHAIN="$SSL_DIR/emby-ip-fullchain.pem"
            SSL_KEY="$SSL_DIR/emby-ip-privkey.pem"
        fi
    fi

    # === 白名单 ===
    read -p "白名单 IP（多个用空格分隔，留空则不限制）: " WHITELIST_INPUT
    if [[ -n "$WHITELIST_INPUT" ]]; then
        WHITELIST="    allow $WHITELIST_INPUT;\n    deny all;"
    else
        WHITELIST=""
    fi

    # === 安装依赖 ===
    echo "1. 安装必要组件 (Nginx/Certbot)..."
    sudo apt update && sudo apt install -y nginx certbot python3-certbot-nginx openssl

    # === 申请/生成证书 ===
    echo "2. 处理 SSL 证书..."
    if [[ "$CERT_MODE" == "custom" ]]; then
        echo "使用自定义证书路径：$SSL_FULLCHAIN"
    elif [[ "$CERT_AUTO" == "letsencrypt" ]]; then
        if [[ ! -f "$SSL_FULLCHAIN" ]]; then
            sudo certbot certonly --nginx -d "$DOMAIN" --agree-tos --non-interactive --register-unsafely-without-email || true
        fi
    else
        # 自签名证书（纯IP模式）
        sudo mkdir -p "$SSL_DIR"
        if [[ ! -f "$SSL_FULLCHAIN" ]]; then
            sudo openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
                -keyout "$SSL_KEY" \
                -out "$SSL_FULLCHAIN" \
                -subj "/CN=$SERVER_NAME" \
                -addext "subjectAltName=IP:$SERVER_NAME" 2>/dev/null
            echo "自签名证书已生成（有效期 10 年）"
        fi
    fi

    # === 同步 404 页面 ===
    echo "3. 同步 404 页面资源..."
    sudo mkdir -p $HTML_DIR
    curl -s -f "$REPO_RAW/emby-404.html" -o "$HTML_DIR/cyber-404.html" || \
    echo "<h1>404 Not Found</h1>" > "$HTML_DIR/cyber-404.html"

    # === 拉取并渲染配置模板 ===
    echo "4. 部署 Nginx 配置..."
    curl -s -f "$REPO_RAW/emby.conf" -o /tmp/emby_raw.conf || {
        echo "错误：无法从 GitHub 获取 emby.conf"
        exit 1
    }

    # 多占位符替换
    sed -e "s|{{SERVER_NAME}}|$SERVER_NAME|g" \
        -e "s|{{HTTP_PORT}}|$HTTP_PORT|g" \
        -e "s|{{HTTPS_PORT}}|$HTTPS_PORT|g" \
        -e "s|{{SSL_CERTIFICATE}}|$SSL_FULLCHAIN|g" \
        -e "s|{{SSL_CERTIFICATE_KEY}}|$SSL_KEY|g" \
        -e "s|{{WHITELIST}}|$WHITELIST|g" \
        /tmp/emby_raw.conf | tr -d '\r' > /tmp/emby_final.conf

    sudo mv /tmp/emby_final.conf $CONF_TARGET

    # === 重启服务 ===
    echo "5. 重启 Nginx 服务..."
    sudo rm -f /etc/nginx/sites-enabled/default || true
    if sudo nginx -t; then
        sudo systemctl restart nginx
        sudo ln -sf "$(readlink -f "$0")" /usr/local/bin/emby
        sudo chmod +x /usr/local/bin/emby

        # 成功提示
        if [[ $HTTPS_PORT -eq 443 ]]; then
            ACCESS_URL="https://$SERVER_NAME"
        else
            ACCESS_URL="https://$SERVER_NAME:$HTTPS_PORT"
        fi
        echo -e "\n✅ 部署成功！"
        echo "访问地址：$ACCESS_URL/目标域名"
        echo "使用方式：https://$SERVER_NAME[:$HTTPS_PORT]/目标IP或域名"
    else
        echo -e "\n❌ Nginx 配置验证失败，请检查 $CONF_TARGET"
    fi
}

uninstall() {
    read -p "确定彻底卸载吗？(y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        sudo rm -f $CONF_TARGET
        sudo rm -rf $HTML_DIR
        sudo rm -f /usr/local/bin/emby
        sudo rm -rf $SSL_DIR/emby-ip-* 2>/dev/null || true
        sudo systemctl restart nginx
        echo "卸载完成。"
    fi
}

# --- 主程序 ---
while true; do
    show_menu
    case $opt in
        1) install ;;
        2) uninstall ;;
        3) exit 0 ;;
        *) echo "无效选项" ;;
    esac
    read -p "按回车继续..."
done
