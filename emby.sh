# --- [3] Nginx 部署（已为单站和万能都加强 Authorization 头传递）---
deploy_nginx() {
    local TYPE=$1; local D=$2
    local CONF="/etc/nginx/conf.d/emby_\( {TYPE}_ \){D}.conf"

    cat > "$CONF.tmp" << 'EOF'
server {
    listen 443 ssl http2;
    listen 40889 ssl http2;
    server_name __DOMAIN__;
    ssl_certificate /etc/nginx/ssl/__DOMAIN__/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/__DOMAIN__/privkey.pem;

    resolver 8.8.8.8 1.1.1.1 valid=30s;

    proxy_buffering off;
    proxy_request_buffering off;
    proxy_max_temp_file_size 0;

    error_page 403 /emby-404.html;
    if ($is_emby_client = 0) { return 403; }

    location = /emby-404.html {
        root /etc/nginx;
        internal;
    }
EOF

    if [[ "$TYPE" == "universal" ]]; then
        cat >> "$CONF.tmp" << 'EOF'

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_max_temp_file_size 0;

        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $http_host;
        proxy_set_header X-Forwarded-Port $server_port;
        
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        # 关键修复：传递客户端的 Authorization 头（解决 Basic Auth 401）
        proxy_set_header Authorization $http_authorization;
        proxy_pass_header Authorization;
    }
}
EOF
    else
        # 单站反代 - 互动式多 Emby 服务
        echo -e "\( {CYAN}=== 单站多 Emby 服务配置（互动模式）=== \){NC}"
        echo "请逐个添加 Emby 服务，输入空路径前缀时结束。"

        local count=1
        while true; do
            echo -e "\n${YELLOW}第 \( {count} 个 Emby 服务 \){NC}"
            read -p "路径前缀 (例如 /emby1 或 /media，直接回车结束): " PREFIX
            [[ -z "$PREFIX" ]] && break
            [[ "${PREFIX:0:1}" != "/" ]] && PREFIX="/$PREFIX"

            read -p "目标后端地址: " TARGET

            cat >> "$CONF.tmp" << EOF

    location \~* ^${PREFIX}(/.*)?\$ {
        proxy_pass ${TARGET};
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_max_temp_file_size 0;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
EOF
            count=$((count + 1))
        done

        cat >> "$CONF.tmp" << 'EOF'

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_max_temp_file_size 0;
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $http_host;
        proxy_set_header X-Forwarded-Port $server_port;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        # 传递 Basic Auth 头
        proxy_set_header Authorization $http_authorization;
        proxy_pass_header Authorization;
    }
}
EOF
    fi

    sed "s|__DOMAIN__|$D|g" "$CONF.tmp" > "$CONF"
    rm -f "$CONF.tmp"

    if ! pgrep -f emby-proxy >/dev/null; then
        echo -e "\( {YELLOW}正在启动 emby-proxy... \){NC}"
        nohup "$PROXY_BIN" > "$LOG_FILE" 2>&1 &
        echo -e "\( {GREEN}emby-proxy 已启动。 \){NC}"
    fi

    if [[ ! -f "$SERVICE_FILE" ]]; then
        cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Emby Reverse Proxy Service
After=network.target

[Service]
Type=simple
ExecStart=$PROXY_BIN
WorkingDirectory=/usr/local/bin
Restart=always
RestartSec=5
User=root
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now emby-proxy.service
        echo -e "\( {GREEN}emby-proxy 已设置为开机自启动。 \){NC}"
    fi

    if nginx -t; then
        systemctl restart nginx
        echo -e "\( {GREEN}部署成功！ \){NC}"
        echo -e "客户端使用端口 40889"
        echo -e "示例: https://auto2.oneq1st.dpdns.org:40889/https/ask.ash.yt/443/web/index.html"
    else
        echo -e "\( {RED}Nginx 配置测试失败！ \){NC}"
        rm -f "$CONF"
        return 1
    fi
}
