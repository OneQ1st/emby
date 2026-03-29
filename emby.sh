#!/bin/bash
# ========================================
# Emby-Workers VPS 极简部署脚本 (V3.4)
# 修正：适配新项目地址 https://github.com/OneQ1st/emby
# ========================================

set -e

# --- 核心配置 (已更新为新路径) ---
REPO_RAW="https://raw.githubusercontent.com/OneQ1st/emby/main"
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
    # 尝试从新仓库拉取 404 页面
    curl -s -f "$REPO_RAW/emby-404.html" -o "$HTML_DIR/cyber-404.html" || \
    echo "<html><body><h1>404 Not Found</h1></body></html>" > "$HTML_DIR/cyber-404.html"

    echo "4. 从 GitHub 拉取并部署 Nginx 配置..."
    # 使用 -f 参数，如果 GitHub 返回 404，curl 会直接报错退出，不会写入文件
    if curl -s -f "$REPO_RAW/emby.conf" -o /tmp/emby_raw.conf; then
        # 替换域名占位符并净化字符
        sed "s/{{DOMAIN}}/$DOMAIN/g" /tmp/emby_raw.conf | tr -d '\r' > /tmp/emby_final.conf
        echo "" >> /tmp/emby_final.conf # 确保结尾有换行符
        sudo mv /tmp/emby_final.conf $CONF_TARGET
    else
        echo -e "\n❌ 错误：无法从 GitHub 获取 emby.conf"
        echo "请检查链接：$REPO_RAW/emby.conf 是否可以正常访问。"
        exit 1
    fi

    echo "5. 重启 Nginx 服务..."
    sudo rm -f /etc/nginx/sites-enabled/default || true
    if sudo nginx -t; then
        sudo systemctl restart nginx
        sudo ln -sf "$(readlink -f "$0")" /usr/local/bin/emby
        sudo chmod +x /usr/local/bin/emby
        echo -e "\n✅ 部署成功！"
        echo "使用方式：https://$DOMAIN/目标域名"
    else
        echo -e "\n❌ Nginx 配置验证失败，请手动检查 $CONF_TARGET"
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
