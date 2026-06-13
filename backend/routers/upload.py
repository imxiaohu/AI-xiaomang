"""HTTP上行路由：音频分片 + 图像帧上传"""
import asyncio
import json
import base64
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from config import OMNI_MODE
from services.session_manager import session_manager
from routers.sse_chat import trigger_session_inference

router = APIRouter(prefix="/upload", tags=["upload"])


class AudioChunkBody(BaseModel):
    ctxId: str
    audio: str  # base64编码的PCM
    end: bool = False


class FrameBody(BaseModel):
    ctxId: str
    frame: str  # base64编码的JPG
    index: int = 0


class EndTurnBody(BaseModel):
    ctxId: str


@router.post("/audio_chunk")
async def upload_audio_chunk(body: AudioChunkBody):
    """
    接收Flutter上传的音频分片（base64 PCM）
    并写入对应会话的音频缓冲区
    """
    session = await session_manager.get_or_create(body.ctxId)

    if body.audio:
        session.audio_buffer.append(body.audio)
        session.touch()

    if body.end:
        session.turn_active = True
        session.touch()

    return {"code": 0, "message": "ok"}


@router.post("/frame")
async def upload_frame(body: FrameBody):
    """
    接收Flutter上传的图像帧（base64 JPG）
    存入会话的最近帧缓冲区，供VL推理或Omni推理使用
    """
    session = await session_manager.get_or_create(body.ctxId)

    session.frame_buffer.append({
        "frame": body.frame,
        "index": body.index,
    })
    session.touch()
    return {"code": 0, "message": "frame_received", "index": body.index}


@router.post("/chat/end")
async def end_turn(body: EndTurnBody):
    """
    结束当前推理轮次

    - Omni 模式（OMNI_MODE=true）：调用 Qwen-Omni-Realtime，
      音频+帧通过 WebSocket 转发，流式 PCM 音频通过 SSE 推送
    - 分离模式（OMNI_MODE=false）：调用 VL+TTS 分离推理流水线，
      流式文本+MP3 通过 SSE 推送
    """
    session = await session_manager.get_or_create(body.ctxId)

    session.turn_active = True
    session.touch()

    if OMNI_MODE:
        # Omni 模式：在 endTurn 触发推理（绕过 trigger_session_inference）
        asyncio.create_task(_omni_inference(session, body.ctxId))
    else:
        # 分离模式：走原有 VL+TTS 流水线
        asyncio.create_task(trigger_session_inference(session, body.ctxId))

    return {"code": 0, "message": "turn_ended"}


async def _omni_inference(session, ctx_id: str):
    """
    Omni 模式推理：音频 + 图像帧 → Qwen-Omni-Realtime
    结果通过 session.sse_queue 推送 SSE 事件
    """
    from services.aliyun_omni import OmniService

    sse_queue = session.sse_queue
    if sse_queue is None:
        sse_queue = asyncio.Queue()
        session.sse_queue = sse_queue

    try:
        omni = OmniService()
        if not omni.is_configured:
            await sse_queue.put({
                "event": "error",
                "data": json.dumps({"code": "omni_not_configured", "message": "OMNI_MODE enabled but DASHSCOPE_API_KEY not configured"}),
            })
            return

        audio_chunks = list(session.audio_buffer)
        frame_data = session.frame_buffer[-1] if session.frame_buffer else None
        frame_b64 = frame_data["frame"] if frame_data else None

        result = await omni.run_turn(
            audio_chunks=audio_chunks,
            frame_b64=frame_b64,
            sse_queue=sse_queue,
        )

        full_text = result.get("full_text", "")
        audio_seconds = result.get("audio_seconds", 0.0)

        # 保存上下文
        if full_text:
            session.add_message("user", session.transcribed_text or "（语音输入）")
            session.add_message("assistant", full_text)
        session.transcribed_text = ""
        session.touch()

        await sse_queue.put({
            "event": "end",
            "data": json.dumps({"full_text": full_text, "audio_seconds": audio_seconds}),
        })

    except asyncio.CancelledError:
        raise
    except Exception as e:
        print(f"[Omni] Inference error: {e}")
        try:
            await sse_queue.put({
                "event": "error",
                "data": json.dumps({"code": "omni_error", "message": str(e)}),
            })
        except Exception:
            pass
    finally:
        session.audio_buffer.clear()
        session.turn_active = False
