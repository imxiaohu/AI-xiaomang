"""HTTP上行路由：音频分片 + 图像帧上传 + 交互模式切换"""
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


class ModeBody(BaseModel):
    ctxId: str
    mode: str  # "manual" | "vad"


@router.post("/mode")
async def set_interaction_mode(body: ModeBody):
    """
    切换 Omni 交互模式：
    - manual：长按发送语音（每次推理创建临时 WS）
    - vad：自动语音检测（维护持久 WS 长连接）
    """
    if body.mode not in ("manual", "vad"):
        raise HTTPException(status_code=400, detail="mode must be 'manual' or 'vad'")

    session = await session_manager.get_or_create(body.ctxId)

    if session.interaction_mode == body.mode:
        return {"code": 0, "message": f"already in {body.mode} mode"}

    # 切换模式
    old_mode = session.interaction_mode
    session.interaction_mode = body.mode

    if body.mode == "vad" and old_mode == "manual":
        # Manual → VAD：创建持久 WS 会话
        from services.aliyun_omni import OmniVadSession
        from config import DASHSCOPE_API_KEY, OMNI_MODEL, OMNI_VOICE, OMNI_INSTRUCTIONS

        vad_session = OmniVadSession(
            api_key=DASHSCOPE_API_KEY,
            model=OMNI_MODEL,
            voice=OMNI_VOICE,
            instructions=OMNI_INSTRUCTIONS,
            event_bus=session.event_bus,
        )
        try:
            await vad_session.start()
            session.omni_vad_session = vad_session
            print(f"[upload] Switched to VAD mode for ctxId={body.ctxId}")
        except Exception as e:
            session.interaction_mode = old_mode
            print(f"[upload] Failed to start VAD session: {e}")
            raise HTTPException(status_code=500, detail=f"Failed to start VAD: {e}")

    elif body.mode == "manual" and old_mode == "vad":
        # VAD → Manual：关闭持久 WS 会话
        if session.omni_vad_session:
            await session.omni_vad_session.stop()
            session.omni_vad_session = None
        print(f"[upload] Switched to Manual mode for ctxId={body.ctxId}")

    session.touch()
    return {"code": 0, "message": f"switched to {body.mode} mode"}


@router.post("/audio_chunk")
async def upload_audio_chunk(body: AudioChunkBody):
    """
    接收Flutter上传的音频分片（base64 PCM）

    VAD 模式：实时转发到 Omni WS 长连接
    Manual 模式：缓存到 session 音频缓冲区
    """
    session = await session_manager.get_or_create(body.ctxId)

    if body.audio:
        if session.interaction_mode == "vad" and session.omni_vad_session:
            # VAD 模式：实时转发
            await session.omni_vad_session.send_audio(body.audio)
            print(f"[upload] VAD audio forwarded, len={len(body.audio)}")
        else:
            # Manual 模式：缓存
            session.audio_buffer.append(body.audio)
        session.touch()

    if body.end:
        session.turn_active = True
        session.touch()
        print(f"[upload] end=true, mode={session.interaction_mode}")

    return {"code": 0, "message": "ok"}


@router.post("/frame")
async def upload_frame(body: FrameBody):
    """
    接收Flutter上传的图像帧（base64 JPG）

    VAD 模式：实时转发到 Omni WS
    Manual 模式：存入缓冲区
    """
    session = await session_manager.get_or_create(body.ctxId)

    if session.interaction_mode == "vad" and session.omni_vad_session:
        await session.omni_vad_session.send_frame(body.frame)
    else:
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

    VAD 模式：服务端自动检测语音结束，无需手动触发
    Manual 模式（Omni）：一次性发送所有音频 → commit → response.create
    Manual 模式（分离）：VL+TTS 推理流水线
    """
    print(f"[upload] chat/end HIT ctx_id={body.ctxId}")
    session = await session_manager.get_or_create(body.ctxId)

    session.turn_active = True
    session.touch()

    # 关键修复：在推理任务启动**之前**同步设置 turn_start_id。
    # 作用：让"chat/end 之后才连上 SSE"的客户端也能从 turn_start_id 开始
    # 重放本轮所有事件（修复竞态：客户端先发 chat/end，后连 SSE）。
    # 这是一个简单的乐观赋值：即使 SSE 此时已连上，新事件从这里开始编号
    # 也比 _next_id 更靠前，能让已连的订阅者从本轮起点开始重放。
    # 注意：实际编号由 EventBus._next_id 决定，turn_start_id 只用于
    # 限制新订阅者的重放起点。
    session.turn_start_id = session.event_bus.next_id  # 当前 _next_id 是下一个 event_id

    # VAD 模式：服务端自动处理，不需要手动触发推理
    if session.interaction_mode == "vad":
        print(f"[upload] chat/end EARLY-RETURN vad_mode ctx_id={body.ctxId}")
        return {"code": 0, "message": "vad_mode_auto_handled"}

    # Manual 模式
    print(f"[upload] chat/end OMNI_MODE={OMNI_MODE} interaction_mode={session.interaction_mode} audio_buf_len={len(session.audio_buffer)} frame_buf_len={len(session.frame_buffer)}")
    if OMNI_MODE:
        print(f"[upload] _omni_inference ctx_id={body.ctxId} audio_chunks={len(session.audio_buffer)} has_frame={bool(session.frame_buffer)}")
        task = asyncio.create_task(_omni_inference(session, body.ctxId))
        def _on_done(t: asyncio.Task):
            try:
                t.result()
                print(f"[upload] _omni_inference TASK DONE OK ctx_id={body.ctxId}")
            except asyncio.CancelledError:
                print(f"[upload] _omni_inference TASK CANCELLED ctx_id={body.ctxId}")
            except Exception as e:
                print(f"[upload] _omni_inference TASK EXCEPTION ctx_id={body.ctxId}: {type(e).__name__}: {e}")
        task.add_done_callback(_on_done)
    else:
        print(f"[upload] trigger_session_inference ctx_id={body.ctxId}")
        asyncio.create_task(trigger_session_inference(session, body.ctxId))

    return {"code": 0, "message": "turn_ended"}


async def _omni_inference(session, ctx_id: str):
    """
    Omni Manual 模式推理：音频 + 图像帧 → Qwen-Omni-Realtime
    结果通过 session.event_bus.publish 推送 SSE 事件

    关键改进（基于 EventBus）：
    - 不再需要等待 SSE 连接就绪（sse_ready 已删除）
    - 事件直接 publish 到 EventBus；客户端是否在线不影响事件保存
    - 客户端断线重连后可通过 lastEventId 续传遗漏事件
    """
    from services.aliyun_omni import OmniService

    event_bus = session.event_bus

    try:
        print(f"[upload] _omni_inference TASK START ctx_id={ctx_id} audio_chunks={len(session.audio_buffer)} has_frame={bool(session.frame_buffer)}")
        omni = OmniService()
        print(f"[upload] _omni_inference OmniService constructed, is_configured={omni.is_configured}")
        if not omni.is_configured:
            await event_bus.publish({
                "event": "error",
                "data": json.dumps({"code": "omni_not_configured", "message": "OMNI_MODE enabled but DASHSCOPE_API_KEY not configured"}),
            })
            return

        audio_chunks = list(session.audio_buffer)
        frame_data = session.frame_buffer[-1] if session.frame_buffer else None
        frame_b64 = frame_data["frame"] if frame_data else None

        print(f"[upload] _omni_inference CALLING run_turn audio_chunks={len(audio_chunks)} has_frame={bool(frame_b64)}")
        result = await omni.run_turn(
            audio_chunks=audio_chunks,
            frame_b64=frame_b64,
            event_bus=event_bus,
        )
        print(f"[upload] _omni_inference run_turn RETURNED keys={list(result.keys()) if isinstance(result, dict) else type(result)}")
        print(f"[upload] _omni_inference RESULT full_text={result.get('full_text', '')!r} audio_seconds={result.get('audio_seconds', 0.0)} error={result.get('error')!r}")

        full_text = result.get("full_text", "")
        audio_seconds = result.get("audio_seconds", 0.0)

        # 保存上下文
        if full_text:
            session.add_message("user", session.transcribed_text or "（语音输入）")
            session.add_message("assistant", full_text)
        session.transcribed_text = ""
        session.touch()

        await event_bus.publish({
            "event": "end",
            "data": json.dumps({"full_text": full_text, "audio_seconds": audio_seconds}),
        })

    except asyncio.CancelledError:
        raise
    except Exception as e:
        print(f"[Omni] Manual inference error: {e}")
        try:
            await event_bus.publish({
                "event": "error",
                "data": json.dumps({"code": "omni_error", "message": str(e)}),
            })
        except Exception:
            pass
    finally:
        session.audio_buffer.clear()
        session.turn_active = False
        # 本轮结束：清零 turn_start_id，后续 SSE 订阅者不再重放本轮事件
        session.turn_start_id = 0
