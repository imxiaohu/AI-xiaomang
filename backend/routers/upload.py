"""HTTP上行路由：音频分片 + 图像帧上传"""
import asyncio
import json
import base64
from fastapi import APIRouter, HTTPException, Body
from pydantic import BaseModel
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
    session = await session_manager.get(body.ctxId)
    if not session:
        raise HTTPException(status_code=404, detail="会话不存在")

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
    存入会话的最近帧缓冲区，供VL推理使用
    """
    session = await session_manager.get(body.ctxId)
    if not session:
        raise HTTPException(status_code=404, detail="会话不存在")

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
    从 session 取出音频缓冲区和最近帧，触发VL推理 + TTS合成
    结果写入 SSE 队列推送
    """
    session = await session_manager.get(body.ctxId)
    if not session:
        raise HTTPException(status_code=404, detail="会话不存在")

    session.turn_active = True
    session.touch()

    # 异步触发推理
    asyncio.create_task(trigger_session_inference(session, body.ctxId))

    return {"code": 0, "message": "turn_ended"}
