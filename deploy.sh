#!/bin/bash

# ==================== Emby-Proxy 一键部署脚本 ====================
# GitHub: https://github.com/OneQ1st/emby
# 自动检测架构 + 官方 Caddy + 修复 Caddyfile 语法

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "\( {GREEN}==================================================== \){NC}"
echo -e "${GREEN}    Emby-Proxy 一键部署脚本 (最终稳定版)         ${NC}"
echo -e "\( {GREEN}==================================================== \){NC}"

# ====================== 一键卸载 ======================
if [ "$1" = "uninstall" ]; then
    echo -e "\( {RED}⚠️  警告：即将完全卸载 Emby-Proxy！ \){NC}"
    read -p "确认卸载吗？(y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "\( {GREEN}已取消。 \){NC}"
        exit 0
    fi
    systemctl stop emby-backend caddy-proxy 2>/dev/null || true
    systemctl disable emby-backend caddy-proxy 2>/dev/null || true
    rm -f /etc/systemd/system/emby-backend.service /etc/systemd/system/caddy-proxy.service
    systemctl daemon-reload
    rm -rf /opt/emby-proxy
    echo -e "\( {GREEN}✅ 卸载完成！ \){NC}"
    exit 0
fi

# ====================== 自动检测架构 ======================
echo -e "\( {YELLOW}>>> 正在检测系统架构... \){NC}"
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) CADDY_ARCH="amd64" ;;
    aarch64|arm64) CADDY_ARCH="arm64" ;;
    arm|armv7l) CADDY_ARCH="arm" ;;
    *)
        echo -e "${RED}❌ 不支持的架构: \( ARCH \){NC}"
        exit 1
        ;;
esac
echo -e "${GREEN}>>> 检测到架构: \( ARCH \){NC}"

# ====================== 安装依赖 ======================
apt update -y
apt install -y curl wget socat net-tools psmisc

# ====================== 准备目录 ======================
rm -rf /opt/emby-proxy
mkdir -p /opt/emby-proxy

# ====================== 下载文件 ======================
echo -e "\( {YELLOW}>>> 正在下载 emby-proxy... \){NC}"
wget -q https://github.com/OneQ1st/emby/raw/main/emby-proxy -O /opt/emby-proxy/emby-proxy
chmod +x /opt/emby-proxy/emby-proxy

if [ ! -x "/opt/emby-proxy/emby-proxy" ]; then
    echo -e "\( {RED}❌ emby-proxy 下载失败！请确保仓库中已上传正确的 emby-proxy \){NC}"
    exit 1
fi

echo -e "\( {YELLOW}>>> 正在下载官方 Caddy ( \){CADDY_ARCH})...${NC}"
wget -q https://github.com/caddyserver/caddy/releases/latest/download/caddy_linux_${CADDY_ARCH}.tar.gz -O /tmp/caddy.tar.gz
tar -xzf /tmp/caddy.tar.gz -C /opt/emby-proxy caddy
rm -f /tmp/caddy.tar.gz

if [ ! -x "/opt/emby-proxy/caddy" ]; then
    echo -e "\( {RED}❌ Caddy 下载失败！ \){NC}"
    exit 1
fi
echo -e "\( {GREEN}>>> Caddy 下载完成 \){NC}"

# ====================== 参数收集 ======================
read -p "请输入你的域名 (例如: emby.example.com): " DOMAIN
read -p "请输入外部端口 (默认 443): " EX_PORT
EX_PORT=${EX_PORT:-443}

echo -e "\n请选择证书申请方式:"
echo -e "1) HTTP Standalone（推荐，如果 80 端口可临时开放）"
echo -e "2) Cloudflare DNS（推荐，80 端口被封锁时使用）"
read -p "选择 [1/2]: " AUTH_MODE

# ====================== 生成正确的 Caddyfile ======================
cat > /opt/emby-proxy/Caddyfile << EOF
{
    email admin@example.com
}

\( {DOMAIN}: \){EX_PORT} {
    reverse_proxy 127.0.0.1:8080 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto {scheme}
        flush_interval -1
    }
}

http://${DOMAIN} {
    redir https://\( {DOMAIN}: \){EX_PORT}{uri} permanent
}
EOF

# Cloudflare DNS 模式处理
if [ "$AUTH_MODE" == "2" ]; then
    echo -e "\( {YELLOW}>>> Cloudflare DNS 模式 \){NC}"
    read -p "请输入 Cloudflare API Token: " CF_TOKEN
    read -p "请输入邮箱: " MY_EMAIL
    
    sed -i "s|email admin@example.com|email $MY_EMAIL|" /opt/emby-proxy/Caddyfile
    
    cat >> /opt/emby-proxy/Caddyfile << EOF

    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }
EOF
    echo "CF_API_TOKEN=$CF_TOKEN" > /opt/emby-proxy/caddy.env
else
    echo -e "\( {YELLOW}>>> HTTP Standalone 模式 \){NC}"
    read -p "请输入邮箱: " MY_EMAIL
    sed -i "s|email admin@example.com|email $MY_EMAIL|" /opt/emby-proxy/Caddyfile
fi

# ====================== 创建 systemd 服务 ======================
cat > /etc/systemd/system/emby-backend.service << EOF
[Unit]
Description=Emby Proxy Backend
After=network.target

[Service]
WorkingDirectory=/opt/emby-proxy
ExecStart=/opt/emby-proxy/emby-proxy
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/caddy-proxy.service << EOF
[Unit]
Description=Caddy SSL Frontend
After=network.target

[Service]
WorkingDirectory=/opt/emby-proxy
EnvironmentFile=-/opt/emby-proxy/caddy.env
ExecStart=/opt/emby-proxy/caddy run --config /opt/emby-proxy/Caddyfile --adapter caddyfile
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ====================== 启动服务 ======================
chmod +x /opt/emby-proxy/emby-proxy /opt/emby-proxy/caddy
systemctl daemon-reload
systemctl enable --now emby-backend caddy-proxy

echo -e "\n\( {GREEN}🎉 部署完成！ \){NC}"
echo -e "访问地址: https://$DOMAIN:$EX_PORT"
echo -e "\n\( {YELLOW}常用命令： \){NC}"
echo -e "  查看日志     : journalctl -u caddy-proxy -f"
echo -e "  重启服务     : systemctl restart emby-backend caddy-proxy"
echo -e "  一键卸载     : ./deploy.sh uninstall"

echo -e "\n\( {YELLOW}正在显示 Caddy 日志（首次申请证书可能需要 1-2 分钟）： \){NC}"
sleep 2
journalctl -u caddy-proxy -n 60 -f
