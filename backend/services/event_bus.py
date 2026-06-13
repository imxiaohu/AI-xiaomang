"""
EventBus: per-session event bus with replay support.

设计目标：
1. 解决 SSE 消费者断开时事件丢失的问题（弱网 / App 切后台 / hot restart）
2. 支持多消费者同时订阅
3. 支持 Last-Event-ID 续传：消费者断线后回来能补送遗漏事件
4. 内存安全：消费者确认后可 trim 已投递事件，防止泄漏

并发模型：
- 单 asyncio event loop 内安全
- publish() 分配单调递增 event_id，写入 _log，notify_all 唤醒所有订阅者
- subscribe() 先按 last_id 重放历史，再订阅新事件
- trim() 由消费者在确认后调用，回收已被所有订阅者确认的事件
"""
import asyncio
from typing import AsyncIterator


class EventBus:
    """Per-session event bus with replay + multi-subscriber support."""

    def __init__(self) -> None:
        # 已发布的事件日志（按 id 严格递增）
        self._log: list[tuple[int, dict]] = []
        self._next_id: int = 0
        # 保护 _log / _next_id / _subscribers 的 Condition
        self._cond = asyncio.Condition()
        # 订阅者位置表：subscriber_id -> 已确认的最大 event_id
        self._subscribers: dict[int, int] = {}
        self._next_subscriber_id: int = 0
        self._closed: bool = False

    # ── 状态查询 ──────────────────────────────────────────────
    @property
    def is_closed(self) -> bool:
        return self._closed

    @property
    def size(self) -> int:
        """当前未 trim 的事件数量（用于诊断/测试）。"""
        return len(self._log)

    @property
    def next_id(self) -> int:
        return self._next_id

    # ── 发布 ──────────────────────────────────────────────────
    async def publish(self, event: dict) -> int:
        """
        发布一个事件，返回分配的 event_id。
        """
        async with self._cond:
            if self._closed:
                return -1
            self._next_id += 1
            eid = self._next_id
            self._log.append((eid, event))
            self._cond.notify_all()
            return eid

    # ── 订阅 ──────────────────────────────────────────────────
    def new_subscriber(self) -> int:
        """
        注册一个新订阅者，返回 subscriber_id。
        初始确认位置 = 当前最新 event_id（新订阅者不重放过老历史）。
        """
        sid = self._next_subscriber_id
        self._next_subscriber_id += 1
        self._subscribers[sid] = self._next_id
        return sid

    def remove_subscriber(self, sid: int) -> None:
        """订阅者断开时调用，清理其在 _subscribers 中的记录。"""
        self._subscribers.pop(sid, None)

    def get_subscriber_position(self, sid: int) -> int:
        """获取订阅者已确认的最大 event_id（公开 API）。"""
        return self._subscribers.get(sid, 0)

    async def subscribe(
        self,
        sid: int,
        last_id: int | None = None,
    ) -> AsyncIterator[tuple[int, dict]]:
        """
        订阅事件流（异步迭代器）。

        Args:
            sid: new_subscriber() 返回的订阅者 ID
            last_id: Last-Event-ID 续传起点；None 表示使用 new_subscriber() 时的
                     初始确认位置（即"新订阅者不重放过老历史"）

        Yields:
            (event_id, event_dict) 元组
        """
        # 新订阅者默认从 new_subscriber() 时的位置开始
        # 调用方传入 last_id 可用于 Last-Event-ID 续传
        if last_id is None:
            last_id = self._subscribers.get(sid, 0)

        # 1. 重放历史（锁外 yield，避免持锁 yield 阻塞 publish）
        to_replay = await self._snapshot_after(last_id)
        for eid, event in to_replay:
            # 先更新订阅者位置（保证消费者 break 时位置已落盘）
            self._subscribers[sid] = eid
            yield eid, event

        # 2. 订阅新事件
        last_seen_id = self._subscribers.get(sid, last_id)
        while True:
            # 在锁内检查并取出新事件
            async with self._cond:
                if self._closed:
                    return
                next_idx = self._bisect_replay_start(last_seen_id)
                if next_idx < len(self._log):
                    eid, event = self._log[next_idx]
                    self._subscribers[sid] = eid
                else:
                    # 没有新事件，等待 publish
                    await self._cond.wait()
                    continue
            # 锁外 yield
            yield eid, event
            last_seen_id = eid

    async def _snapshot_after(self, last_id: int) -> list[tuple[int, dict]]:
        """在锁内复制 [last_id+1, ...] 的事件快照，锁外迭代。"""
        async with self._cond:
            start = self._bisect_replay_start(last_id)
            return list(self._log[start:])

    # ── 回收 ──────────────────────────────────────────────────
    async def trim(self) -> None:
        """
        回收已被所有订阅者确认的事件，防止内存泄漏。

        策略：找到所有订阅者中最小确认位置，删除其之前的所有事件。
        """
        async with self._cond:
            if not self._subscribers:
                # 无订阅者：保留最近 100 条作为缓冲
                if len(self._log) > 100:
                    self._log = self._log[-100:]
                return
            min_acked = min(self._subscribers.values())
            cut = self._bisect_replay_start(min_acked)
            if cut > 0:
                del self._log[:cut]
                # 不需要 notify：trim 不影响订阅者

    async def close(self) -> None:
        """关闭总线，唤醒所有订阅者并停止。"""
        async with self._cond:
            self._closed = True
            self._cond.notify_all()

    # ── 内部 ──────────────────────────────────────────────────
    def _bisect_replay_start(self, last_id: int) -> int:
        """二分查找：找到 _log 中第一个 id > last_id 的位置。"""
        lo, hi = 0, len(self._log)
        while lo < hi:
            mid = (lo + hi) // 2
            if self._log[mid][0] <= last_id:
                lo = mid + 1
            else:
                hi = mid
        return lo
