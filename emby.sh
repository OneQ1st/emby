#!/bin/bash
# ========================================
# Emby-Workers VPS 极简部署脚本 (V3.1)
# 修复：Nginx 语法截断与换行符问题
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
    # 检查证书是否存在
    if [[ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
        echo "正在申请证书，请稍候..."
        sudo certbot certonly --nginx -d "$DOMAIN" --agree-tos --non-interactive --register-unsafely-without-email || true
    fi

    echo "3. 同步 404 页面资源..."
    sudo mkdir -p $HTML_DIR
    if [[ -f "$WORKDIR/emby-404.html" ]]; then
        sudo cp "$WORKDIR/emby-404.html" "$HTML_DIR/cyber-404.html"
    else
        sudo curl -s "$REPO_RAW/emby-404.html" -o "$HTML_DIR/cyber-404.html"
    fi

    echo "4. 从 GitHub 拉取并部署 Nginx 配置模板..."
    # 关键修复：使用临时文件并强制追加换行符，防止 EOF 报错
    TMP_CONF=$(mktemp)
    curl -s "$REPO_RAW/emby.conf" | sed "s/{{DOMAIN}}/$DOMAIN/g" > "$TMP_CONF"
    # 确保文件以大括号和换行符结尾
    printf "\n" >> "$TMP_CONF"
    
    sudo mv "$TMP_CONF" "$CONF_TARGET"
    sudo chown root:root "$CONF_TARGET"
    sudo chmod 644 "$CONF_TARGET"

    echo "5. 重启 Nginx 服务..."
    # 先清理可能存在的默认配置冲突
    if [[ -f "/etc/nginx/sites-enabled/default" ]]; then
        sudo rm -f /etc/nginx/sites-enabled/default
    fi

    if sudo nginx -t; then
        sudo systemctl restart nginx
        # 创建全局快捷命令
        sudo ln -sf "$(readlink -f "$0")" /usr/local/bin/emby
        sudo chmod +x /usr/local/bin/emby
        echo -e "\n✅ 部署成功！"
        echo "使用方式：https://$DOMAIN/目标服务器地址"
        echo "例如：https://$DOMAIN/your-emby-server.com:8096"
    else
        echo -e "\n❌ Nginx 配置校验失败！"
        echo "请检查 /etc/nginx/conf.d/emby.conf 的末尾是否完整。"
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
