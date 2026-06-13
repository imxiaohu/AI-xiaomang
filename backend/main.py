"""FastAPI 应用入口"""
import asyncio
from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from routers import sse_chat, upload, tripo_3d, model_download
from services.session_manager import session_manager
from services import marketplace_db
from config import MODELS_CACHE_DIR
import os


@asynccontextmanager
async def lifespan(app: FastAPI):
    """应用生命周期管理"""
    # 启动：初始化 3D 形象市场数据库 & 启动会话清理后台任务
    marketplace_db.init_db()
    # 初始化离线模型缓存目录
    os.makedirs(MODELS_CACHE_DIR, exist_ok=True)
    print(f"[main] offline models cache dir: {MODELS_CACHE_DIR}")
    await session_manager.start()
    yield
    # 关闭：停止清理任务
    await session_manager.stop()


app = FastAPI(
    title="AI小芒 后端服务",
    description="AI视觉语音对话助手 FastAPI后端",
    version="1.0.0",
    lifespan=lifespan,
)

# CORS（允许移动端跨域）
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# GZip压缩
app.add_middleware(GZipMiddleware, minimum_size=1024)

# 注册路由
app.include_router(sse_chat.router)
app.include_router(upload.router)
app.include_router(tripo_3d.router)
app.include_router(model_download.router)


@app.get("/health")
async def health():
    """健康检查"""
    return {"status": "ok", "version": "1.0.0"}


@app.get("/")
async def root():
    return {"message": "AI小芒 Backend", "docs": "/docs"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
