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
    
    # 强制 IPv4
    resolver 1.1.1.1 8.8.8.8 ipv6=off valid=30s;
    resolver_timeout 5s;

    # ========================================================================
    # 1. 核心捕获逻辑：更加鲁棒的正则，直接提取后端域名
    # ========================================================================
    location ~* "^/(?<p_proto>https?)://(?<p_host>[^:/]+)(?::(?<p_port>\d+))?(?<p_uri>.*)$" {
        
        # 内部变量处理
        set $p_real_port $p_port;
        if ($p_real_port = "") {
            set $p_real_port "443";
        }
        if ($p_proto = "http") {
            set $p_real_port "80";
        }

        # 构造发往后端的地址
        proxy_pass $p_proto://$p_host:$p_real_port$p_uri$is_args$args;

        # --------------------------------------------------------------------
        # 2. 内容改写 (解决 Hills/Capy 拿到真实地址的问题)
        # --------------------------------------------------------------------
        proxy_set_header Accept-Encoding ""; 
        gzip off;
        sub_filter_types *;
        sub_filter_once off;
        
        # 动态替换：利用 $http_host 自动适配当前访问的端口
        sub_filter ':"http' ':"$scheme://$http_host/http';
        sub_filter '\"http' '\"$scheme://$http_host/http';
        sub_filter 'http\:\/\/' '$scheme\:\/\/$http_host\/http\:\/\/';
        sub_filter 'https\:\/\/' '$scheme\:\/\/$http_host\/https\:\/\/';

        proxy_redirect ~*^https?://(?<re_host>[^/]+)(?<re_path>.*)$ $scheme://$http_host/https://$re_host$re_path;

        # --------------------------------------------------------------------
        # 3. 头部修正 (解决 502/Handshake 失败的关键)
        # --------------------------------------------------------------------
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        
        # 必须传后端自己的 Host，否则 Cloudflare 会拒绝连接
        proxy_set_header Host $p_host;
        
        proxy_ssl_server_name on;
        proxy_ssl_name $p_host;
        proxy_ssl_verify off;

        # 跨域全开
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

    location / { return 404 "Check Proxy Path Format"; }
}
EOF

# 变量替换
sed -i "s|{{PORT}}|$PROXY_PORT|g" "$CONF_TARGET"
sed -i "s|{{DOMAIN}}|$DOMAIN|g" "$CONF_TARGET"
sed -i "s|{{CERT}}|$CERT_PATH|g" "$CONF_TARGET"
sed -i "s|{{KEY}}|$KEY_PATH|g" "$CONF_TARGET"

nginx -t && systemctl restart nginx && echo "部署完成。如果还不通，请检查是否被防火墙拦截了 $PROXY_PORT 端口。"
