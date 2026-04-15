#!/bin/bash
set -e

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

    merge_slashes off;
    
    # 【关键修复】禁用 IPv6，解决 Network is unreachable 报错
    resolver 1.1.1.1 8.8.8.8 ipv6=off valid=300s;
    resolver_timeout 5s;

    location ~* "^/(?<raw_proto>https?|wss?)://(?<raw_target>[^:/]+)(?:[:/_](?<raw_port>\d+))?(?<raw_path>.*)$" {
        
        set $target_port "";
        if ($raw_port != "") { set $target_port ":$raw_port"; }
        
        # 构造后端地址
        set $backend_url "$raw_proto://$raw_target$target_port$raw_path$is_args$args";

        proxy_pass $backend_url;

        # 内容重写
        proxy_set_header Accept-Encoding ""; 
        gzip off;
        
        sub_filter_types *;
        sub_filter_once off;
        
        # 动态替换
        sub_filter ':"http' ':"$scheme://$http_host/http';
        sub_filter '\"http' '\"$scheme://$http_host/http';
        sub_filter 'http\:\/\/' '$scheme\:\/\/$http_host\/http\:\/\/';
        sub_filter 'https\:\/\/' '$scheme\:\/\/$http_host\/https\:\/\/';

        proxy_redirect ~*^https?://(?<re_host>[^/]+)(?<re_path>.*)$ $scheme://$http_host/https://$re_host$re_path;

        # 头部设置
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $raw_target;
        
        proxy_ssl_server_name on;
        proxy_ssl_name $raw_target;
        proxy_ssl_verify off;

        # 万能跨域 (解决 CapyPlayer 报错)
        proxy_hide_header 'Access-Control-Allow-Origin';
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' '*' always;
        add_header 'Access-Control-Allow-Headers' '*' always;
        add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range' always;
        
        if ($request_method = 'OPTIONS') { return 204; }

        proxy_buffering off;
        proxy_set_header X-Accel-Buffering no;
        proxy_force_ranges on;
    }

    location / { return 404 "Network unreachable? Check IPv6."; }
}
EOF

sed -i "s|{{PORT}}|$PROXY_PORT|g" "$CONF_TARGET"
sed -i "s|{{DOMAIN}}|$DOMAIN|g" "$CONF_TARGET"
sed -i "s|{{CERT}}|$CERT_PATH|g" "$CONF_TARGET"
sed -i "s|{{KEY}}|$KEY_PATH|g" "$CONF_TARGET"

nginx -t && systemctl restart nginx && echo "修复完成！IPv6 已禁用。"
