# --- [3] Nginx 部署（最终优化版：支持 40889 + Basic Auth + 单站多 Emby）---
deploy_nginx() {
    local TYPE=$1; local D=$2
    local CONF="/etc/nginx/conf.d/emby_\( {TYPE}_ \){D}.conf"

    cat > "$CONF.tmp" << 'EOF'
server {
    listen 443 ssl http2;
    listen 40889 ssl http2;     # 运营商映射的外部端口
    server_name __DOMAIN__;

    ssl_certificate /etc/nginx/ssl/__DOMAIN__/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/__DOMAIN__/privkey.pem;

    resolver 8.8.8.8 1.1.1.1 valid=30s;

    proxy_buffering off;
    proxy_request_buffering off;
    proxy_max_temp_file_size 0;

    # 非 Emby 客户端返回自定义 404
    error_page 403 /emby-404.html;
    if ($is_emby_client = 0) { return 403; }

    location = /emby-404.html {
        root /etc/nginx;
        internal;
    }
EOF

    if [[ "$TYPE" == "universal" ]]; then
        # 万能反代
        cat >> "$CONF.tmp" << 'EOF'

    location / {
        proxy_pass http://127.0.0.1:8080;

        proxy_buffering off;
        proxy_request_buffering off;
        proxy_max_temp_file_size 0;

        # 原项目要求的核心 header
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $http_host;
        proxy_set_header X-Forwarded-Port $server_port;
        
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        # 解决 Emby 401 Unauthorized（传递 Basic Auth）
        proxy_set_header Authorization $http_authorization;
        proxy_pass_header Authorization;
    }
}
EOF
    else
        # 单站反代（互动式多 Emby 服务）
        echo -e "\( {CYAN}=== 单站多 Emby 服务配置（互动模式）=== \){NC}"
        echo "请逐个添加 Emby 服务，输入空路径前缀时结束。"

        local count=1
        while true; do
            echo -e "\n${YELLOW}第 \( {count} 个 Emby 服务 \){NC}"
            read -p "路径前缀 (例如 /emby1 或 /media，直接回车结束): " PREFIX
            [[ -z "$PREFIX" ]] && break
            [[ "${PREFIX:0:1}" != "/" ]] && PREFIX="/$PREFIX"

            read -p "目标后端地址 (例如 https://emby1.example.com): " TARGET

            cat >> "$CONF.tmp" << EOF

    # 单站服务 ${count}: ${PREFIX} → ${TARGET}
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

    # 启动 emby-proxy
    if ! pgrep -f emby-proxy >/dev/null; then
        echo -e "\( {YELLOW}正在启动 emby-proxy... \){NC}"
        nohup "$PROXY_BIN" > "$LOG_FILE" 2>&1 &
        echo -e "\( {GREEN}emby-proxy 已启动。 \){NC}"
    fi

    # systemd 自启动（保持不变）
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
        echo -e "客户端访问方式："
        echo -e "https://auto2.oneq1st.dpdns.org:40889/https/目标域名/443/..."
    else
        echo -e "\( {RED}Nginx 配置测试失败！ \){NC}"
        rm -f "$CONF"
        return 1
    fi
}
