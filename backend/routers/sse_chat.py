"""SSE路由：文本分片 + MP3音频分片 + 心跳推送"""
import asyncio
import json
import base64
from typing import AsyncGenerator
from fastapi import APIRouter, Query, HTTPException
from fastapi.responses import StreamingResponse
from sse_starlette.sse import EventSourceResponse
from config import SSE_HEARTBEAT_INTERVAL, DEBUG, DASHSCOPE_API_KEY
from services.session_manager import session_manager
from services.aliyun_vl import AliyunVL
from services.aliyun_tts import AliyunTTS
from services.aliyun_asr import AliyunASR

from utils.cors import build_sse_headers, validate_session_params

router = APIRouter(prefix="/sse", tags=["sse"])


async def sse_event_stream(ctx_id: str, token: str) -> AsyncGenerator[dict, None]:
    """
    SSE事件流生成器
    事件类型：text / audio / end / heartbeat / error / quota_exceeded
    """
    is_valid, err_msg = validate_session_params(ctx_id, token)
    if not is_valid:
        yield {"event": "error", "data": json.dumps({"code": "invalid_params", "message": err_msg})}
        return

    session = await session_manager.get_or_create(ctx_id)
    if not session:
        yield {"event": "error", "data": json.dumps({"code": "invalid_session", "message": "会话不存在或已过期"})}
        return

    sse_queue: asyncio.Queue[dict] = asyncio.Queue()

    async def heartbeat():
        while True:
            await asyncio.sleep(SSE_HEARTBEAT_INTERVAL)
            try:
                await asyncio.wait_for(sse_queue.put({"event": "heartbeat", "data": "ping"}), timeout=1.0)
            except asyncio.TimeoutError:
                pass

    heartbeat_task = asyncio.create_task(heartbeat())

    async def run_inference():
        await trigger_session_inference(session, ctx_id)

    inference_task = asyncio.create_task(run_inference())
    session.sse_queue = sse_queue
    session.inference_task = inference_task

    try:
        while True:
            event = await sse_queue.get()
            yield event
    except asyncio.CancelledError:
        inference_task.cancel()
        raise
    finally:
        heartbeat_task.cancel()
        try:
            await inference_task
        except asyncio.CancelledError:
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
    从 session 取出音频/帧/文本，执行 VL 流式推理 + TTS 流式合成，结果写入 session.sse_queue。

    核心设计：
    - VL 通过 SSE 实时推送 token（用户看到打字机效果）
    - TTS 通过 input_text.append 实时合成音频（几乎同步播放）
    - 两者并行，音频紧跟文本
    """
    sse_queue = session.sse_queue
    if sse_queue is None:
        sse_queue = asyncio.Queue()
        session.sse_queue = sse_queue

    if session.inference_task and not session.inference_task.done():
        session.inference_task.cancel()
        try:
            await session.inference_task
        except asyncio.CancelledError:
            pass

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
                await sse_queue.put({
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
                    await sse_queue.put({
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
                    await sse_queue.put({
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
        await sse_queue.put({
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
            await sse_queue.put({
                "event": "error",
                "data": json.dumps({"code": "inference_error", "message": str(e)}),
            })
        except Exception:
            pass


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
        headers=build_sse_headers(),
    )


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
