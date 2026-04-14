#!/bin/bash
set -e
REPO_RAW="https://raw.githubusercontent.com/OneQ1st/emby/main"
SSL_DIR="/etc/nginx/ssl"
CONF_TARGET="/etc/nginx/conf.d/emby.conf"
HTML_DIR="/var/www/emby-404"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 核心逻辑：检查本地证书是否存在
check_cert() {
    local d=$1
    # 路径1: acme.sh 默认路径
    local p1="$HOME/.acme.sh/${d}_ecc/fullchain.cer"
    # 路径2: certbot 默认路径
    local p2="/etc/letsencrypt/live/$d/fullchain.pem"
    # 路径3: 脚本自定义安装路径
    local p3="$SSL_DIR/$d/fullchain.pem"

    if [[ -f "$p1" ]]; then 
        SSL_FULLCHAIN="$p1"
        SSL_KEY="${p1/fullchain.cer/$d.key}"
        echo -e "${GREEN}检测到 acme.sh 证书: $p1${NC}"
        return 0
    fi
    if [[ -f "$p2" ]]; then 
        SSL_FULLCHAIN="$p2"
        SSL_KEY="/etc/letsencrypt/live/$d/privkey.pem"
        echo -e "${GREEN}检测到 certbot 证书: $p2${NC}"
        return 0
    fi
    if [[ -f "$p3" ]]; then 
        SSL_FULLCHAIN="$p3"
        SSL_KEY="$SSL_DIR/$d/privkey.pem"
        echo -e "${GREEN}检测到自定义目录证书: $p3${NC}"
        return 0
    fi
    return 1
}

uninstall_emby() {
    echo -e "${RED}正在彻底卸载...${NC}"
    rm -f "$CONF_TARGET"
    rm -rf "$HTML_DIR"
    read -p "是否删除 SSL 目录? [y/N]: " del_ssl
    [[ "$del_ssl" == "y" ]] && rm -rf "$SSL_DIR"
    nginx -t && systemctl restart nginx
    echo -e "${GREEN}卸载完成！${NC}"
}

install_emby() {
    apt update && apt install -y nginx curl openssl perl
    echo -e "${GREEN}请输入您的域名:${NC}"
    read -p "> " DOMAIN
    [[ -z "$DOMAIN" ]] && exit 1

    # --- 原有逻辑：IP 白名单配置 ---
    WHITE_LIST_CONTENT=""
    echo -e "${YELLOW}🛡️ 配置 IP 白名单 (回车跳过)${NC}"
    while true; do
        read -p "允许 IP: " USER_IP
        [[ -z "$USER_IP" ]] && break
        WHITE_LIST_CONTENT="${WHITE_LIST_CONTENT}    allow $USER_IP;\n"
    done
    [[ -n "$WHITE_LIST_CONTENT" ]] && WHITE_LIST_CONTENT="${WHITE_LIST_CONTENT}    deny all;"

    # --- 原有逻辑：SNI 映射配置 ---
    DYNAMIC_MAP_CONTENT=""
    echo -e "${YELLOW}🔗 配置 SNI 映射表 (回车跳过)${NC}"
    while true; do
        read -p "后端 (如 emos.best): " T_DOM
        [[ -z "$T_DOM" ]] && break
        read -p "SNI (如 apple-cdn.net): " S_DOM
        [[ -z "$S_DOM" ]] && continue
        DYNAMIC_MAP_CONTENT="${DYNAMIC_MAP_CONTENT}    $T_DOM    \"$S_DOM\";\n"
    done

    # --- 核心修复：先检查证书，只有没有证书时才进入申请流程 ---
    if check_cert "$DOMAIN"; then
        echo -e "${GREEN}使用现有证书，跳过申请流程。${NC}"
    else
        echo -e "${YELLOW}未检测到有效证书，准备申请新证书...${NC}"
        [[ ! -f ~/.acme.sh/acme.sh ]] && curl https://get.acme.sh | sh
        
        ~/.acme.sh/acme.sh --register-account -m "emby_admin@${DOMAIN}"
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

        echo "1. HTTP (推荐) 2. DNS (Cloudflare)"
        read -p "选择验证方式: " CM
        
        issue_func() {
            if [[ "$CM" == "2" ]]; then
                read -p "CF_Token: " tk && export CF_Token="$tk"
                ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --force
            else
                systemctl stop nginx || true
                ~/.acme.sh/acme.sh --issue --standalone -d "$DOMAIN" --force
                systemctl start nginx || true
            fi
        }

        if ! issue_func; then
            echo -e "${RED}Let's Encrypt 验证失败，尝试备用 CA: Buypass...${NC}"
            ~/.acme.sh/acme.sh --set-default-ca --server buypass
            issue_func
        fi
        
        mkdir -p "$SSL_DIR/$DOMAIN"
        ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
            --key-file "$SSL_DIR/$DOMAIN/privkey.pem" \
            --fullchain-file "$SSL_DIR/$DOMAIN/fullchain.pem"
        
        SSL_FULLCHAIN="$SSL_DIR/$DOMAIN/fullchain.pem"
        SSL_KEY="$SSL_DIR/$DOMAIN/privkey.pem"
    fi

    echo -e "${YELLOW}🚀 部署 Nginx 核心配置...${NC}"
    curl -sSL "$REPO_RAW/emby.conf" -o "$CONF_TARGET"
    mkdir -p "$HTML_DIR"
    curl -sSL "$REPO_RAW/emby-404.html" -o "$HTML_DIR/cyber-404.html"

    # 替换配置文件中的占位符
    sed -i "s|{{SERVER_NAME}}|$DOMAIN|g" "$CONF_TARGET"
    sed -i "s|{{SSL_CERTIFICATE}}|$SSL_FULLCHAIN|g" "$CONF_TARGET"
    sed -i "s|{{SSL_CERTIFICATE_KEY}}|$SSL_KEY|g" "$CONF_TARGET"
    sed -i "s|{{HTTP_PORT}}|80|g" "$CONF_TARGET"
    sed -i "s|{{HTTPS_PORT}}|443|g" "$CONF_TARGET"
    
    perl -i -pe "s|\{\{WHITELIST\}\}|$WHITE_LIST_CONTENT|g" "$CONF_TARGET"
    perl -i -pe "s|\{\{DYNAMIC_MAP\}\}|$DYNAMIC_MAP_CONTENT|g" "$CONF_TARGET"

    # 检查并重启 Nginx
    if nginx -t; then
        systemctl restart nginx
        echo -e "${GREEN}✅ 安装/更新成功！${NC}"
    else
        echo -e "${RED}❌ Nginx 配置错误，请检查生成的配置文件${NC}"
        exit 1
    fi
}

clear
echo -e "${GREEN}Emby-Workers 高级工具箱 (2026版本)${NC}"
echo "1. 安装/更新"
echo "2. 彻底卸载"
echo "3. 退出"
read -p "请选择: " opt
case $opt in
    1) install_emby ;;
    2) uninstall_emby ;;
    *) exit 0 ;;
esac
