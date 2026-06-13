"""Qwen-Omni-Realtime 服务 — WebSocket 代理 + SSE 事件推送"""
import asyncio
import json
import base64
import uuid
import websockets
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

    前端 SSE 事件（Omni 模式）：
      omni_speech_started  : 服务端检测到用户语音开始（VAD 模式）
      omni_speech_stopped : 服务端检测到用户语音结束（VAD 模式）
      omni_committed      : 服务端已接收并提交音频缓冲
      omni_audio         : 流式 PCM 音频（24kHz，base64）
      text               : 流式文本（用户转录 + 模型回复）
      end                : 推理结束，完整文本
      error              : 错误信息

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

    def _mk_event_id(self) -> str:
        return f"evt_{uuid.uuid4().hex[:16]}"

    async def run_turn(
        self,
        audio_chunks: list[str],
        frame_b64: str | None,
        sse_queue: asyncio.Queue,
        user_text: str | None = None,
    ) -> dict:
        """
        执行一轮 Omni 推理（音频+图像 → 流式 PCM 音频 + 文本）

        audio_chunks : 音频分片列表（每项为 base64 PCM 16kHz）
        frame_b64    : 当前帧 base64（可选）
        sse_queue    : SSE 事件队列
        user_text    : 用户 ASR 转写文本（Omni 模式下一般由 Omni 自行转录）

        Returns: {"full_text": str, "audio_seconds": float, "error": str|None}
        """
        if not self.is_configured:
            return {"error": "DASHSCOPE_API_KEY not configured", "full_text": "", "audio_seconds": 0.0}

        full_text = ""
        audio_seconds = 0.0
        audio_chunk_count = 0
        user_transcript_parts: list[str] = []
        model_transcript_parts: list[str] = []
        done = asyncio.Event()

        try:
            async with websockets.connect(
                self.BASE_URL,
                additional_headers={"Authorization": f"Bearer {self._api_key}"},
                ping_interval=20,
            ) as ws:
                # ── 1. 配置会话 ───────────────────────────────────
                await ws.send(json.dumps({
                    "event_id": self._mk_event_id(),
                    "type": "session.update",
                    "session": {
                        "modalities": ["text", "audio"],
                        "voice": self._voice,
                        "input_audio_format": "pcm",
                        "output_audio_format": "pcm",
                        "instructions": self._instructions,
                        # 启用服务端 VAD（自动检测语音起止）
                        "turn_detection": {
                            "type": "semantic_vad",
                            "threshold": 0.5,
                            "silence_duration_ms": 800,
                        },
                        # 启用用户语音转录（用户说话时显示实时文字）
                        "input_audio_transcription": {
                            "model": "paraformer-zh",
                        },
                    },
                }))

                await self._wait_event(ws, "session.updated")

                # ── 2. 发送音频（VAD 模式：服务端自动检测并提交）──
                for chunk_b64 in audio_chunks:
                    await ws.send(json.dumps({
                        "event_id": self._mk_event_id(),
                        "type": "input_audio_buffer.append",
                        "audio": chunk_b64,
                    }))
                    # 略作延迟，避免发送过快
                    await asyncio.sleep(0.01)

                # ── 3. 发送图像帧 ────────────────────────────────
                if frame_b64:
                    await ws.send(json.dumps({
                        "event_id": self._mk_event_id(),
                        "type": "input_image_buffer.append",
                        "image": frame_b64,
                    }))

                # ── 4. 接收响应事件流 ─────────────────────────────
                async for raw in ws:
                    if done.is_set():
                        break

                    if isinstance(raw, bytes):
                        continue

                    try:
                        msg = json.loads(raw)
                    except json.JSONDecodeError:
                        continue

                    msg_type = msg.get("type", "")

                    # VAD 事件
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

                    elif msg_type == "input_audio_buffer.committed":
                        # 服务端已接收并提交音频，开始生成响应
                        await sse_queue.put({
                            "event": "omni_committed",
                            "data": json.dumps({}),
                        })

                    # 用户语音实时转录（Omni 端到端转录）
                    elif msg_type == "conversation.item.input_audio_transcription.delta":
                        delta = msg.get("delta", "") or ""
                        stash = msg.get("stash", "") or ""
                        if delta or stash:
                            user_transcript_parts.append(delta + stash)
                            display_text = "".join(user_transcript_parts)
                            await sse_queue.put({
                                "event": "text",
                                "data": json.dumps({"text": display_text, "is_final": False, "source": "user"}),
                            })

                    elif msg_type == "conversation.item.input_audio_transcription.completed":
                        # 转录完成，最终用户文本
                        transcript = msg.get("transcript", "") or ""
                        if transcript and not user_transcript_parts:
                            user_transcript_parts.append(transcript)
                        full_text = transcript or user_text or ""

                    # 模型流式音频（直接播放）
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

                    # 模型流式文本（回复内容）
                    elif msg_type == "response.audio_transcript.delta":
                        delta = msg.get("delta", "") or ""
                        if delta:
                            model_transcript_parts.append(delta)
                            full_text = "".join(model_transcript_parts)
                            await sse_queue.put({
                                "event": "text",
                                "data": json.dumps({"text": delta, "is_final": False, "source": "assistant"}),
                            })

                    # 音频输出完成
                    elif msg_type == "response.audio.done":
                        # 模型回复内容确定
                        transcript = msg.get("transcript", "") or ""
                        if transcript:
                            model_transcript_parts = [transcript]
                            full_text = transcript

                    # 整个响应完成
                    elif msg_type == "response.done":
                        done.set()
                        break

                    # 错误
                    elif msg_type == "error":
                        print(f"[Omni] Server error: {msg}")
                        await sse_queue.put({
                            "event": "error",
                            "data": json.dumps({
                                "code": msg.get("error", {}).get("code", "omni_error"),
                                "message": msg.get("error", {}).get("message", str(msg)),
                            }),
                        })
                        done.set()
                        break

        except websockets.ConnectionClosed as e:
            print(f"[Omni] Connection closed: code={e.code} reason={e.reason}")
        except Exception as e:
            print(f"[Omni] Error: {e}")
            if not done.is_set():
                try:
                    await sse_queue.put({
                        "event": "error",
                        "data": json.dumps({"code": "omni_error", "message": str(e)}),
                    })
                except Exception:
                    pass

        # 防止残留文本（如只有 user 转录无模型回复）
        if not full_text and user_transcript_parts:
            full_text = "".join(user_transcript_parts)

        return {
            "full_text": full_text,
            "audio_seconds": audio_seconds,
            "error": None,
        }

    async def _wait_event(self, ws, event_type: str, timeout: float = 10.0):
        """等待特定类型的 Omni 事件"""
        loop = asyncio.get_running_loop()
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
