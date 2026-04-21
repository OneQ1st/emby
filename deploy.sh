#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "\( {GREEN}==================================================== \){NC}"
echo -e "${GREEN}    Emby-Proxy 一键部署脚本 (Caddy 自动证书版)    ${NC}"
echo -e "\( {GREEN}==================================================== \){NC}"

# ====================== 一键卸载 ======================
if [ "$1" = "uninstall" ]; then
    echo -e "\( {RED}⚠️  警告：即将完全卸载 Emby-Proxy！ \){NC}"
    read -p "确认卸载吗？(y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "\( {GREEN}已取消卸载。 \){NC}"
        exit 0
    fi
    systemctl stop emby-backend caddy-proxy 2>/dev/null || true
    systemctl disable emby-backend caddy-proxy 2>/dev/null || true
    rm -f /etc/systemd/system/emby-backend.service /etc/systemd/system/caddy-proxy.service
    systemctl daemon-reload
    rm -rf /opt/emby-proxy /opt/emby-reverse-proxy-go
    echo -e "\( {GREEN}✅ 卸载完成！ \){NC}"
    exit 0
fi

# ====================== 部署流程 ======================
echo -e "\( {YELLOW}>>> 正在准备环境并安装依赖... \){NC}"

apt update -y
apt install -y git curl wget socat net-tools psmisc

# 安装官方 Go 1.24.2（解决项目 go 1.24 要求）
echo -e "\( {YELLOW}>>> 安装官方 Go 1.24.2（必须）... \){NC}"
rm -rf /usr/local/go
wget -q https://go.dev/dl/go1.24.2.linux-amd64.tar.gz -O /tmp/go.tar.gz
tar -C /usr/local -xzf /tmp/go.tar.gz
rm -f /tmp/go.tar.gz

export PATH=/usr/local/go/bin:/root/go/bin:$PATH
echo 'export PATH=/usr/local/go/bin:/root/go/bin:$PATH' >> /root/.bashrc
echo 'export PATH=/usr/local/go/bin:/root/go/bin:$PATH' >> /etc/profile

go version || { echo -e "\( {RED}Go 安装失败，请检查网络！ \){NC}"; exit 1; }
echo -e "\( {GREEN}>>> Go 安装成功： \)(go version)${NC}"

# 清理旧文件
rm -rf /opt/emby-proxy /opt/emby-reverse-proxy-go
mkdir -p /opt/emby-proxy

# 1. 编译 emby-proxy
echo -e "\( {YELLOW}>>> 正在拉取并编译 emby-proxy... \){NC}"
cd /opt
git clone https://github.com/Gsy-allen/emby-reverse-proxy-go.git
cd emby-reverse-proxy-go

go mod tidy
go build -ldflags="-s -w" -o emby-proxy main.go

if [ ! -f "emby-proxy" ]; then
    echo -e "\( {RED}❌ emby-proxy 编译失败！ \){NC}"
    echo -e "请把上面编译错误信息完整贴给我，我帮你解决。"
    exit 1
fi

cp emby-proxy /opt/emby-proxy/emby-proxy
echo -e "\( {GREEN}>>> emby-proxy 编译完成 \){NC}"

# 2. 编译 Caddy（带 Cloudflare DNS 插件）
echo -e "\( {YELLOW}>>> 正在编译 Caddy（支持两种证书方式）... \){NC}"
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest

/root/go/bin/xcaddy build --with github.com/caddy-dns/cloudflare --output /opt/emby-proxy/caddy || \
xcaddy build --with github.com/caddy-dns/cloudflare --output /opt/emby-proxy/caddy

if [ ! -f "/opt/emby-proxy/caddy" ]; then
    echo -e "\( {RED}❌ Caddy 编译失败！ \){NC}"
    exit 1
fi

echo -e "\( {GREEN}>>> Caddy 编译完成 \){NC}"

# 3. 参数收集
read -p "请输入你的域名 (例如: emby.example.com): " DOMAIN
read -p "请输入外部端口 (默认 443): " EX_PORT
EX_PORT=${EX_PORT:-443}

echo -e "\n请选择证书申请方式:"
echo -e "1) HTTP Standalone（推荐，如果 80 端口可临时开放）"
echo -e "2) Cloudflare DNS（推荐，80 端口被封锁时使用）"
read -p "选择 [1/2]: " AUTH_MODE

# 4. 生成 Caddyfile
cat <<CADDY_EOF > /opt/emby-proxy/Caddyfile
{
    email admin@example.com
}

$DOMAIN:$EX_PORT {
    reverse_proxy 127.0.0.1:8080 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto {scheme}
        flush_interval -1
    }
}

http://$DOMAIN {
    redir https://$DOMAIN:$EX_PORT{uri} permanent
}
CADDY_EOF

if [ "$AUTH_MODE" == "2" ]; then
    echo -e "\( {YELLOW}>>> 已选择 Cloudflare DNS 模式 \){NC}"
    read -p "请输入 Cloudflare API Token: " CF_TOKEN
    read -p "请输入邮箱: " MY_EMAIL
    sed -i "s|email admin@example.com|email $MY_EMAIL|" /opt/emby-proxy/Caddyfile
    cat <<EOF >> /opt/emby-proxy/Caddyfile

    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }
EOF
    echo "CF_API_TOKEN=$CF_TOKEN" > /opt/emby-proxy/caddy.env
else
    echo -e "\( {YELLOW}>>> 已选择 HTTP Standalone 模式 \){NC}"
    read -p "请输入邮箱: " MY_EMAIL
    sed -i "s|email admin@example.com|email $MY_EMAIL|" /opt/emby-proxy/Caddyfile
fi

# 5. 创建 systemd 服务
cat <<SVC_EOF > /etc/systemd/system/emby-backend.service
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
SVC_EOF

cat <<SVC_EOF > /etc/systemd/system/caddy-proxy.service
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
SVC_EOF

# 6. 赋权 + 清理
chmod +x /opt/emby-proxy/emby-proxy /opt/emby-proxy/caddy

read -p "是否清理编译时的源码目录（推荐，节省空间）？(y/n，默认 y): " clean
if [[ "$clean" != "n" && "$clean" != "N" ]]; then
    rm -rf /opt/emby-reverse-proxy-go
    echo -e "\( {GREEN}>>> 源码目录已清理 \){NC}"
fi

# 7. 启动服务
systemctl daemon-reload
systemctl enable --now emby-backend caddy-proxy

echo -e "\n\( {GREEN}🎉 部署完成！ \){NC}"
echo -e "访问地址: https://$DOMAIN:$EX_PORT"
echo -e "\n\( {YELLOW}常用命令： \){NC}"
echo -e "  查看日志     : journalctl -u caddy-proxy -f"
echo -e "  重启服务     : systemctl restart emby-backend caddy-proxy"
echo -e "  一键卸载     : ./deploy.sh uninstall"

echo -e "\n\( {YELLOW}正在显示 Caddy 日志（首次申请证书可能需要 1-2 分钟，按 Ctrl+C 退出）： \){NC}"
sleep 2
journalctl -u caddy-proxy -n 60 -f
