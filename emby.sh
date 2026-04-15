#!/bin/bash
set -e

# --- 变量配置 ---
CONF_TARGET="/etc/nginx/conf.d/emby.conf"
SSL_DIR="/etc/nginx/ssl"

# --- 颜色 ---
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- 1. 环境检查 ---
echo -e "${GREEN}正在配置 Nginx 万能动态反代环境...${NC}"

read -p "请输入你的代理域名 (例如 auto2.oneq1st.dpdns.org): " DOMAIN
read -p "请输入你的代理端口 (例如 40889): " PROXY_PORT

# 自动寻找证书路径
CERT_PATH=$(find /etc/letsencrypt/live/$DOMAIN "$HOME/.acme.sh/${DOMAIN}_ecc" "$SSL_DIR/$DOMAIN" -name "fullchain.pem" -o -name "fullchain.cer" 2>/dev/null | head -n 1)
KEY_PATH=$(find /etc/letsencrypt/live/$DOMAIN "$HOME/.acme.sh/${DOMAIN}_ecc" "$SSL_DIR/$DOMAIN" -name "privkey.pem" -o -name "*.key" 2>/dev/null | head -n 1)

if [[ -z "$CERT_PATH" || -z "$KEY_PATH" ]]; then
    echo -e "${RED}错误: 未找到域名 $DOMAIN 的 SSL 证书，请先申请证书。${NC}"
    exit 1
fi

# --- 2. 生成完整配置 ---
cat > "$CONF_TARGET" << EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

# 播放器识别
map \$http_user_agent \$is_emby_client {
    default 0;
    "~*(Hills|yamby|Afuse|Capy|Fileball|Infuse|SenPlayer|VLC|VidHub|Emby|Android|iOS)" 1;
}

server {
    listen $PROXY_PORT ssl http2;
    server_name $DOMAIN;

    ssl_certificate $CERT_PATH;
    ssl_certificate_key $KEY_PATH;

    # 关键设置：禁止合并斜杠，允许 https:// 正常传递
    merge_slashes off;
    client_max_body_size 0;

    # 动态解析后端域名
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;

    # ========================================================================
    # 核心匹配逻辑：抓取 /协议://域名:端口/路径
    # ========================================================================
    location ~* "^/(?<raw_proto>https?|wss?)://(?<raw_target>[a-zA-Z0-9\.-]+)(?:[:/_](?<raw_port>\d+))?(?<raw_path>/.*)?\$" {
        
        # 提取参数
        set \$target_proto \$raw_proto;
        set \$target_port "";
        if (\$raw_port != "") { set \$target_port ":\$raw_port"; }
        set \$final_path \$raw_path;
        if (\$final_path = "") { set \$final_path "/"; }

        # 反代执行
        proxy_pass \$target_proto://\$raw_target\$target_port\$final_path\$is_args\$args;

        # --------------------------------------------------------------------
        # 【核心黑科技】全自动内容抓取与 URL 劫持
        # --------------------------------------------------------------------
        # A. 必须强行禁用后端 Gzip，否则 Nginx 抓不到明文 URL
        proxy_set_header Accept-Encoding ""; 
        
        # B. 开启全量内容扫描 (涵盖所有流媒体索引和 API 响应)
        sub_filter_types application/json text/xml text/plain text/javascript application/javascript application/x-mpegurl;
        sub_filter_once off;

        # C. 深度递归重写：把所有后端返回的域名套上你的代理前缀
        # 使用 \$http_host 自动处理当前域名和 $PROXY_PORT 端口
        sub_filter ':"http' ':"\$scheme://\$http_host/http';
        sub_filter '\"http' '\"\$scheme://\$http_host/http';
        
        # 针对 Emby 转义 URL (http\:\/\/) 进行抓取重写
        sub_filter 'http\:\/\/' '\$scheme\:\/\/\$http_host\/http\:\/\/';
        sub_filter 'https\:\/\/' '\$scheme\:\/\/\$http_host\/https\:\/\/';
        
        # 针对末尾端口的兼容性修正
        sub_filter '\:443' '\/443';

        # D. 劫持 302 重定向
        proxy_redirect ~*^https?://(?<re_host>[^/]+)(?<re_path>.*)\$ \$scheme://\$http_host/https://\$re_host\$re_path;

        # --------------------------------------------------------------------
        # 【兼容性修复】解决 CapyPlayer 播放失败的关键：CORS 跨域补全
        # --------------------------------------------------------------------
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$raw_target; 
        
        proxy_ssl_server_name on;
        proxy_ssl_name \$raw_target;
        proxy_ssl_verify off;

        # 强行覆盖后端跨域头，确保播放器有权读取数据流
        proxy_hide_header 'Access-Control-Allow-Origin';
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, RANGE' always;
        add_header 'Access-Control-Allow-Headers' '*' always;
        add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range' always;
        
        # 处理 OPTIONS 预检请求（CapyPlayer 非常依赖这个）
        if (\$request_method = 'OPTIONS') { 
            add_header 'Access-Control-Max-Age' 1728000;
            add_header 'Content-Type' 'text/plain; charset=utf-8';
            add_header 'Content-Length' 0;
            return 204; 
        }

        # 视频传输性能优化
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_set_header X-Accel-Buffering no;
        proxy_force_ranges on;
    }

    location / {
        return 404 "Invalid Proxy URL Format.";
    }
}
EOF

# --- 3. 重启 ---
if nginx -t; then
    systemctl restart nginx
    echo -e "${GREEN}配置已成功应用！${NC}"
    echo -e "请在 CapyPlayer 中使用地址: ${CYAN}https://$DOMAIN:$PROXY_PORT/https://ask.ash.yt:443${NC}"
else
    echo -e "${RED}Nginx 配置错误，请检查日志。${NC}"
    exit 1
fi
