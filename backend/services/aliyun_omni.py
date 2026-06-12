"""Qwen-Omni-Realtime 服务 — WebSocket 代理 + SSE 事件推送"""
import asyncio
import json
import base64
import websockets
from typing import Callable, Awaitable
from config import DASHSCOPE_API_KEY, OMNI_MODEL, OMNI_VOICE, OMNI_INSTRUCTIONS


class OmniService:
    """
    Qwen-Omni-Realtime 代理服务

    工作原理：
    1. 前端通过 SSE 保持长连接（与 VL+TTS 模式共用）
    2. 前端 HTTP POST 音频/帧到 /upload 端点
    3. upload 路由在 turn_active=True 时立即触发 Omni 推理
    4. Omni WebSocket 接收音频/帧，流式返回 PCM 音频 + 文本
    5. 通过 session.sse_queue 推送回前端

    Omni vs VL+TTS：
    - Omni：一体化模型，端到端语音交互，更智能，支持联网搜索/Function Calling
    - VL+TTS：分离模型，文本+语音分开，需额外 TTS 费用

    前端 SSE 事件（Omni 模式）：
    - omni_audio: 流式 PCM 音频（24kHz，base64编码）
    - omni_speech_started: 检测到语音开始
    - omni_speech_stopped: 检测到语音结束
    - text: 流式文本（转录或回复）
    - end: 推理结束
    - error: 错误

    文档：https://help.aliyun.com/zh/model-studio/realtime-omni
    """

    BASE_URL = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"

    def __init__(self):
        self._api_key = DASHSCOPE_API_KEY
        self._model = OMNI_MODEL
        self._voice = OMNI_VOICE
        self._instructions = OMNI_INSTRUCTIONS

    @property
    def is_configured(self) -> bool:
        return bool(self._api_key)

    async def run_turn(
        self,
        audio_chunks: list[str],
        frame_b64: str | None,
        sse_queue: asyncio.Queue,
        user_text: str | None = None,
    ) -> dict:
        """
        执行一轮 Omni 推理（音频+图像 → 流式 PCM 音频 + 文本）

        audio_chunks: 音频分片列表（每项为 base64 PCM）
        frame_b64: 当前帧 base64（可选）
        sse_queue: SSE 事件队列
        user_text: 用户 ASR 转写文本（用于显示）

        Returns: {"full_text": str, "audio_seconds": float}
        """
        if not self.is_configured:
            return {"error": "DASHSCOPE_API_KEY not configured"}

        audio_bytes = b""
        for chunk_b64 in audio_chunks:
            try:
                audio_bytes += base64.b64decode(chunk_b64)
            except Exception:
                continue

        full_text = user_text or ""
        transcript_parts: list[str] = []
        audio_seconds = 0.0
        audio_chunk_count = 0
        running = True

        async def pump_audio():
            nonlocal audio_bytes, audio_seconds, audio_chunk_count
            chunk_size = 4800  # 24kHz, 16bit mono, 100ms = 4800 bytes
            while running and audio_bytes:
                chunk = audio_bytes[:chunk_size]
                audio_bytes = audio_bytes[chunk_size:]
                if chunk:
                    b64 = base64.b64encode(chunk).decode()
                    audio_chunk_count += 1
                    await sse_queue.put({
                        "event": "omni_audio",
                        "data": json.dumps({"audio": b64, "index": audio_chunk_count}),
                    })
                    audio_seconds += 0.1
                await asyncio.sleep(0.095)

        try:
            async with websockets.connect(
                self.BASE_URL,
                extra_headers={"Authorization": f"Bearer {self._api_key}"},
                ping_interval=20,
            ) as ws:
                await ws.send(json.dumps({
                    "type": "session.update",
                    "session": {
                        "model": self._model,
                        "modalities": ["text", "audio"],
                        "voice": self._voice,
                        "input_audio_format": "pcm",
                        "output_audio_format": "pcm",
                        "instructions": self._instructions,
                        "turn_detection": None,
                    },
                }))

                await self._wait_event(ws, "session.updated")

                pump_task = asyncio.create_task(pump_audio())

                for chunk_b64 in audio_chunks:
                    try:
                        await ws.send(json.dumps({
                            "type": "input_audio_buffer.append",
                            "audio": chunk_b64,
                        }))
                    except websockets.ConnectionClosed:
                        break
                    await asyncio.sleep(0.01)

                await ws.send(json.dumps({"type": "input_audio_buffer.commit"}))

                if frame_b64:
                    try:
                        await ws.send(json.dumps({
                            "type": "input_image_buffer.append",
                            "image": frame_b64,
                        }))
                    except websockets.ConnectionClosed:
                        pass

                async for raw in ws:
                    if not running:
                        break
                    if isinstance(raw, bytes):
                        continue
                    try:
                        msg = json.loads(raw)
                    except json.JSONDecodeError:
                        continue

                    msg_type = msg.get("type", "")

                    if msg_type == "input_audio_buffer.speech_started":
                        await sse_queue.put({
                            "event": "omni_speech_started",
                            "data": json.dumps({}),
                        })

                    elif msg_type == "input_audio_buffer.speech_stopped":
                        await sse_queue.put({
                            "event": "omni_speech_stopped",
                            "data": json.dumps({}),
                        })

                    elif msg_type == "response.audio.delta":
                        delta = msg.get("delta", "")
                        if delta:
                            try:
                                chunk_bytes = base64.b64decode(delta)
                                chunk_b64 = base64.b64encode(chunk_bytes).decode()
                                audio_chunk_count += 1
                                audio_seconds += len(chunk_bytes) / (24000 * 2)
                                await sse_queue.put({
                                    "event": "omni_audio",
                                    "data": json.dumps({"audio": chunk_b64, "index": audio_chunk_count}),
                                })
                            except Exception:
                                pass

                    elif msg_type == "response.audio_transcript.delta":
                        delta = msg.get("delta", "")
                        if delta:
                            transcript_parts.append(delta)
                            full_text += delta
                            await sse_queue.put({
                                "event": "text",
                                "data": json.dumps({"text": delta, "is_final": False}),
                            })

                    elif msg_type in ("response.audio.done", "response.done"):
                        running = False
                        break

                    elif msg_type == "error":
                        running = False
                        print(f"[Omni] Error: {msg}")
                        await sse_queue.put({
                            "event": "error",
                            "data": json.dumps({"code": "omni_error", "message": str(msg)}),
                        })
                        break

                running = False
                pump_task.cancel()

        except websockets.ConnectionClosed as e:
            print(f"[Omni] Connection closed: {e}")
            running = False
        except Exception as e:
            print(f"[Omni] Error: {e}")
            running = False
            await sse_queue.put({
                "event": "error",
                "data": json.dumps({"code": "omni_error", "message": str(e)}),
            })

        return {
            "full_text": full_text,
            "audio_seconds": audio_seconds,
        }

    async def _wait_event(self, ws, event_type: str, timeout: float = 10.0):
        """等待特定类型的 Omni 事件"""
        loop = asyncio.get_event_loop()
        end_time = loop.time() + timeout
        async for raw in ws:
            if isinstance(raw, bytes):
                continue
            try:
                msg = json.loads(raw)
                if msg.get("type") == event_type:
                    return msg
            except json.JSONDecodeError:
                pass
            if loop.time() > end_time:
                break
        return None
