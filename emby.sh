#!/bin/bash
set -e

# --- 变量配置 ---
CONF_TARGET="/etc/nginx/conf.d/emby.conf"

# --- 1. 获取输入 ---
read -p "请输入你的代理域名 (如 auto2.oneq1st.dpdns.org): " DOMAIN
read -p "请输入你的代理端口 (如 40889): " PROXY_PORT

# 自动寻找证书
CERT_PATH=$(find /etc/letsencrypt/live/$DOMAIN "$HOME/.acme.sh/${DOMAIN}_ecc" /etc/nginx/ssl/$DOMAIN -name "fullchain.pem" -o -name "fullchain.cer" 2>/dev/null | head -n 1)
KEY_PATH=$(find /etc/letsencrypt/live/$DOMAIN "$HOME/.acme.sh/${DOMAIN}_ecc" /etc/nginx/ssl/$DOMAIN -name "privkey.pem" -o -name "*.key" 2>/dev/null | head -n 1)

if [[ -z "$CERT_PATH" ]]; then
    echo "未找到证书，请检查路径" && exit 1
fi

# --- 2. 生成配置 (使用 'EOF' 防止变量被 Shell 提前解析) ---
echo "正在生成 Nginx 配置..."

cat > "$CONF_TARGET" << 'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen {{PORT}} ssl http2;
    server_name {{DOMAIN}};

    ssl_certificate {{CERT}};
    ssl_certificate_key {{KEY}};

    merge_slashes off;
    client_max_body_size 0;

    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;

    # 兼容 Hills 和 Capyplayer 的万能正则
    location ~* "^/(?<raw_proto>https?|wss?)://(?<raw_target>[a-zA-Z0-9\.-]+)(?:[:/_](?<raw_port>\d+))?(?<raw_path>/.*)?$" {
        
        set $target_proto $raw_proto;
        set $target_port "";
        if ($raw_port != "") { set $target_port ":$raw_port"; }
        set $final_path $raw_path;
        if ($final_path = "") { set $final_path "/"; }

        proxy_pass $target_proto://$raw_target$target_port$final_path$is_args$args;

        # 核心：内容改写
        proxy_set_header Accept-Encoding ""; 
        sub_filter_types *;
        sub_filter_once off;
        
        # 动态替换所有后端返回的链接，加上当前代理的域名和端口
        sub_filter ':"http' ':"$scheme://$http_host/http';
        sub_filter '\"http' '\"$scheme://$http_host/http';
        sub_filter 'http://' '$scheme://$http_host/http://';
        sub_filter 'https://' '$scheme://$http_host/https://';
        
        # 处理转义格式
        sub_filter 'http\:\/\/' '$scheme\:\/\/$http_host\/http\:\/\/';
        sub_filter 'https\:\/\/' '$scheme\:\/\/$http_host\/https\:\/\/';

        # 劫持重定向
        proxy_redirect ~*^https?://(?<re_host>[^/]+)(?<re_path>.*)$ $scheme://$http_host/https://$re_host$re_path;

        # 基础头设置
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $raw_target;
        
        proxy_ssl_server_name on;
        proxy_ssl_name $raw_target;
        proxy_ssl_verify off;

        # 针对 Capyplayer 的强力跨域支持
        proxy_hide_header 'Access-Control-Allow-Origin';
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' '*' always;
        add_header 'Access-Control-Allow-Headers' '*' always;
        add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range' always;

        if ($request_method = 'OPTIONS') { return 204; }

        proxy_buffering off;
        proxy_request_buffering off;
        proxy_set_header X-Accel-Buffering no;
        proxy_force_ranges on;
    }

    location / { return 404 "Use /http://target:port/ format"; }
}
EOF

# --- 3. 替换占位符 ---
sed -i "s|{{PORT}}|$PROXY_PORT|g" "$CONF_TARGET"
sed -i "s|{{DOMAIN}}|$DOMAIN|g" "$CONF_TARGET"
sed -i "s|{{CERT}}|$CERT_PATH|g" "$CONF_TARGET"
sed -i "s|{{KEY}}|$KEY_PATH|g" "$CONF_TARGET"

# --- 4. 重启测试 ---
if nginx -t; then
    systemctl restart nginx
    echo "配置成功！端口: $PROXY_PORT"
else
    echo "Nginx 配置有误，请检查输出。"
    exit 1
fi
