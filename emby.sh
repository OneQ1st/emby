#!/bin/bash
set -e

# --- 配置 ---
CONF_TARGET="/etc/nginx/conf.d/emby.conf"

read -p "请输入代理域名: " DOMAIN
read -p "请输入代理端口: " PROXY_PORT

# 自动寻找证书
CERT_PATH=$(find /etc/letsencrypt/live/$DOMAIN "$HOME/.acme.sh/${DOMAIN}_ecc" /etc/nginx/ssl/$DOMAIN -name "fullchain.pem" -o -name "fullchain.cer" 2>/dev/null | head -n 1)
KEY_PATH=$(find /etc/letsencrypt/live/$DOMAIN "$HOME/.acme.sh/${DOMAIN}_ecc" /etc/nginx/ssl/$DOMAIN -name "privkey.pem" -o -name "*.key" 2>/dev/null | head -n 1)

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

    # 关键：不要合并斜杠
    merge_slashes off;
    
    # 动态解析
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;

    # ========================================================================
    # 核心匹配逻辑：放宽正则，优先抓取协议和域名
    # ========================================================================
    location ~* "^/(?<raw_proto>https?|wss?)://(?<raw_target>[^:/]+)(?:[:/_](?<raw_port>\d+))?(?<raw_path>.*)$" {
        
        set $target_port "";
        if ($raw_port != "") { set $target_port ":$raw_port"; }
        
        # 构造后端完整地址
        set $backend_url "$raw_proto://$raw_target$target_port$raw_path$is_args$args";

        proxy_pass $backend_url;

        # --------------------------------------------------------------------
        # 全自动内容重写 (抓取并改写播放列表)
        # --------------------------------------------------------------------
        proxy_set_header Accept-Encoding ""; 
        gzip off; # 强制关闭 gzip，确保 sub_filter 生效
        
        sub_filter_types *;
        sub_filter_once off;
        
        # 动态替换：将后端返回的所有真实域名替换为代理域名+端口
        sub_filter ':"http' ':"$scheme://$http_host/http';
        sub_filter '\"http' '\"$scheme://$http_host/http';
        
        # 处理转义格式 (针对 Emby)
        sub_filter 'http\:\/\/' '$scheme\:\/\/$http_host\/http\:\/\/';
        sub_filter 'https\:\/\/' '$scheme\:\/\/$http_host\/https\:\/\/';

        # 劫持 302 重定向
        proxy_redirect ~*^https?://(?<re_host>[^/]+)(?<re_path>.*)$ $scheme://$http_host/https://$re_host$re_path;

        # --------------------------------------------------------------------
        # 头部与跨域设置 (针对 CapyPlayer 优化)
        # --------------------------------------------------------------------
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $raw_target;
        
        proxy_ssl_server_name on;
        proxy_ssl_name $raw_target;
        proxy_ssl_verify off;

        # 强制万能跨域
        proxy_hide_header 'Access-Control-Allow-Origin';
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' '*' always;
        add_header 'Access-Control-Allow-Headers' '*' always;
        
        if ($request_method = 'OPTIONS') { return 204; }

        proxy_buffering off;
        proxy_set_header X-Accel-Buffering no;
        proxy_force_ranges on;
    }

    location / { return 404 "Invalid Proxy URL Format."; }
}
EOF

# 替换占位符
sed -i "s|{{PORT}}|$PROXY_PORT|g" "$CONF_TARGET"
sed -i "s|{{DOMAIN}}|$DOMAIN|g" "$CONF_TARGET"
sed -i "s|{{CERT}}|$CERT_PATH|g" "$CONF_TARGET"
sed -i "s|{{KEY}}|$KEY_PATH|g" "$CONF_TARGET"

nginx -t && systemctl restart nginx && echo "配置已恢复并增强！"
