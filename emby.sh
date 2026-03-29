#!/bin/bash
# ========================================
# Emby-Workers VPS 极简部署脚本 (V3.0)
# 项目：https://github.com/OneQ1st/emby-worker
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

    echo "2. 申请 SSL 证书 (Let's Encrypt)..."
    if [[ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
        sudo certbot certonly --nginx -d "$DOMAIN" --agree-tos --non-interactive --register-unsafely-without-email || true
    fi

    echo "3. 同步 404 页面资源..."
    sudo mkdir -p $HTML_DIR
    # 优先使用本地文件，没有则从 GitHub 拉取
    if [[ -f "$WORKDIR/emby-404.html" ]]; then
        sudo cp "$WORKDIR/emby-404.html" "$HTML_DIR/cyber-404.html"
    else
        sudo curl -s "$REPO_RAW/emby-404.html" -o "$HTML_DIR/cyber-404.html"
    fi

    echo "4. 从 GitHub 拉取并部署 Nginx 配置模板..."
    # 动态获取 emby.conf 模板并替换域名占位符
    curl -s "$REPO_RAW/emby.conf" | sed "s/{{DOMAIN}}/$DOMAIN/g" | sudo tee $CONF_TARGET > /dev/null

    echo "5. 重启 Nginx 服务..."
    if sudo nginx -t; then
        sudo systemctl restart nginx
        # 创建全局快捷命令
        sudo ln -sf "$(readlink -f "$0")" /usr/local/bin/emby
        sudo chmod +x /usr/local/bin/emby
        echo -e "\n✅ 部署成功！"
        echo "现在你可以在 Hills 客户端使用：https://$DOMAIN/目标域名"
        echo "以后直接输入 'emby' 即可再次进入此菜单。"
    else
        echo -e "\n❌ Nginx 配置校验失败，请检查报错。"
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
