# Nginx SSE 反向代理完整配置

## 一、背景

SSE（Server-Sent Events）在生产环境需要通过 Nginx 反向代理，主要原因：
1. 移动端无法直接访问非标准端口（80/443）
2. 需要 SSL/TLS 终结（HTTPS）
3. 需要负载均衡和健康检查
4. 需要限制连接超时防止资源耗尽

## 二、Nginx 配置

### 2.1 基本 SSE 代理配置

```nginx
upstream ai_video_backend {
    server 127.0.0.1:8000;
    keepalive 64;
}

server {
    listen 443 ssl http2;
    server_name your-domain.com;

    # SSL 配置（使用 Let's Encrypt 证书）
    ssl_certificate /etc/letsencrypt/live/your-domain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/your-domain.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    # SSE 专用请求日志
    access_log /var/log/nginx/ai_video_sse.access.log main;
    error_log /var/log/nginx/ai_video_sse.error.log warn;

    # 健康检查
    location /health {
        proxy_pass http://ai_video_backend;
        proxy_set_header Host $host;
        access_log off;
    }

    # SSE 下行流（核心）
    location /sse/ {
        # 禁用缓存
        proxy_cache off;

        # 禁用缓冲（必须！SSE 必须实时推送）
        proxy_buffering off;
        chunked_transfer_encoding on;

        # 超时配置（SSE 长连接需要较长超时）
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_connect_timeout 60s;

        # 禁用 X-Accel-Buffering（Nginx 自定义头）
        proxy_set_header X-Accel-Buffering no;

        # 代理头
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # 升级 WebSocket（虽然 SSE 不需要，但统一配置）
        proxy_http_version 1.1;

        proxy_pass http://ai_video_backend;
    }

    # HTTP 上传接口
    location /upload/ {
        # 小请求，可以缓冲
        proxy_buffering on;
        proxy_read_timeout 60s;

        # 限制上传大小（帧约 50KB + 音频分片）
        client_max_body_size 2m;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

        proxy_pass http://ai_video_backend;
    }

    # 根路径
    location / {
        return 200 "AI小芒 Backend OK";
        add_header Content-Type text/plain;
    }
}
```

### 2.2 连接数限制

```nginx
# 在 http {} 块中添加
limit_conn_zone $binary_remote_addr zone=addr:10m;
limit_conn addr 20;

# 限制每个 IP 的 SSE 连接数
# SSE 连接需要特殊处理（一个用户可能有多个连接）
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}
```

### 2.3 多后端负载均衡

```nginx
upstream ai_video_backend {
    least_conn;  # 最少连接优先

    server 127.0.0.1:8000 weight=3;
    server 127.0.0.1:8001 weight=2;
    server 127.0.0.1:8002 weight=1;

    keepalive 64;
}
```

## 三、Docker 部署

### 3.1 docker-compose.yml

```yaml
version: '3.8'

services:
  backend:
    build: ./backend
    ports:
      - "8000:8000"
    environment:
      - DEBUG=false
      - DASHSCOPE_API_KEY=${DASHSCOPE_API_KEY}
    volumes:
      - ./backend/.env:/app/.env:ro
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  nginx:
    image: nginx:alpine
    ports:
      - "443:443"
      - "80:80"
    volumes:
      - ./docs/nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./certs:/etc/letsencrypt/live/your-domain.com:ro
    depends_on:
      - backend
    restart: unless-stopped
```

### 3.2 Nginx 健康检查

```nginx
# upstream 中添加
upstream ai_video_backend {
    zone backend 64k;
    server 127.0.0.1:8000;
    keepalive 64;
}
```

健康检查由 `upstream_zone` 指令自动启用。

## 四、常见问题

### 4.1 SSE 在 Nginx 代理后无响应

检查：
1. `proxy_buffering off;` 是否设置（Nginx 默认缓冲会吞掉 SSE 数据）
2. `X-Accel-Buffering: no` 头是否正确传递
3. `proxy_read_timeout` 是否足够长（至少 1 小时）

### 4.2 移动端偶发连接中断

原因：Nginx 默认代理超时太短
解决：设置 `proxy_read_timeout 86400s;` 和 `proxy_send_timeout 86400s;`

### 4.3 SSL 证书问题

```bash
# 使用 certbot 获取 Let's Encrypt 证书
sudo certbot --nginx -d your-domain.com
```
