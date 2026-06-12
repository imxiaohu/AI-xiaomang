# Nginx SSE 反向代理配置

## 核心配置参数

```nginx
# ==============================
# AI小芒 SSE 反向代理配置
# ==============================

server {
    listen 443 ssl http2;
    server_name your-domain.com;

    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

    # SSE 必须关闭代理缓存，否则流式响应被截断
    proxy_buffering off;

    # SSE 长连接超时：10分钟（600秒）
    # 客户端默认30秒心跳，超时应自动重连
    proxy_read_timeout 10m;
    proxy_send_timeout 10m;

    # WebSocket 支持（用于阿里云 ASR WebSocket）
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";

    # 请求体大小（图像帧最大约50KB）
    client_max_body_size 100k;

    # GZip 压缩（对文本JSON有效，对二进制流无效）
    gzip on;
    gzip_types application/json text/event-stream;

    location / {
        # 代理到 FastAPI 后端
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # SSE 专用路径
    location /sse/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 10m;
        proxy_send_timeout 10m;
        proxy_set_header Host $host;
        # SSE 不支持自定义 Header，鉴权参数必须放 URL query string
    }

    # HTTP 上传路径
    location /upload/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
        client_max_body_size 100k;
    }
}
```

## 关键参数说明

| 参数 | 值 | 说明 |
|------|-----|------|
| `proxy_buffering` | `off` | **必须**，SSE 流式响应关闭代理缓存 |
| `proxy_read_timeout` | `10m` | 600秒，客户端最长等待时间 |
| `proxy_send_timeout` | `10m` | 后端发送超时 |
| `gzip_types` | `text/event-stream` | SSE 事件流启用压缩（节省带宽） |
| `client_max_body_size` | `100k` | 限制上传体大小，图像帧 ≤ 50KB |

## 本地开发验证

```bash
# 启动后端
cd backend && uvicorn main:app --host 0.0.0.0 --port 8000

# 验证 SSE 连接
curl -N -H "Accept: text/event-stream" \
    "http://localhost:8000/sse/chat?ctxId=test&token=dev"

# 使用 nginx 本地转发验证
# nginx -c /path/to/nginx.conf -t
# nginx -c /path/to/nginx.conf
```

## 常见问题

### SSE 响应被截断
- 检查 `proxy_buffering off` 是否在 `location /sse/` 中也配置
- 检查是否有 CDN 或网关层额外缓存

### 连接 5xx 后立即断开
- 检查后端是否在 10 分钟内发送任何数据
- SSE 心跳 3s/次，超时 5s 无响应客户端重连

### iOS Safari SSE 不工作
- Safari 要求 HTTPS，必须有有效的 SSL 证书
- 自签名证书在 Safari 不被信任

### Android WebView SSE 不工作
- Android 4.4 以下 WebView 不支持 SSE
- 建议升级 WebView 或使用 polyfill
