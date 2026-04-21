#!/bin/bash
set -e

# --- 基础定义 ---
REPO_RAW_URL="https://raw.githubusercontent.com/OneQ1st/emby/main"
PROXY_BIN="/usr/local/bin/emby-proxy"
SSL_DIR="/etc/nginx/ssl"
MAP_CONF="/etc/nginx/conf.d/emby_maps.conf"
HASH_FIX_CONF="/etc/nginx/conf.d/00_map_hash_fix.conf"   # 改名前缀，确保最早加载
NOT_FOUND_HTML="/etc/nginx/emby-404.html"
ACME="$HOME/.acme.sh/acme.sh"
LOG_FILE="/var/log/emby-proxy.log"

# --- 颜色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- [1] 初始化环境（加强 map_hash 修复）---
init_env() {
    echo -e "${CYAN}正在初始化环境并下载 emby-proxy 二进制... ${NC}"
    apt update && apt install -y nginx-full curl openssl socat psmisc lsof cron wget ca-certificates

    systemctl enable --now cron

    # 加强 map_hash 修复 - 使用 00_ 前缀确保最早加载
    echo -e "${YELLOW}正在创建 map_hash 修复配置（优先加载）... ${NC}"
    cat > "$HASH_FIX_CONF" << 'EOF'
# 优先加载 - 解决 map_hash_bucket_size: 64 报错
map_hash_bucket_size 512;
map_hash_max_size 8192;
EOF

    echo -e "${YELLOW}正在下载 emby-proxy 二进制文件... ${NC}"
    curl -sLo "$PROXY_BIN" "$REPO_RAW_URL/emby-proxy" && chmod +x "$PROXY_BIN"
    
    echo -e "${YELLOW}正在下载 emby-404.html... ${NC}"
    curl -sLo "$NOT_FOUND_HTML" "$REPO_RAW_URL/emby-404.html"

    cat > "$MAP_CONF" << 'EOF'
map $http_upgrade $connection_upgrade { default upgrade; '' close; }
map $http_user_agent $is_emby_client {
    default 0;
    "\~*(Hills|yamby|Afuse|Capy|Fileball|Infuse|SenPlayer|VLC|VidHub|Emby|Android|iOS)" 1;
}
EOF

    echo -e "${GREEN}环境初始化完成（map_hash 已加强修复）。 ${NC}"
}

# --- 其余函数（check_cert、apply_cert、deploy_nginx、manage_config）保持你原来的代码不变 ---
# ...（为节省篇幅，这里省略，你可以保留你上一个版本中的 check_cert、apply_cert、deploy_nginx、manage_config 和菜单部分）

# --- 菜单 --- 
# （请保留你上一个版本中的菜单部分，包括选项 1\~6）

# 注意：请把上面 init_env 替换进去，其余部分使用你上一个完整脚本的内容
