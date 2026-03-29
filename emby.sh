#!/bin/bash
# ========================================
# Emby-Workers VPS 极简部署脚本 (V3.2)
# ========================================

set -e

# --- 核心配置 ---
REPO_RAW="https://raw.githubusercontent.com/OneQ1st/emby-worker/main"
CONF_TARGET="/etc/nginx/conf.d/emby.conf"
HTML_DIR="/var/www/emby-404"
WORKDIR=$(cd "$(dirname "$0")"; pwd)

show_menu() {
    clear
    echo "========================================"
    echo "    Emby-Workers 动态反代部署工具    "
    echo "========================================"
    echo "1. 一键安装 / 更新配置"
    echo "2. 彻底卸载"
    echo "3. 退出"
    echo "========================================"
    read -p "选择 [1-3]: " opt
}

install() {
    read -p "输入解析到此 VPS 的域名: " DOMAIN
    if [[ -z "$DOMAIN" ]]; then echo "域名不能为空"; exit 1; fi

    echo "1. 安装必要组件 (Nginx/Certbot)..."
    sudo apt update && sudo apt install -y nginx certbot python3-certbot-nginx

    echo "2. 申请 SSL 证书..."
    if [[ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
        sudo certbot certonly --nginx -d "$DOMAIN" --agree-tos --non-interactive --register-unsafely-without-email || true
    fi

    echo "3. 同步 404 页面资源..."
    sudo mkdir -p $HTML_DIR
    if [[ -f "$WORKDIR/emby-404.html" ]]; then
        sudo cp "$WORKDIR/emby-404.html" "$HTML_DIR/cyber-404.html"
    else
        sudo curl -s "$REPO_RAW/emby-404.html" -o "$HTML_DIR/cyber-404.html"
    fi

    echo "4. 从 GitHub 拉取并净化配置..."
    # 核心修正：下载 -> 替换域名 -> 清理 Windows 换行符 -> 清理不可见字符 -> 确保末尾有换行
    curl -s "$REPO_RAW/emby.conf" | \
    sed "s/{{DOMAIN}}/$DOMAIN/g" | \
    tr -d '\r' | \
    sed 's/[[:space:]]*$//' > /tmp/emby_clean.conf
    echo "" >> /tmp/emby_clean.conf
    
    sudo mv /tmp/emby_clean.conf $CONF_TARGET
    sudo rm -f /etc/nginx/sites-enabled/default || true

    echo "5. 验证并重启 Nginx..."
    if sudo nginx -t; then
        sudo systemctl restart nginx
        sudo ln -sf "$(readlink -f "$0")" /usr/local/bin/emby
        sudo chmod +x /usr/local/bin/emby
        echo -e "\n✅ 部署成功！域名: https://$DOMAIN"
    else
        echo -e "\n❌ 配置验证失败。内容预览如下："
        cat -A $CONF_TARGET | head -n 5
        echo "..."
        cat -A $CONF_TARGET | tail -n 5
    fi
}

uninstall() {
    read -p "确定卸载吗？(y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        sudo rm -f $CONF_TARGET
        sudo rm -rf $HTML_DIR
        sudo rm -f /usr/local/bin/emby
        sudo systemctl restart nginx
        echo "✅ 卸载完成。"
    fi
}

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
