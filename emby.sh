#!/bin/bash

# ==================================================
# 颜色与样式定义
# ==================================================
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
BLUE='\e[36m'
PURPLE='\e[35m'
BOLD='\e[1m'
NC='\e[0m'

clear
echo -e "${BLUE}${BOLD}┌────────────────────────────────────────────────────────┐${NC}"
echo -e "${BLUE}${BOLD}│  hkfires/EmbyProxy + Caddy(含CF) 智能全自检部署脚本    │${NC}"
echo -e "${BLUE}${BOLD}└────────────────────────────────────────────────────────┘${NC}"

# ==================================================
# 基础工具函数
# ==================================================
check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# ==================================================
# 独立执行块：环境依赖库安装 (Debian/Ubuntu)
# ==================================================
install_deps_debian() {
    echo -e "${YELLOW} ℹ 开始独立安装 Debian 系必要工具和依赖库...${NC}"
    apt-get update -y
    apt-get install -y curl tar wget git openssl jq psmisc debian-keyring debian-archive-keyring apt-transport-https
    if [ $? -ne 0 ]; then
        echo -e "${RED} ✖ [错误] Debian 基础依赖安装失败！请检查网络或软件源。${NC}"
        exit 1
    fi
    echo -e "${GREEN} ✔ Debian 依赖库安装完毕。${NC}"
}

# ==================================================
# 独立执行块：环境依赖库安装 (Alpine)
# ==================================================
install_deps_alpine() {
    echo -e "${YELLOW} ℹ 开始独立安装 Alpine 系必要工具和依赖库...${NC}"
    apk update
    apk add curl tar wget git openssl jq psmisc bash coreutils libc6-compat
    if [ $? -ne 0 ]; then
        echo -e "${RED} ✖ [错误] Alpine 基础依赖安装失败！请检查网络或软件源。${NC}"
        exit 1
    fi
    echo -e "${GREEN} ✔ Alpine 依赖库安装完毕。${NC}"
}

# ==================================================
# 系统环境智能识别
# ==================================================
if [ -f /etc/alpine-release ]; then
    OS_TYPE="alpine"
    INIT_SYSTEM="openrc"
elif [ -f /etc/debian_version ] || [ -f /etc/lsb-release ]; then
    OS_TYPE="debian"
    INIT_SYSTEM="systemd"
else
    if command -v apk >/dev/null 2>&1; then
        OS_TYPE="alpine"
        INIT_SYSTEM="openrc"
    else
        OS_TYPE="debian"
        INIT_SYSTEM="systemd"
    fi
fi

# ==================================================
# 0. 互动式功能选择
# ==================================================
echo -e "\n${BLUE}${BOLD}📊 请选择要执行的操作：${NC}"
echo -e "  ${BOLD}1)${NC} ${GREEN}智能自检部署 / 更新环境${NC}"
echo -e "  ${BOLD}2)${NC} ${RED}一键完全卸载 (清理服务与数据)${NC}"
read -p " 请输入数字 [1/2]: " MAIN_CHOICE

# ----------------- 卸载逻辑分支 -----------------
if [ "$MAIN_CHOICE" == "2" ]; then
    echo -e "\n${YELLOW}${BOLD}⚠️  警告：该操作将停止并删除 EmbyProxy 与 Caddy 服务，清空所有相关配置、证书与数据库！${NC}"
    read -p " 确认要继续卸载吗？(y/n, 默认 n): " CONFIRM_UNINSTALL
    if [[ ! "$CONFIRM_UNINSTALL" =~ ^[Yy](es)?$ ]]; then
        echo -e "${GREEN} ℹ 已取消卸载操作。${NC}"
        exit 0
    fi

    echo -e "\n${BLUE}${BOLD}▶ 正在清理系统服务...${NC}"
    echo -e "${BLUE}──────────────────────────────────────────────────${NC}"
    
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        for svc in emby-backend caddy; do
            if systemctl is-active --quiet "$svc" || systemctl is-enabled --quiet "$svc" 2>/dev/null; then
                echo -e "${YELLOW} ℹ 正在停止并禁用服务: $svc...${NC}"
                systemctl stop "$svc" >/dev/null 2>&1
                systemctl disable "$svc" >/dev/null 2>&1
            fi
        done
        rm -f /etc/systemd/system/emby-backend.service
        rm -f /etc/systemd/system/caddy.service
        systemctl daemon-reload
    else
        for svc in emby-backend caddy; do
            if rc-service "$svc" status >/dev/null 2>&1; then
                echo -e "${YELLOW} ℹ 正在停止服务: $svc...${NC}"
                rc-service "$svc" stop >/dev/null 2>&1
            fi
            if rc-update show default | grep -q "$svc"; then
                echo -e "${YELLOW} ℹ 正在移除自启: $svc...${NC}"
                rc-update del "$svc" default >/dev/null 2>&1
            fi
            rm -f /etc/init.d/$svc
        done
    fi
    echo -e "${GREEN} ✔ 系统服务配置清理完毕。${NC}"

    echo -e "${YELLOW} ℹ 正在删除程序目录与配置文件...${NC}"
    rm -rf /opt/emby-proxy
    rm -rf /etc/caddy
    echo -e "${GREEN} ✔ 部署目录（含数据库、证书、Caddyfile）已彻底删除。${NC}"

    if [ "$OS_TYPE" = "debian" ] && [ -f "/etc/apt/sources.list.d/caddy-stable.list" ]; then
        read -p " 是否同步卸载 Caddy 的 APT 软件源与主程序？(y/n, 默认 n): " RM_CADDY_APT
        if [[ "$RM_CADDY_APT" =~ ^[Yy](es)?$ ]]; then
            echo -e "${YELLOW} ℹ 正在卸载 Caddy 软件源及主程序...${NC}"
            apt-get purge -y caddy >/dev/null 2>&1
            rm -f /etc/apt/sources.list.d/caddy-stable.list
            rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
            apt-get update -y >/dev/null 2>&1
            echo -e "${GREEN} ✔ Caddy APT 源及主程序已卸载。${NC}"
        fi
    elif [ "$OS_TYPE" = "alpine" ]; then
        read -p " 是否同步卸载通过 apk 安装的 Caddy 主程序？(y/n, 默认 n): " RM_CADDY_APK
        if [[ "$RM_CADDY_APK" =~ ^[Yy](es)?$ ]]; then
            echo -e "${YELLOW} ℹ 正在卸载 Caddy 主程序...${NC}"
            apk del caddy >/dev/null 2>&1
            echo -e "${GREEN} ✔ Caddy 主程序已卸载。${NC}"
        fi
    fi

    echo -e "\n${GREEN}${BOLD}┌────────────────────────────────────────────────────────┐${NC}"
    echo -e "${GREEN}${BOLD}│ 🎉 卸载完成！EmbyProxy 相关服务及文件已彻底清理干净。  │${NC}"
    echo -e "${GREEN}${BOLD}└────────────────────────────────────────────────────────┘${NC}\n"
    exit 0

elif [ "$MAIN_CHOICE" != "1" ]; then
    echo -e "${RED} ✖ [错误] 输入无效，脚本退出。${NC}"
    exit 1
fi

# ==================================================
# 部署逻辑初始化
# ==================================================
mkdir -p /etc/caddy
mkdir -p /opt/emby-proxy/ssl
mkdir -p /opt/emby-proxy/data

# ==================================================
# 1. 执行独立的依赖检查与安装块
# ==================================================
echo -e "\n${BLUE}${BOLD}▶ [步骤 1/6] 正在检查系统基础依赖环境...${NC}"
echo -e "${BLUE}──────────────────────────────────────────────────${NC}"

NEED_INSTALL=false
for cmd in curl tar wget git openssl jq gpg; do
    if ! check_cmd "$cmd"; then
        NEED_INSTALL=true
        break
    fi
done

if [ "$NEED_INSTALL" = true ]; then
    echo -e "${YELLOW} ℹ 发现系统基础依赖不完整，进入独立安装流程...${NC}"
    if [ "$OS_TYPE" = "debian" ]; then
        install_deps_debian
    else
        install_deps_alpine
    fi
else
    echo -e "${GREEN} ✔ [已通过] 基础系统依赖完整，无需重复安装。${NC}"
fi

# ==================================================
# 2. Caddy 及其插件就绪状态检查
# ==================================================
echo -e "\n${BLUE}${BOLD}▶ [步骤 2/6] 正在检查 Caddy 服务及 Cloudflare 插件状态...${NC}"
echo -e "${BLUE}──────────────────────────────────────────────────${NC}"
CADDY_READY=false
CADDY_BIN="/usr/bin/caddy"

if check_cmd "caddy"; then
    CADDY_BIN=$(command -v caddy)
    echo -e "${YELLOW} ℹ 检测到系统已安装 Caddy，正在校验 Cloudflare 插件...${NC}"
    if "$CADDY_BIN" list-modules | grep -q "dns.providers.cloudflare"; then
        echo -e "${GREEN} ✔ [已通过] 找到完全符合要求的 Caddy (已集成 CF 插件)，跳过安装。${NC}"
        CADDY_READY=true
    else
        echo -e "${YELLOW} ℹ 提示：当前 Caddy 缺失 CF 插件。准备在线热补丁集成...${NC}"
    fi
fi

if [ "$CADDY_READY" = false ]; then
    if ! check_cmd "caddy"; then
        if [ "$OS_TYPE" = "debian" ]; then
            echo -e "${YELLOW} ℹ 正在配置 Caddy 官方 APT 存储库...${NC}"
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
            apt-get update -y && apt-get install -y caddy
            if [ $? -ne 0 ]; then
                echo -e "${RED} ✖ [错误] 标准版 Caddy 安装失败！${NC}"
                exit 1
            fi
            CADDY_BIN="/usr/bin/caddy"
        else
            echo -e "${YELLOW} ℹ 正在通过 apk 安装官方 Caddy...${NC}"
            apk add caddy
            if [ $? -ne 0 ]; then
                echo -e "${RED} ✖ [错误] Alpine 标准版 Caddy 安装失败！${NC}"
                exit 1
            fi
            CADDY_BIN="/usr/sbin/caddy"
            [ ! -f "$CADDY_BIN" ] && CADDY_BIN=$(command -v caddy)
        fi
    fi

    echo -e "${YELLOW} ℹ 正在向 Caddy 注入 cloudflare 插件 (请耐心等待大约 1 分钟)...${NC}"
    "$CADDY_BIN" add-package github.com/caddy-dns/cloudflare
    if [ $? -ne 0 ]; then
        echo -e "${RED} ✖ [错误] 插件集成失败！请检查 VPS 连接 github.com 的网络状态。${NC}"
        exit 1
    fi
    echo -e "${GREEN} ✔ Caddy 及其插件环境配置成功！${NC}"
fi

# ==================================================
# 3. 后端 hkfires/EmbyProxy 下载与部署（带文件名修正）
# ==================================================
echo -e "\n${BLUE}${BOLD}▶ [步骤 3/6] 正在检查与部署 hkfires/EmbyProxy 后端...${NC}"
echo -e "${BLUE}──────────────────────────────────────────────────${NC}"
ARCH=$(uname -m)
PROXY_EXEC="/opt/emby-proxy/embyproxy"

if [ "$ARCH" = "x86_64" ]; then
    DL_ARCH="x64"
elif [ "$ARCH" = "aarch64" ]; then
    DL_ARCH="arm64"
else
    echo -e "${RED} ✖ [错误] 暂不支持当前架构: $ARCH${NC}"
    exit 1
fi

if [ -x "$PROXY_EXEC" ]; then
    echo -e "${GREEN} ✔ [已通过] $PROXY_EXEC 已存在且具备执行权限，跳过下载。${NC}"
else
    echo -e "${YELLOW} ℹ 正在通过 GitHub API 获取最新版本下载链接 (架构: $DL_ARCH)...${NC}"
    LATEST_URL=$(curl -s https://api.github.com/repos/hkfires/EmbyProxy/releases/latest | grep "browser_download_url.*embyproxy-linux-${DL_ARCH}.tar.gz" | cut -d '"' -f 4)
    
    if [ -z "$LATEST_URL" ]; then
         echo -e "${YELLOW} ℹ 无法通过 API 获取链接，尝试拼接默认 Latest 链接...${NC}"
         LATEST_URL="https://github.com/hkfires/EmbyProxy/releases/latest/download/embyproxy-linux-${DL_ARCH}.tar.gz"
    fi

    echo -e "${YELLOW} ℹ 正在下载: $LATEST_URL${NC}"
    wget -qO /tmp/embyproxy.tar.gz "$LATEST_URL"
    if [ $? -eq 0 ]; then
        tar -xzf /tmp/embyproxy.tar.gz -C /opt/emby-proxy/
        
        # 修正逻辑：如果解压出来的是带架构后缀的文件 (如 embyproxy-linux-x64)，重命名为 embyproxy
        if [ -f "/opt/emby-proxy/embyproxy-linux-${DL_ARCH}" ]; then
            mv "/opt/emby-proxy/embyproxy-linux-${DL_ARCH}" "$PROXY_EXEC"
        fi

        chmod +x "$PROXY_EXEC"
        rm -f /tmp/embyproxy.tar.gz
        echo -e "${GREEN} ✔ 后端 EmbyProxy 下载并规范化重命名成功。${NC}"
    else
        echo -e "${RED} ✖ [错误] 后端程序下载失败，请检查网络连通性。${NC}"
        exit 1
    fi
fi

# ==================================================
# 4. ADMIN_TOKEN 自动生成与 .env 配置写入
# ==================================================
echo -e "\n${BLUE}${BOLD}▶ [步骤 4/6] 配置后端通讯安全密钥与环境变量...${NC}"
echo -e "${BLUE}──────────────────────────────────────────────────${NC}"
ENV_FILE="/opt/emby-proxy/.env"
EXISTING_TOKEN=""

if [ -f "$ENV_FILE" ]; then
    EXISTING_TOKEN=$(grep -oP '^ADMIN_TOKEN=\K.*' "$ENV_FILE")
fi

if [ -n "$EXISTING_TOKEN" ]; then
    ADMIN_TOKEN="$EXISTING_TOKEN"
    echo -e "${GREEN} ✔ 检测到旧版服务中已有管理密钥，已自动继承保留。${NC}"
else
    ADMIN_TOKEN=$(openssl rand -hex 16)
    echo -e "${GREEN} ✔ 已生成全新随机安全密钥。${NC}"
fi

cat <<EOF > "$ENV_FILE"
ADMIN_TOKEN=$ADMIN_TOKEN
PORT=8787
DB_PATH=./data/proxy.db
EOF
echo -e "${GREEN} ✔ 环境变量文件 (.env) 已生成。${NC}"

# ==================================================
# 5. 域名输入与证书智能扫描
# ==================================================
echo -e "\n${BLUE}${BOLD}▶ [步骤 5/6] 域名配置与 Caddy 证书设置...${NC}"
echo -e "${BLUE}──────────────────────────────────────────────────${NC}"
read -p " 请输入您的域名 (例如: example.com): " DOMAIN

if [ -z "$DOMAIN" ]; then
    echo -e "${RED} ✖ [错误] 域名不能为空！${NC}"
    exit 1
fi

CERT_FILE="/opt/emby-proxy/ssl/fullchain.pem"
KEY_FILE="/opt/emby-proxy/ssl/privkey.pem"
USE_EXISTING_CERT=false

POSSIBLE_CERTS=(
    "$CERT_FILE"
    "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    "/etc/acme.sh/${DOMAIN}_ecc/fullchain.cer"
    "$HOME/.acme.sh/${DOMAIN}_ecc/fullchain.cer"
    "$HOME/.acme.sh/${DOMAIN}/fullchain.cer"
    "/root/.acme.sh/${DOMAIN}_ecc/fullchain.cer"
    "/etc/ssl/$DOMAIN/fullchain.pem"
)

POSSIBLE_KEYS=(
    "$KEY_FILE"
    "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    "/etc/acme.sh/${DOMAIN}_ecc/$DOMAIN.key"
    "$HOME/.acme.sh/${DOMAIN}_ecc/$DOMAIN.key"
    "$HOME/.acme.sh/${DOMAIN}/$DOMAIN.key"
    "/root/.acme.sh/${DOMAIN}_ecc/$DOMAIN.key"
    "/etc/ssl/$DOMAIN/privkey.pem"
)

echo -e "${YELLOW} ℹ 正在扫描本地常见路径寻找 [$DOMAIN] 的证书...${NC}"
for idx in "${!POSSIBLE_CERTS[@]}"; do
    cert_path="${POSSIBLE_CERTS[$idx]}"
    key_path="${POSSIBLE_KEYS[$idx]}"
    
    if [ -s "$cert_path" ] && [ -s "$key_path" ]; then
        if openssl x509 -in "$cert_path" -noout -text 2>/dev/null | grep -q "$DOMAIN"; then
            echo -e "${GREEN} ✔ [匹配成功] 发现本地有效证书: $cert_path${NC}"
            if [ "$cert_path" != "$CERT_FILE" ]; then
                ln -sf "$cert_path" "$CERT_FILE"
                ln -sf "$key_path" "$KEY_FILE"
            fi
            USE_EXISTING_CERT=true
            break
        fi
    fi
done

if [ "$USE_EXISTING_CERT" = false ]; then
    echo -e "${YELLOW} ℹ 提示：未自动发现匹配 [$DOMAIN] 的本地证书。${NC}"
    read -p " 是否需要手动配置/粘贴源服务器证书？(y/n, 默认 n): " PROVIDE_CERT
    
    if [[ "$PROVIDE_CERT" =~ ^[Yy](es)?$ ]]; then
        echo -e "\n 请选择提供证书的方式:"
        echo -e "  ${BOLD}1)${NC} 输入绝对文件路径"
        echo -e "  ${BOLD}2)${NC} 直接手动粘贴证书/私钥文本"
        read -p " 请选择 [1/2]: " CERT_INPUT_MODE
        
        if [ "$CERT_INPUT_MODE" == "1" ]; then
            read -p " 证书完整路径 (fullchain.pem/.crt): " USER_CERT
            read -p " 私钥完整路径 (privkey.pem/.key): " USER_KEY
            
            if [ -s "$USER_CERT" ] && [ -s "$USER_KEY" ]; then
                ln -sf "$USER_CERT" "$CERT_FILE"
                ln -sf "$USER_KEY" "$KEY_FILE"
                echo -e "${GREEN} ✔ 自定义本地证书导入成功！${NC}"
                USE_EXISTING_CERT=true
            else
                echo -e "${RED} ✖ 路径不存在或不可读，退回 Caddy 自动申请方案。${NC}"
            fi
            
        elif [ "$CERT_INPUT_MODE" == "2" ]; then
            echo -e "\n${YELLOW}┌─────────────────── 证书粘贴引导框 ───────────────────┐${NC}"
            echo -e "${YELLOW}│ 请粘贴您的证书内容，完成后另起一行输入 ${BOLD}EOF${NC}${YELLOW} 并回车确认：│${NC}"
            echo -e "${YELLOW}└──────────────────────────────────────────────────────┘${NC}"
            rm -f "$CERT_FILE"
            while IFS= read -r line; do
                [[ "$line" == "EOF" ]] && break
                echo "$line" >> "$CERT_FILE"
            done
            
            echo -e "\n${YELLOW}┌─────────────────── 私钥粘贴引导框 ───────────────────┐${NC}"
            echo -e "${YELLOW}│ 请粘贴您的私钥内容，完成后另起一行输入 ${BOLD}EOF${NC}${YELLOW} 并回车确认：│${NC}"
            echo -e "${YELLOW}└──────────────────────────────────────────────────────┘${NC}"
            rm -f "$KEY_FILE"
            while IFS= read -r line; do
                [[ "$line" == "EOF" ]] && break
                echo "$line" >> "$KEY_FILE"
            done
            
            if [ -s "$CERT_FILE" ] && [ -s "$KEY_FILE" ] && openssl x509 -in "$CERT_FILE" -noout >/dev/null 2>&1; then
                echo -e "${GREEN} ✔ 粘贴的证书解析保存成功！${NC}"
                USE_EXISTING_CERT=true
            else
                echo -e "${RED} ✖ 证书解析失败，退回 Caddy 自动申请方案。${NC}"
                rm -f "$CERT_FILE" "$KEY_FILE"
            fi
        fi
    fi
fi

# 参数收集
read -p " 域名访问端口 (默认 443): " DOMAIN_PORT
DOMAIN_PORT=${DOMAIN_PORT:-443}
read -p " HTTPS 监听端口 (默认 443): " HTTPS_PORT
HTTPS_PORT=${HTTPS_PORT:-443}
read -p " HTTP 默认端口 (默认 80): " HTTP_PORT
HTTP_PORT=${HTTP_PORT:-80}
read -p " 通知邮箱 (用于证书申请): " MY_EMAIL

if [ "$USE_EXISTING_CERT" = false ]; then
    echo -e "\n 请选择 Caddy 证书申请/验证方式:"
    echo -e "  ${BOLD}1)${NC} Cloudflare DNS 挑战 (${PURPLE}推荐${NC})"
    echo -e "  ${BOLD}2)${NC} HTTP 自动挑战 (需对外开放 HTTP 端口)"
    echo -e "  ${BOLD}3)${NC} Caddy 自动自签证书 (tls internal)"
    read -p " 选择 [1/2/3]: " AUTH_MODE
    
    if [ "$AUTH_MODE" == "1" ]; then
        read -p " 请输入 Cloudflare API Token: " CF_TOKEN
    fi
fi

# ==================================================
# 6. 动态生成 Caddyfile 与系统服务设置
# ==================================================
echo -e "\n${BLUE}${BOLD}▶ [步骤 6/6] 生成 Caddyfile 与注册系统服务...${NC}"
echo -e "${BLUE}──────────────────────────────────────────────────${NC}"

CADDYFILE_PATH="/opt/emby-proxy/Caddyfile"

GLOBAL_BLOCK="email $MY_EMAIL\n    http_port $HTTP_PORT\n    https_port $HTTPS_PORT"

if [ "$USE_EXISTING_CERT" = true ]; then
    TLS_CONFIG="tls $CERT_FILE $KEY_FILE"
elif [ "$AUTH_MODE" == "1" ]; then
    GLOBAL_BLOCK="${GLOBAL_BLOCK}\n    acme_dns cloudflare ${CF_TOKEN}"
    TLS_CONFIG=""
elif [ "$AUTH_MODE" == "3" ]; then
    TLS_CONFIG="tls internal"
else
    TLS_CONFIG="tls {\n        acme_ca https://acme-v02.api.letsencrypt.org/directory\n    }"
fi

cat <<EOF > "$CADDYFILE_PATH"
{
    $(echo -e "$GLOBAL_BLOCK")
}

$DOMAIN:$DOMAIN_PORT {
    $(echo -e "$TLS_CONFIG")

    handle {
        reverse_proxy 127.0.0.1:8787 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            flush_interval -1
        }
    }
}
EOF

# ==================================================
# 服务配置与重启 (Systemd / OpenRC)
# ==================================================
if [ "$INIT_SYSTEM" = "systemd" ]; then
    cat <<EOF > /etc/systemd/system/emby-backend.service
[Unit]
Description=hkfires EmbyProxy Backend
After=network.target

[Service]
WorkingDirectory=/opt/emby-proxy
ExecStart=$PROXY_EXEC
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    cat <<EOF > /etc/systemd/system/caddy.service
[Unit]
Description=Caddy Web Server
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=root
Group=root
ExecStart=$CADDY_BIN run --environ --config $CADDYFILE_PATH
ExecReload=$CADDY_BIN reload --config $CADDYFILE_PATH --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now emby-backend caddy >/dev/null 2>&1
    systemctl restart emby-backend caddy >/dev/null 2>&1

else
    cat <<EOF > /etc/init.d/emby-backend
#!/sbin/openrc-run
description="hkfires EmbyProxy Backend"
supervisor="supervise-daemon"
command="$PROXY_EXEC"
directory="/opt/emby-proxy"
respawn_delay=5
respawn_max=0

depend() {
    need net
    after firewall
}
EOF
    chmod +x /etc/init.d/emby-backend

    cat <<EOF > /etc/init.d/caddy
#!/sbin/openrc-run
description="Caddy Web Server"
supervisor="supervise-daemon"
command="$CADDY_BIN"
command_args="run --config $CADDYFILE_PATH"
directory="/opt/emby-proxy"

depend() {
    need net
    after firewall
}
EOF
    chmod +x /etc/init.d/caddy

    rc-update add emby-backend default >/dev/null 2>&1
    rc-update add caddy default >/dev/null 2>&1
    rc-service emby-backend restart >/dev/null 2>&1
    rc-service caddy restart >/dev/null 2>&1
fi

sleep 2

# ==================================================
# 看板信息输出
# ==================================================
echo -e "\n${GREEN}${BOLD}┌────────────────────────────────────────────────────────┐${NC}"
echo -e "${GREEN}${BOLD}│ 🎉 部署完毕！各项环境依赖和系统组件已构建完成。        │${NC}"
echo -e "${GREEN}${BOLD}└────────────────────────────────────────────────────────┘${NC}"

echo -e " ${BOLD}📊 [配置服务运行看板]${NC}"
echo -e " ────────────────────────────────────────────────────────"
echo -e "  🌐 面板访问地址:  ${GREEN}${BOLD}https://$DOMAIN:$DOMAIN_PORT/admin${NC}"
echo -e "  🔑 接口管理密钥:  ${PURPLE}${BOLD}${ADMIN_TOKEN}${NC}  ${YELLOW}(请务必妥善保存此密码)${NC}"
echo -e "  📁 数据库存放地:  ${BLUE}/opt/emby-proxy/data/proxy.db${NC}"
echo -e "  📄 Caddy配置路径:  ${BLUE}$CADDYFILE_PATH${NC}"

STATUS_CADDY=false
STATUS_BACKEND=false

if [ "$INIT_SYSTEM" = "systemd" ]; then
    systemctl is-active --quiet caddy && STATUS_CADDY=true
    systemctl is-active --quiet emby-backend && STATUS_BACKEND=true
    DIAG_CMD="journalctl -u caddy -n 20"
else
    rc-service caddy status >/dev/null 2>&1 && STATUS_CADDY=true
    rc-service emby-backend status >/dev/null 2>&1 && STATUS_BACKEND=true
    DIAG_CMD="rc-service caddy status"
fi

if [ "$STATUS_CADDY" = true ]; then
    echo -e "  ⚡ Caddy 前端状态: ${GREEN}${BOLD}● Running (正常运行)${NC}"
else
    echo -e "  ⚡ Caddy 前端状态: ${RED}${BOLD}● Failed (启动异常，请用 '$DIAG_CMD' 诊断)${NC}"
fi

if [ "$STATUS_BACKEND" = true ]; then
    echo -e "  ⚡ Proxy 后端状态: ${GREEN}${BOLD}● Running (正常运行)${NC}"
else
    echo -e "  ⚡ Proxy 后端状态: ${RED}${BOLD}● Failed (启动异常)${NC}"
fi
echo -e " ────────────────────────────────────────────────────────\n"
