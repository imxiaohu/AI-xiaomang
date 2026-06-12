# ============================================================
# AI小芒 后端 — 多阶段 Dockerfile
# 构建: docker build -t ai-video-backend ./backend
# 运行: docker run -d -p 8000:8000 --env-file ./backend/.env ai-video-backend
# ============================================================

# ---- 构建阶段 ----
FROM python:3.11-slim AS builder

WORKDIR /app

# 安装编译依赖（阿里云 SDK 等需要）
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    g++ \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt


# ---- 运行阶段 ----
FROM python:3.11-slim

WORKDIR /app

# 安装运行时依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgomp1 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# 从 builder 复制已安装的 Python 包
COPY --from=builder /root/.local /root/.local
ENV PATH=/root/.local/bin:$PATH

# 复制应用代码
COPY . .

# 环境变量
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"

EXPOSE 8000

# 启动
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
