#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "\( {GREEN}==================================================== \){NC}"
echo -e "${GREEN}    Emby-Proxy 部署脚本 (Caddy 自动证书版)    ${NC}"
echo -e "\( {GREEN}==================================================== \){NC}"

# 1. 基础依赖与环境
apt update -y
apt install -y curl socat fuser net-tools tar wget git golang-go 2>/dev/null
mkdir -p /opt/emby-proxy

# 2. 编译 Caddy（带 Cloudflare DNS 插件，支持两种申请方式）
echo -e "\( {YELLOW}>>> 正在编译 Caddy（包含 Cloudflare DNS 插件）... \){NC}"
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest

# 编译带 Cloudflare 插件的 Caddy
xcaddy build --with github.com/caddy-dns/cloudflare --output /opt/emby-proxy/caddy

chmod +x /opt/emby-proxy/caddy

echo -e "\( {GREEN}>>> Caddy 编译完成 \){NC}"

# 3. 收集参数
read -p "请输入域名 (例如: emby.example.com): " DOMAIN
read -p "请输入外部端口 (默认 443): " EX_PORT
EX_PORT=${EX_PORT:-443}

echo -e "\n请选择证书申请方式:"
echo -e "1) HTTP Standalone（推荐，如果 80 端口可临时开放）"
echo -e "2) Cloudflare DNS（推荐，如果 80 端口被封锁）"
read -p "选择 [1/2]: " AUTH_MODE

# 4. 生成 Caddyfile（根据选择生成对应配置）
cat <<CADDY_EOF > /opt/emby-proxy/Caddyfile
{
    email your-email@example.com   # ← 后面会替换成你输入的邮箱
}

$DOMAIN:$EX_PORT {
    reverse_proxy 127.0.0.1:8080 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-Proto {scheme}
        flush_interval -1
    }
}

# HTTP 跳转到 HTTPS（可选）
http://$DOMAIN {
    redir https://$DOMAIN:$EX_PORT{uri} permanent
}
CADDY_EOF

# 根据模式修改 Caddyfile
if [ "$AUTH_MODE" == "2" ]; then
    echo -e "\( {YELLOW}>>> 模式: Cloudflare DNS 挑战 \){NC}"
    read -p "请输入 Cloudflare API Token (需要 Zone.DNS:Edit 权限): " CF_TOKEN
    
    # 在全局块中添加 DNS 配置
    sed -i "s|email your-email@example.com|email $MY_EMAIL|" /opt/emby-proxy/Caddyfile 2>/dev/null || true
    cat <<EOF >> /opt/emby-proxy/Caddyfile

    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }
EOF
    echo "export CF_API_TOKEN=$CF_TOKEN" > /opt/emby-proxy/caddy.env
else
    echo -e "\( {YELLOW}>>> 模式: HTTP Standalone \){NC}"
    read -p "请输入邮箱 (用于 Let's Encrypt 通知): " MY_EMAIL
    sed -i "s|email your-email@example.com|email $MY_EMAIL|" /opt/emby-proxy/Caddyfile
fi

# 5. Systemd 服务
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

# 6. 自动赋权
echo -e "\( {YELLOW}>>> 设置文件执行权限... \){NC}"
chmod +x /opt/emby-proxy/emby-proxy 2>/dev/null || true
chmod +x /opt/emby-proxy/caddy 2>/dev/null || true

systemctl daemon-reload
systemctl enable --now emby-backend caddy-proxy

echo -e "\n\( {GREEN}部署完成！ \){NC}"
echo -e "访问地址: https://$DOMAIN:$EX_PORT"
echo -e "\( {YELLOW}提示： \){NC}"
echo -e "1. Caddy 会自动申请并续期证书（首次可能需要 1-2 分钟）"
echo -e "2. 查看日志: journalctl -u caddy-proxy -f"
echo -e "3. 重启命令: systemctl restart emby-backend caddy-proxy"
