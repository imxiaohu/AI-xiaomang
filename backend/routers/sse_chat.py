"""SSE路由：文本分片 + MP3音频分片 + Omni PCM音频 + 心跳推送"""
import asyncio
import json
import base64
from typing import AsyncGenerator
from fastapi import APIRouter, Query, HTTPException
from fastapi.responses import StreamingResponse
from sse_starlette.sse import EventSourceResponse
from config import SSE_HEARTBEAT_INTERVAL, DEBUG, DASHSCOPE_API_KEY, OMNI_MODE
from services.session_manager import session_manager
from services.aliyun_vl import AliyunVL
from services.aliyun_tts import AliyunTTS
from services.aliyun_asr import AliyunASR

from utils.cors import build_sse_headers, validate_session_params

router = APIRouter(prefix="/sse", tags=["sse"])


async def sse_event_stream(
    ctx_id: str,
    token: str,
    last_event_id: int = 0,
) -> AsyncGenerator[dict, None]:
    """
    SSE事件流生成器（基于 EventBus）

    事件类型（VL+TTS模式）：text / audio / end / heartbeat / error / quota_exceeded
    事件类型（Omni模式）：omni_audio / omni_speech_started / omni_speech_stopped / text / end / heartbeat / error

    Args:
        last_event_id: Last-Event-ID 续传起点（query 参数）。
                      0 表示从当前位置之后开始（新订阅者默认行为）。
                      >0 表示从该 event_id 之后开始重放。
    """
    is_valid, err_msg = validate_session_params(ctx_id, token)
    if not is_valid:
        yield {"event": "error", "data": json.dumps({"code": "invalid_params", "message": err_msg})}
        return

    session = await session_manager.get_or_create(ctx_id)
    if not session:
        yield {"event": "error", "data": json.dumps({"code": "invalid_session", "message": "会话不存在或已过期"})}
        return

    # 注册新订阅者到 EventBus
    # 关键修复：SSE 断开时不再取消推理任务 —— 推理继续完成，事件写入总线
    # 新连接通过 last_event_id 续传
    sid = session.register_sse_subscriber()
    if last_event_id > 0:
        # 续传：从 last_event_id 之后开始重放
        initial_last_id = last_event_id
    else:
        # 全新连接：从当前位置之后开始（新订阅者不重放过老历史）
        initial_last_id = session.event_bus.get_subscriber_position(sid)

    async def heartbeat():
        while True:
            await asyncio.sleep(SSE_HEARTBEAT_INTERVAL)
            try:
                await asyncio.wait_for(
                    session.event_bus.publish({"event": "heartbeat", "data": "ping"}),
                    timeout=1.0,
                )
            except asyncio.TimeoutError:
                pass

    heartbeat_task = asyncio.create_task(heartbeat())

    # Omni 模式：不在此处启动推理，等 upload/chat/end 触发
    # VL+TTS 模式：保留原行为（首次连接自动触发）
    inference_task: asyncio.Task | None = None
    if not OMNI_MODE:
        async def run_inference():
            await trigger_session_inference(session, ctx_id)

        inference_task = asyncio.create_task(run_inference())
        session.inference_task = inference_task

    try:
        # 从 EventBus 订阅事件流（自动支持 Last-Event-ID 重放）
        async for eid, event in session.event_bus.subscribe(sid, last_id=initial_last_id):
            # 事件 = {"event": "text", "data": "..."}
            # yield 时附加 id 字段，方便客户端记录 Last-Event-ID
            yield {"id": str(eid), "event": event["event"], "data": event["data"]}
            # 每 16 个事件 trim 一次（避免每个事件都 trim 加锁开销）
            if eid % 16 == 0:
                await session.event_bus.trim()
    except asyncio.CancelledError:
        # 关键修复：SSE 断开时不再取消推理任务
        # 让推理继续完成，把事件写入 EventBus
        # 新连接会通过 last_event_id 续传
        raise
    finally:
        heartbeat_task.cancel()
        session.unregister_sse_subscriber(sid)
        # 清理后做一次 trim（释放当前订阅者确认的事件）
        try:
            await session.event_bus.trim()
        except Exception:
            pass
        # 仅在 VL+TTS 模式下管理 inference_task
        if inference_task and not OMNI_MODE:
            # 不取消，让它自然完成（事件会进 EventBus）
            pass


def _split_sentences_for_sse(text: str) -> list[str]:
    """将文本拆分为适合SSE推送的片段（按句子或固定长度）"""
    import re
    sentences = re.split(r'(?<=[。！？.!?])', text)
    result = []
    current = ""
    for s in sentences:
        if len(current) + len(s) > 50:
            if current:
                result.append(current.strip())
            current = s
        else:
            current += s
    if current.strip():
        result.append(current.strip())
    return result if result else [text]


def _mock_vl_response(question: str) -> str:
    """开发模式Mock VL回答"""
    responses = [
        "我看到这是一个室内的场景，光线充足。",
        "根据画面分析，这似乎是一个现代化的空间。",
        "从视觉角度来看，画面中的内容非常清晰。",
        "我注意到画面中有一些有趣的元素，让我为你描述一下。",
    ]
    return responses[hash(question) % len(responses)]


def _mock_text_response(question: str) -> str:
    """开发模式Mock纯文本回答"""
    return f"我听到了你的问题：{question}。当前运行在开发模式，使用模拟回答。阿里云凭证配置完成后将启用真实AI推理。"


async def trigger_session_inference(session, ctx_id: str):
    """
    共享推理函数：被 SSE 事件流、/chat/infer、/upload/chat/end 调用。
    从 session 取出音频/帧/文本，执行 VL 流式推理 + TTS 流式合成，
    结果通过 session.event_bus.publish 推送（支持 Last-Event-ID 续传）。

    核心设计：
    - VL 通过 SSE 实时推送 token（用户看到打字机效果）
    - TTS 通过 input_text.append 实时合成音频（几乎同步播放）
    - 两者并行，音频紧跟文本
    - 事件写入 EventBus：SSE 断开不会丢失，新连接可续传
    """
    event_bus = session.event_bus

    if session.inference_task and not session.inference_task.done():
        session.inference_task.cancel()
        try:
            await session.inference_task
        except asyncio.CancelledError:
            pass

    # 同步设置 turn_start_id：让任何后续才连上的 SSE 订阅者从本轮开始重放
    # 修复"客户端先发 /chat/infer 或 /chat/end、后连 SSE"导致的竞态
    session.turn_start_id = event_bus.next_id

    full_text = ""
    total_audio_chunks = 0

    try:
        # ── 准备输入 ────────────────────────────────────────────
        vl = AliyunVL()
        tts = AliyunTTS()

        user_text = session.transcribed_text
        if not user_text and session.audio_buffer:
            user_text = await _do_backend_asr(session)
        if not user_text:
            user_text = "你好"

        frame_data = session.frame_buffer[-1] if session.frame_buffer else None
        context = session.get_context()

        # ── DEBUG 模式：Mock 非流式 ─────────────────────────────
        if DEBUG:
            full_text = _mock_vl_response(user_text)
            for sent in _split_sentences_for_sse(full_text):
                await event_bus.publish({
                    "event": "text",
                    "data": json.dumps({"text": sent, "is_final": False}),
                })
                await asyncio.sleep(0.05)
            total_audio_chunks = 0

        # ── 真实推理：VL 流式 + TTS 流式 ───────────────────────
        else:
            from services.aliyun_vl import build_streaming_messages

            tts_ctx = None
            try:
                # 启动 TTS 流式连接
                if tts.is_configured and tts.check_quota():
                    tts_ctx = await tts.synthesize_stream()

                round_count = session.round_count

                # 构建消息（含 cache_control 标记）
                if frame_data:
                    messages = build_streaming_messages(
                        context, user_text, frame_data["frame"], round_count
                    )
                else:
                    messages = build_streaming_messages(context, user_text, None, round_count)

                # 句子缓冲（攒到句末标点才 flush TTS）
                audio_chunk_count = 0

                async def on_tts_audio(mp3_b64: str):
                    nonlocal audio_chunk_count
                    audio_chunk_count += 1
                    await event_bus.publish({
                        "event": "audio",
                        "data": json.dumps({"audio": mp3_b64, "index": audio_chunk_count}),
                    })

                if tts_ctx is None:
                    async def noop_b64(_b: str): pass
                    on_audio = noop_b64
                else:
                    tts_ctx._on_audio = on_tts_audio
                    on_audio = on_tts_audio

                # ── VL token 主循环 ───────────────────────────────
                async for token in vl.chat_stream(messages):
                    full_text += token

                    # 实时推送文本给前端
                    await event_bus.publish({
                        "event": "text",
                        "data": json.dumps({"text": token, "is_final": False}),
                    })

                    # 实时追加到 TTS
                    if tts_ctx is not None:
                        await tts_ctx.append_text(token)

                    # 句子结束 → flush TTS
                    if token in "。！？.!?" and tts_ctx is not None:
                        await tts_ctx.flush()
                        await asyncio.sleep(0.05)

                # 最后一次 flush
                if tts_ctx is not None:
                    await tts_ctx.finish()
                    total_audio_chunks = audio_chunk_count

                session.add_message("user", user_text)
                session.add_message("assistant", full_text)
                session.transcribed_text = ""
                session.touch()

            except Exception as e:
                print(f"[SSE] Stream inference error: {e}")
                full_text = f"推理异常：{e}"
                if tts_ctx is not None:
                    await tts_ctx.close()

        # ── 推送结束事件 ───────────────────────────────────────
        await event_bus.publish({
            "event": "end",
            "data": json.dumps({"full_text": full_text, "total_audio_chunks": total_audio_chunks}),
        })

        session.audio_buffer.clear()
        session.turn_active = False

    except asyncio.CancelledError:
        raise
    except Exception as e:
        print(f"[SSE] Inference error: {e}")
        try:
            await event_bus.publish({
                "event": "error",
                "data": json.dumps({"code": "inference_error", "message": str(e)}),
            })
        except Exception:
            pass
    finally:
        # 本轮结束：清零 turn_start_id，后续 SSE 订阅者不再重放本轮事件
        session.turn_start_id = 0


async def _do_backend_asr(session) -> str:
    """
    若客户端未做 ASR（session.transcribed_text 为空），
    则从 session.audio_buffer 合并 PCM，调用阿里云 DashScope 实时 ASR 识别。
    """
    if not DASHSCOPE_API_KEY:
        return ""

    try:
        combined_pcm = b"".join(base64.b64decode(chunk) for chunk in session.audio_buffer)
        transcribed = ""

        asr = AliyunASR()

        async def on_final(text: str):
            nonlocal transcribed
            transcribed = text

        await asr.connect(on_final=on_final)
        await asr.send_audio(combined_pcm)
        await asyncio.sleep(6)
        await asr.close()

        return transcribed
    except Exception as e:
        print(f"[SSE] Backend ASR failed: {e}")
        return ""


@router.get("/chat")
async def sse_chat(
    ctxId: str = Query(..., description="会话ID"),
    token: str = Query(..., description="认证token"),
    lastEventId: int = Query(0, description="Last-Event-ID 续传起点；0 表示新连接"),
):
    """
    SSE下行流接口
    URL参数携带鉴权（避免SSE跨域自定义Header问题）
    SSE响应头必须设置：Content-Type: text/event-stream, Cache-Control: no-cache, X-Accel-Buffering: no
    """
    async def event_generator():
        async for event in sse_event_stream(ctxId, token, last_event_id=lastEventId):
            yield event

    return EventSourceResponse(
        event_generator(),
        headers=build_sse_headers(),
    )


@router.get("/mode")
async def get_mode(ctxId: str = Query(..., description="会话ID")):
    """查询当前 Omni 交互模式"""
    session = await session_manager.get(ctxId)
    if not session:
        return {"mode": "manual"}
    return {"mode": session.interaction_mode}


@router.post("/chat/infer")
async def trigger_inference(
    ctxId: str = Query(..., description="会话ID"),
    userText: str = Query(..., description="用户语音转写文本"),
):
    """
    手动触发推理（当客户端使用自有ASR时调用）
    从 session 取出最近帧和文本，触发VL+TTS推理并通过SSE推送
    """
    session = await session_manager.get(ctxId)
    if not session:
        raise HTTPException(status_code=404, detail="会话不存在")

    if session.inference_task and not session.inference_task.done():
        session.inference_task.cancel()

    session.transcribed_text = userText
    session.inference_task = asyncio.create_task(trigger_session_inference(session, ctxId))

    return {"code": 0, "message": "inference_triggered"}
