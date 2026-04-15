#!/bin/bash
set -e

# --- 配置参数 ---
REPO_RAW="https://raw.githubusercontent.com/OneQ1st/emby/main"
SSL_DIR="/etc/nginx/ssl"
CONF_TARGET="/etc/nginx/conf.d/emby.conf"
HTML_DIR="/var/www/emby-404"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 证书检查函数 ---
check_cert() {
    local d=$1
    local p1="$HOME/.acme.sh/${d}_ecc/fullchain.cer"
    local p2="/etc/letsencrypt/live/$d/fullchain.pem"
    local p3="$SSL_DIR/$d/fullchain.pem"
    
    if [[ -f "$p1" ]]; then 
        SSL_FULLCHAIN="$p1"
        SSL_KEY="${p1/fullchain.cer/$d.key}"
        return 0
    fi
    if [[ -f "$p2" ]]; then 
        SSL_FULLCHAIN="$p2"
        SSL_KEY="/etc/letsencrypt/live/$d/privkey.pem"
        return 0
    fi
    if [[ -f "$p3" ]]; then 
        SSL_FULLCHAIN="$p3"
        SSL_KEY="$SSL_DIR/$d/privkey.pem"
        return 0
    fi
    return 1
}

# --- 卸载函数 ---
uninstall_emby() {
    echo -e "${YELLOW}正在卸载 Emby 网关...${NC}"
    rm -f "$CONF_TARGET"
    rm -rf "$HTML_DIR"
    read -p "是否删除 SSL 证书目录? [y/N]: " del_ssl
    [[ "$del_ssl" == "y" ]] && rm -rf "$SSL_DIR"
    
    if nginx -t > /dev/null 2>&1; then
        systemctl restart nginx
        echo -e "${GREEN}卸载完成。${NC}"
    else
        echo -e "${RED}卸载后 Nginx 语法异常，请检查其他配置文件。${NC}"
    fi
}

# --- 安装函数 ---
install_emby() {
    echo -e "${GREEN}开始安装 Emby 核心反代网关...${NC}"
    # 增加 cron 和 socat (acme.sh 依赖)
    apt update && apt install -y nginx curl openssl perl sed socat cron

    read -p "请输入解析后的域名: " DOMAIN
    [[ -z "$DOMAIN" ]] && { echo -e "${RED}域名不能为空${NC}"; exit 1; }

    # 白名单处理
    WHITE_LIST_CONTENT=""
    while true; do
        read -p "允许访问的 IP (直接回车跳过/结束): " USER_IP
        [[ -z "$USER_IP" ]] && break
        WHITE_LIST_CONTENT="${WHITE_LIST_CONTENT}    allow $USER_IP;\n"
    done
    [[ -n "$WHITE_LIST_CONTENT" ]] && WHITE_LIST_CONTENT="${WHITE_LIST_CONTENT}    deny all;"

    # ================== 证书申请逻辑 ==================
    if ! check_cert "$DOMAIN"; then
        echo -e "${YELLOW}未检测到本地证书，尝试通过 acme.sh 申请...${NC}"
        
        # 确保 acme.sh 安装成功
        if [[ ! -f "$HOME/.acme.sh/acme.sh" ]]; then
            curl https://get.acme.sh | sh -s email=admin@$DOMAIN
            # 如果还不行，强制安装
            [[ ! -f "$HOME/.acme.sh/acme.sh" ]] && $HOME/.acme.sh/acme.sh --install --force
        fi
        
        # 别名方便调用
        ACME="$HOME/.acme.sh/acme.sh"
        
        $ACME --register-account -m "admin@${DOMAIN}"
        $ACME --set-default-ca --server letsencrypt
        
        echo -e "\n${CYAN}请选择证书验证方式:${NC}"
        echo "1. HTTP Standalone (需确保 80 端口未被占用)"
        echo "2. DNS Cloudflare (需 Token)"
        echo "3. DNS 阿里云 (需 Key/Secret)"
        echo "4. DNS 腾讯云/DNSPod (需 ID/Key)"
        read -p "请输入选项 [1-4]: " CM

        issue_func() {
            case "$CM" in
                2)
                    read -p "请输入 Cloudflare Token: " tk && export CF_Token="$tk"
                    $ACME --issue --dns dns_cf -d "$DOMAIN" --force
                    ;;
                3)
                    read -p "请输入 Aliyun AccessKey ID: " ali_key
                    read -p "请输入 Aliyun AccessKey Secret: " ali_sec
                    export Ali_Key="$ali_key" && export Ali_Secret="$ali_sec"
                    $ACME --issue --dns dns_ali -d "$DOMAIN" --force
                    ;;
                4)
                    read -p "请输入 DNSPod ID: " dp_id
                    read -p "请输入 DNSPod Token: " dp_token
                    export DP_Id="$dp_id" && export DP_Key="$dp_token"
                    $ACME --issue --dns dns_dp -d "$DOMAIN" --force
                    ;;
                *)
                    systemctl stop nginx || true
                    $ACME --issue --standalone -d "$DOMAIN" --force
                    systemctl start nginx || true
                    ;;
            esac
        }
        
        if ! issue_func; then
            echo -e "${YELLOW}主服务器申请失败，尝试备用服务器 (Buypass)...${NC}"
            $ACME --set-default-ca --server buypass
            issue_func
        fi

        mkdir -p "$SSL_DIR/$DOMAIN"
        $ACME --install-cert -d "$DOMAIN" \
            --key-file "$SSL_DIR/$DOMAIN/privkey.pem" \
            --fullchain-file "$SSL_DIR/$DOMAIN/fullchain.pem"
        SSL_FULLCHAIN="$SSL_DIR/$DOMAIN/fullchain.pem"
        SSL_KEY="$SSL_DIR/$DOMAIN/privkey.pem"
    fi
    # ==================================================

    # 获取配置模板
    echo -e "${YELLOW}正在从远程获取配置文件模板...${NC}"
    curl -sSL "$REPO_RAW/emby.conf" -o "$CONF_TARGET"
    mkdir -p "$HTML_DIR"
    curl -sSL "$REPO_RAW/emby-404.html" -o "$HTML_DIR/cyber-404.html"

    # 变量替换
    sed -i "s|{{SERVER_NAME}}|$DOMAIN|g" "$CONF_TARGET"
    sed -i "s|{{SSL_CERTIFICATE}}|$SSL_FULLCHAIN|g" "$CONF_TARGET"
    sed -i "s|{{SSL_CERTIFICATE_KEY}}|$SSL_KEY|g" "$CONF_TARGET"
    sed -i "s|{{HTTP_PORT}}|80|g" "$CONF_TARGET"
    sed -i "s|{{HTTPS_PORT}}|443|g" "$CONF_TARGET"
    
    perl -i -pe "s|\{\{WHITELIST\}\}|$WHITE_LIST_CONTENT|g" "$CONF_TARGET"

    # 语法修正
    echo -e "${YELLOW}正在进行语法修正，移除无效转义符...${NC}"
    sed -i 's/\\~\*/~\*/g' "$CONF_TARGET"

    # 测试并重启
    if nginx -t; then
        systemctl restart nginx
        echo -e "------------------------------------------------"
        echo -e "${GREEN}安装成功!${NC}"
        echo -e "域名: ${CYAN}https://$DOMAIN${NC}"
        echo -e "配置: $CONF_TARGET"
        echo -e "------------------------------------------------"
    else
        echo -e "${RED}Nginx 配置测试失败！请手动检查 $CONF_TARGET${NC}"
        exit 1
    fi
}

# --- 脚本入口 ---
clear
echo -e "${GREEN}Emby 流量包装反代网关管理脚本${NC}"
echo "1. 安装/更新配置"
echo "2. 卸载网关"
echo "3. 退出"
read -p "请选择操作 [1-3]: " opt

case $opt in
    1) install_emby ;;
    2) uninstall_emby ;;
    3) exit 0 ;;
    *) echo -e "${RED}无效选项${NC}" ;;
esac
