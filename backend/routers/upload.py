"""HTTP上行路由：音频分片 + 图像帧上传"""
import json
import base64
from fastapi import APIRouter, HTTPException, Body
from pydantic import BaseModel
from services.session_manager import session_manager
from routers.sse_chat import _asr_instances

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
    转发给阿里云ASR进行实时识别
    """
    session = await session_manager.get(body.ctxId)
    if not session:
        raise HTTPException(status_code=404, detail="会话不存在")

    asr = _asr_instances.get(body.ctxId)
    if asr and body.audio:
        await asr.send_audio(body.audio)

    if body.end:
        session.touch()

    return {"code": 0, "message": "ok"}


@router.post("/frame")
async def upload_frame(body: FrameBody):
    """
    接收Flutter上传的图像帧（base64 JPG）
    触发阿里云VL推理（异步，由VL服务直接写入SSE队列推送）
    """
    session = await session_manager.get(body.ctxId)
    if not session:
        raise HTTPException(status_code=404, detail="会话不存在")

    # 图像帧已在后端缓存（此处占位，实际VL调用在sse_chat中处理）
    session.touch()
    return {"code": 0, "message": "frame_received", "index": body.index}


@router.post("/chat/end")
async def end_turn(body: EndTurnBody):
    """
    结束当前推理轮次
    触发VL生成最终回答 + TTS合成
    """
    session = await session_manager.get(body.ctxId)
    if not session:
        raise HTTPException(status_code=404, detail="会话不存在")

    session.turn_active = True
    session.touch()

    return {"code": 0, "message": "turn_ended"}
