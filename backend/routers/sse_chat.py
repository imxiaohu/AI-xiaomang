"""SSE路由：文本分片 + MP3音频分片 + 心跳推送"""
import asyncio
import json
import uuid
from typing import AsyncGenerator
from fastapi import APIRouter, Query, HTTPException
from fastapi.responses import StreamingResponse
from sse_starlette.sse import EventSourceResponse
from config import SSE_HEARTBEAT_INTERVAL
from services.session_manager import session_manager
from services.aliyun_asr import AliyunASR
from services.aliyun_vl import AliyunVL
from services.aliyun_tts import AliyunTTS

router = APIRouter(prefix="/sse", tags=["sse"])

# 每个会话的ASR实例
_asr_instances: dict[str, AliyunASR] = {}


async def sse_event_stream(ctx_id: str, token: str) -> AsyncGenerator[dict, None]:
    """
    SSE事件流生成器
    事件类型：text / audio / end / heartbeat / error / quota_exceeded
    """
    session = await session_manager.get(ctx_id)
    if not session:
        yield {"event": "error", "data": json.dumps({"code": "invalid_session", "message": "会话不存在或已过期"})}
        return

    asr = AliyunASR()
    _asr_instances[ctx_id] = asr

    # 注册文本回调
    async def on_asr_text(text: str):
        await sse_queue.put({"event": "text", "data": json.dumps({"text": text, "is_final": False})})

    try:
        await asr.connect(on_asr_text)
    except Exception as e:
        yield {"event": "error", "data": json.dumps({"code": "asr_connect", "message": str(e)})}

    # SSE队列
    sse_queue = asyncio.Queue()
    session.sse_queues.append(sse_queue)

    # 心跳任务
    async def heartbeat():
        while True:
            await asyncio.sleep(SSE_HEARTBEAT_INTERVAL)
            await sse_queue.put({"event": "heartbeat", "data": "ping"})

    heartbeat_task = asyncio.create_task(heartbeat())

    try:
        while True:
            event = await sse_queue.get()
            yield event
    except asyncio.CancelledError:
        pass
    finally:
        heartbeat_task.cancel()
        await asr.close()
        _asr_instances.pop(ctx_id, None)


@router.get("/chat")
async def sse_chat(
    ctxId: str = Query(..., description="会话ID"),
    token: str = Query(..., description="认证token"),
):
    """
    SSE下行流接口

    URL参数携带鉴权（避免SSE跨域自定义Header问题）
    SSE响应头必须设置：Content-Type: text/event-stream, Cache-Control: no-cache, X-Accel-Buffering: no
    """
    async def event_generator():
        async for event in sse_event_stream(ctxId, token):
            yield event

    return EventSourceResponse(
        event_generator(),
        headers={
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
            "Access-Control-Allow-Origin": "*",
        },
    )
