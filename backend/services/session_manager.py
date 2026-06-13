"""会话管理器：内存存储、10分钟过期清理、上下文截断"""
import asyncio
import time
from typing import Any
from config import SESSION_TIMEOUT, MAX_CONTEXT_ROUNDS
from services.event_bus import EventBus


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
        # 音频分片缓冲区（upload.py 写入，推理时消耗）
        self.audio_buffer: list[str] = []
        # 图像帧缓冲区（upload.py 写入，供 VL 推理）
        self.frame_buffer: list[dict] = []
        # 用户 ASR 转写文本（/chat/infer 调用时写入）
        self.transcribed_text: str = ""
        # 当前推理任务（用于取消旧推理）
        self.inference_task = None
        # Omni 交互模式："manual"（长按）或 "vad"（自动检测）
        self.interaction_mode: str = "manual"
        # VAD 模式持久会话（OmniVadSession 实例）
        self.omni_vad_session = None
        # ── EventBus：SSE 事件总线（替代旧的 sse_queue + sse_ready）────────
        # 每会话一个总线：发布者（推理/VAD 模式）写入，订阅者（SSE 连接）读取
        # 支持 Last-Event-ID 续传：消费者断线后能补送遗漏事件
        self.event_bus: EventBus = EventBus()
        # SSE 订阅者登记表：subscriber_id -> 用于清理
        self._sse_subscriber_ids: set[int] = set()
        # 当前轮次的"事件起点 id"：在 /chat/end 被调用时**同步**设置。
        # 作用：让任何后续才连上的 SSE 订阅者都能从这个位置开始重放本轮事件。
        # 解决"客户端先发 chat/end、后连 SSE"导致事件丢失的竞态。
        self.turn_start_id: int = 0

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

    def register_sse_subscriber(self) -> int:
        """
        SSE 消费者上线时调用，注册到总线并返回 subscriber_id。

        初始确认位置选择策略：
        - 若当前有进行中的 turn（turn_active=True），从 turn_start_id 开始
          → 解决"chat/end 之后才连 SSE"的竞态（关键修复）
        - 否则从最新 event_id 开始（新订阅者不重放过老历史）
        """
        sid = self.event_bus.new_subscriber()
        if self.turn_active:
            # 有未结束的轮次：从轮次起点开始订阅（补送本轮所有事件）
            self.event_bus._subscribers[sid] = self.turn_start_id
        # else: 保持 new_subscriber 的默认（= _next_id，不重放）
        self._sse_subscriber_ids.add(sid)
        return sid

    def unregister_sse_subscriber(self, sid: int) -> None:
        """SSE 消费者断开时调用，清理订阅者记录。"""
        self.event_bus.remove_subscriber(sid)
        self._sse_subscriber_ids.discard(sid)

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
            session = self._sessions.pop(ctx_id, None)
        if session is not None:
            # 关闭 EventBus：唤醒所有在 wait 的订阅者，让它们能正常退出
            try:
                await session.event_bus.close()
            except Exception:
                pass

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
