# Nginx SSE 反向代理完整配置

本文档说明如何配置 Nginx 作为 AI小芒 FastAPI 后端的反向代理，
重点解决 SSE（Server-Sent Events）长连接在反向代理下的特殊要求。

---

## 一、关键配置说明

SSE 与普通 HTTP 请求的关键区别：

| 特性 | 普通 HTTP | SSE |
|------|---------|-----|
| 连接时长 | 短（请求-响应即关闭） | 长（分钟~小时级） |
| 方向 | 客户端发→服务端收 | 服务端推→客户端收 |
| 缓存 | 可缓存 | **禁止缓存** |
| 代理缓冲 | 开启可提升性能 | **必须关闭** |

### 为什么必须关闭代理缓冲？

当 `proxy_buffering on`（默认）时：
```
客户端 ← Nginx（缓冲） ← FastAPI
```
Nginx 会缓冲服务端的 SSE 响应，直到缓冲满了才发送给客户端。
这导致客户端无法实时接收推送，SSE 完全失效。

---

## 二、最小配置（生产可用）

```nginx
server {
    listen 443 ssl;
    server_name your-domain.com;

    ssl_certificate     /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

    # SSE 上行接口（Flutter 客户端上传音频/图像帧）
    location /upload/ {
        proxy_pass         http://127.0.0.1:8000/upload/;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;

        # HTTP 上传可开启缓冲（加速大文件上传）
        proxy_buffering    on;
        proxy_buffer_size  4k;
    }

    # SSE 下行流（核心！必须关闭缓冲）
    location /sse/ {
        proxy_pass         http://127.0.0.1:8000/sse/;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;

        # ===== SSE 必需配置 =====
        # 1. 关闭代理缓冲（实时推送）
        proxy_buffering    off;

        # 2. 关闭缓存（禁止缓存流式响应）
        proxy_cache        off;

        # 3. 关闭连接关闭（保持连接活跃）
        proxy_request_buffering off;
        proxy_intercept_errors  off;

        # 4. 关闭 Nginx 的 gzip（流式响应不应压缩）
        gzip               off;

        # 5. SSE 必需 Header
        proxy_set_header   Connection        '';
        proxy_hide_header  X-Accel-Buffering;

        # 6. 超时设置（SSE 长连接需要较长超时）
        proxy_read_timeout  10m;   # 10分钟无活动才超时
        proxy_send_timeout  300s;  # 5分钟上传超时

        # 7. 减少连接开销
        tcp_nodelay        on;
        tcp_nopush         off;

        # 8. WebSocket 兼容（备用）
        proxy_set_header   Upgrade    $http_upgrade;
        proxy_set_header   Connection "upgrade";
    }

    # 健康检查接口
    location /health {
        proxy_pass         http://127.0.0.1:8000/health;
        proxy_http_version 1.1;
        proxy_set_header   Host $host;
    }
}
```

---

## 三、完整生产配置（含 WAF/限流）

```nginx
# 全局限流定义
limit_req_zone $binary_remote_addr zone=sse_limit:10m rate=30r/m;
limit_conn_zone $binary_remote_addr zone=conn_limit:10m;

upstream ai_video_backend {
    server 127.0.0.1:8000;
    keepalive 32;
}

server {
    listen 443 ssl http2;
    server_name your-domain.com;

    ssl_certificate     /path/to/fullchain.pem;
    ssl_certificate_key /path/to/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    # 安全 Header
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options    "nosniff" always;
    add_header X-Frame-Options           "DENY" always;

    # SSE 端点（含限流）
    location /sse/ {
        limit_req    zone=sse_limit burst=10 nodelay;
        limit_conn   conn_limit 5;

        proxy_pass         http://ai_video_backend/sse/;
        proxy_http_version 1.1;

        proxy_buffering    off;
        proxy_cache        off;
        proxy_request_buffering off;
        gzip               off;

        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_set_header   Connection        '';

        proxy_read_timeout  10m;
        proxy_send_timeout  300s;
        tcp_nodelay         on;
        tcp_nopush          off;
    }

    location /upload/ {
        client_max_body_size 10m;

        proxy_pass         http://ai_video_backend/upload/;
        proxy_http_version 1.1;

        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;

        proxy_buffering    on;
        proxy_buffer_size  64k;
        proxy_busy_buffers_size 128k;

        proxy_read_timeout  300s;
        proxy_send_timeout  300s;
    }

    location /health {
        proxy_pass         http://ai_video_backend/health;
        proxy_http_version 1.1;
        proxy_set_header   Host $host;
    }

    location /docs {
        proxy_pass         http://127.0.0.1:8000/docs;
        proxy_http_version 1.1;
        proxy_set_header   Host $host;
    }
}
```

---

## 四、Docker Compose 部署

```yaml
version: '3.8'
services:
  backend:
    build: ./backend
    restart: unless-stopped
    ports:
      - "127.0.0.1:8000:8000"  # 仅本地监听，Nginx 代理
    environment:
      - DEBUG=false
    volumes:
      - ./backend/.env:/app/.env:ro

  nginx:
    image: nginx:alpine
    restart: unless-stopped
    ports:
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    depends_on:
      - backend
```

---

## 五、常见错误与解决

| 错误现象 | 原因 | 解决 |
|---------|------|------|
| SSE 只收到第一条消息 | `proxy_buffering on` | 设置 `proxy_buffering off` |
| SSE 连接被 Nginx 关闭 | `proxy_read_timeout` 太小 | 设置足够大的超时（如 `10m`） |
| Flutter 端收到 502 | Nginx upstream 配置错误 | 检查 `proxy_pass` 地址是否可访问 |
| SSE 响应被 gzip 压缩 | 全局开启了 gzip | 在 SSE location 中设置 `gzip off` |
| WebSocket 升级失败 | 未设置 Upgrade Header | 添加 `proxy_set_header Upgrade $http_upgrade` |

---

## 六、测试验证

```bash
# 测试 SSE 是否正确（无需 Flutter 客户端）
curl -N \
  -H "Accept: text/event-stream" \
  -H "Cache-Control: no-cache" \
  "http://localhost:8000/sse/chat?ctxId=test&token=dev_token"

# 观察：
# 1. 连接保持打开（不立即关闭）
# 2. 每3秒收到一次 heartbeat 事件
# 3. 无缓存 header（如 X-Cache-Status: MISS）
```
