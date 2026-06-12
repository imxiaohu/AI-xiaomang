"""会话管理器：内存存储、10分钟过期清理、上下文截断"""
import asyncio
import time
from typing import Any
from config import SESSION_TIMEOUT, MAX_CONTEXT_ROUNDS


class Session:
    """单个会话"""

    def __init__(self, ctx_id: str):
        self.ctx_id = ctx_id
        self.created_at = time.time()
        self.last_active = time.time()
        # 对话上下文：每条 { "role": "user"|"assistant", "content": str 或 list }
        self.messages: list[dict[str, Any]] = []
        # 当前推理轮次（用于判断是否结束）
        self.turn_active = False
        # SSE队列
        self.sse_queue = None
        # 音频分片缓冲区（upload.py 写入，推理时消耗）
        self.audio_buffer: list[str] = []
        # 图像帧缓冲区（upload.py 写入，供 VL 推理）
        self.frame_buffer: list[dict] = []
        # 用户 ASR 转写文本（/chat/infer 调用时写入）
        self.transcribed_text: str = ""
        # 当前推理任务（用于取消旧推理）
        self.inference_task = None

    def touch(self):
        self.last_active = time.time()

    def add_message(self, role: str, content: str | list[dict], image: str | None = None):
        """
        添加消息，截断超长上下文。
        content: str（纯文本消息）或 list（多模态消息，含图片）
        """
        msg: dict[str, Any] = {"role": role, "content": content}
        if image:
            msg["image"] = image
        self.messages.append(msg)
        # 上下文截断：超过MAX_CONTEXT_ROUNDS则丢弃最早两轮
        while len(self.messages) > MAX_CONTEXT_ROUNDS * 2:
            self.messages.pop(0)
            if self.messages:
                self.messages.pop(0)

    @property
    def round_count(self) -> int:
        """当前对话轮次（assistant消息数量）"""
        return sum(1 for m in self.messages if m.get("role") == "assistant")

    def is_expired(self) -> bool:
        return time.time() - self.last_active > SESSION_TIMEOUT

    def get_context(self) -> list[dict[str, Any]]:
        """返回最近 MAX_CONTEXT_ROUNDS 轮对话（不含 system prompt）"""
        return self.messages[-MAX_CONTEXT_ROUNDS * 2:]


class SessionManager:
    """全局会话管理器"""

    def __init__(self):
        self._sessions: dict[str, Session] = {}
        self._lock = asyncio.Lock()
        self._cleanup_task: asyncio.Task | None = None

    async def start(self):
        """启动后台清理任务"""
        self._cleanup_task = asyncio.create_task(self._cleanup_loop())

    async def stop(self):
        """停止清理任务"""
        if self._cleanup_task:
            self._cleanup_task.cancel()

    async def get_or_create(self, ctx_id: str) -> Session:
        async with self._lock:
            if ctx_id not in self._sessions:
                self._sessions[ctx_id] = Session(ctx_id)
            session = self._sessions[ctx_id]
            session.touch()
            return session

    async def get(self, ctx_id: str) -> Session | None:
        async with self._lock:
            return self._sessions.get(ctx_id)

    async def remove(self, ctx_id: str):
        async with self._lock:
            self._sessions.pop(ctx_id, None)

    async def _cleanup_loop(self):
        """每60秒扫描，清理过期会话"""
        while True:
            await asyncio.sleep(60)
            expired = []
            async with self._lock:
                for ctx_id, session in self._sessions.items():
                    if session.is_expired():
                        expired.append(ctx_id)
                for ctx_id in expired:
                    self._sessions.pop(ctx_id, None)
            if expired:
                print(f"[SessionManager] Cleaned up {len(expired)} expired sessions")


# 全局单例
session_manager = SessionManager()
