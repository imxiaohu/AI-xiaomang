"""Qwen-Omni-Realtime 服务 — WebSocket 代理 + SSE 事件推送"""
import asyncio
import json
import base64
import uuid
import websockets
import time
from config import DASHSCOPE_API_KEY, OMNI_MODEL, OMNI_VOICE, OMNI_INSTRUCTIONS

LOG_PATH = "/Users/xiaohu/Downloads/AIVideo/.cursor/debug-b10e1d.log"

def _debug_log(location: str, message: str, data: dict, hypothesis_id: str, run_id: str = "initial"):
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(json.dumps({
                "sessionId": "b10e1d",
                "runId": run_id,
                "hypothesisId": hypothesis_id,
                "location": location,
                "message": message,
                "data": data,
                "timestamp": int(time.time() * 1000),
            }, ensure_ascii=False) + "\n")
    except Exception:
        pass


class OmniService:
    """
    Qwen-Omni-Realtime 代理服务

    工作原理：
    1. 前端通过 SSE 保持长连接（与 VL+TTS 模式共用）
    2. 前端 HTTP POST 音频/帧到 /upload 端点
    3. upload 路由在 turn_active=True 时立即触发 Omni 推理
    4. Omni WebSocket 接收音频/帧，流式返回 PCM 音频 + 文本
    5. 通过 session.event_bus 发布到前端（支持 Last-Event-ID 续传）

    前端 SSE 事件（Omni 模式）：
      omni_speech_started  : 服务端检测到用户语音开始（VAD 模式）
      omni_speech_stopped : 服务端检测到用户语音结束（VAD 模式）
      omni_committed      : 服务端已接收并提交音频缓冲
      omni_audio         : 流式 PCM 音频（24kHz，base64）
      text               : 流式文本（用户转录 + 模型回复）
      end                : 推理结束，完整文本
      error              : 错误信息

    文档：https://bailian.console.aliyun.com/cn-beijing?spm=5176.12818093_47.overview_recent.1.1a8516d0gpGGGH&tab=doc#/doc/?type=model&url=3021987
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
        event_bus,  # EventBus（替代旧的 sse_queue）
        user_text: str | None = None,
    ) -> dict:
        """
        执行一轮 Omni 推理（音频+图像 → 流式 PCM 音频 + 文本）

        audio_chunks : 音频分片列表（每项为 base64 PCM 16kHz）
        frame_b64    : 当前帧 base64（可选）
        event_bus    : 事件总线（替代 sse_queue，支持 Last-Event-ID 续传）
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
                self.BASE_URL + f"?model={self._model}",
                additional_headers={"Authorization": f"Bearer {self._api_key}"},
                ping_interval=20,
            ) as ws:
                # ── 1. 配置会话（Manual 模式：客户端控制提交时机）──
                await ws.send(json.dumps({
                    "event_id": self._mk_event_id(),
                    "type": "session.update",
                    "session": {
                        "modalities": ["text", "audio"],
                        "voice": self._voice,
                        "input_audio_format": "pcm",
                        "output_audio_format": "pcm",
                        "instructions": self._instructions,
                        # Manual 模式：禁用服务端 VAD，由客户端显式 commit + create_response
                        # 适用于"按下即说"场景：一次性发送所有音频后提交
                        "turn_detection": None,
                        # 启用用户语音转录（用户说话时显示实时文字）
                        "input_audio_transcription": {
                            "model": "paraformer-zh",
                        },
                    },
                }))

                await self._wait_event(ws, "session.updated")

                # ── 2. 发送音频（Manual 模式：一次性发送所有音频分片）──
                for chunk_b64 in audio_chunks:
                    await ws.send(json.dumps({
                        "event_id": self._mk_event_id(),
                        "type": "input_audio_buffer.append",
                        "audio": chunk_b64,
                    }))

                # ── 3. 发送图像帧 ────────────────────────────────
                if frame_b64:
                    await ws.send(json.dumps({
                        "event_id": self._mk_event_id(),
                        "type": "input_image_buffer.append",
                        "image": frame_b64,
                    }))

                # ── 4. Manual 模式：显式提交音频缓冲 + 请求响应 ──
                # 文档：客户端必须在发送完数据后主动 commit，等待服务端确认后才能 create_response
                await ws.send(json.dumps({
                    "event_id": self._mk_event_id(),
                    "type": "input_audio_buffer.commit",
                }))

                # 等待服务端确认音频缓冲已提交（关键：不能跳过）
                try:
                    await self._wait_event(ws, "input_audio_buffer.committed")
                    print("[Omni] input_audio_buffer.committed received")
                except RuntimeError as e:
                    print(f"[Omni] commit confirm failed: {e}")
                    return {"full_text": "", "audio_seconds": 0.0, "error": str(e)}

                # 服务端确认后再请求模型生成响应
                await ws.send(json.dumps({
                    "event_id": self._mk_event_id(),
                    "type": "response.create",
                }))

                # ── 5. 接收响应事件流（带超时保护）──────────────────
                last_event_time = asyncio.get_running_loop().time()
                response_timeout = 60.0  # 最长等待 60 秒

                async for raw in ws:
                    if done.is_set():
                        break

                    now = asyncio.get_running_loop().time()
                    if now - last_event_time > response_timeout:
                        print(f"[Omni] Response timeout after {response_timeout}s, breaking")
                        break

                    if isinstance(raw, bytes):
                        continue

                    try:
                        msg = json.loads(raw)
                    except json.JSONDecodeError:
                        continue

                    last_event_time = asyncio.get_running_loop().time()
                    msg_type = msg.get("type", "")

                    # VAD 事件
                    if msg_type == "input_audio_buffer.speech_started":
                        await event_bus.publish({
                            "event": "omni_speech_started",
                            "data": json.dumps({}),
                        })

                    elif msg_type == "input_audio_buffer.speech_stopped":
                        await event_bus.publish({
                            "event": "omni_speech_stopped",
                            "data": json.dumps({}),
                        })

                    elif msg_type == "input_audio_buffer.committed":
                        # 服务端已接收并提交音频，开始生成响应
                        await event_bus.publish({
                            "event": "omni_committed",
                            "data": json.dumps({}),
                        })

                    # 用户语音实时转录（Omni 端到端转录）
                    # API: text=已确认前缀, stash=草稿后缀, 实时预览=text+stash
                    elif msg_type == "conversation.item.input_audio_transcription.delta":
                        text_part = msg.get("text", "") or ""
                        stash_part = msg.get("stash", "") or ""
                        display_text = text_part + stash_part
                        if display_text:
                            await event_bus.publish({
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
                                audio_chunk_count += 1
                                raw_len = (len(delta) * 3) >> 2
                                audio_seconds += raw_len / (24000 * 2)
                                await event_bus.publish({
                                    "event": "omni_audio",
                                    "data": json.dumps({"audio": delta, "index": audio_chunk_count}),
                                })
                            except Exception:
                                pass

                    # 模型流式文本（回复内容）
                    elif msg_type == "response.audio_transcript.delta":
                        delta = msg.get("delta", "") or ""
                        if delta:
                            model_transcript_parts.append(delta)
                            full_text = "".join(model_transcript_parts)
                            await event_bus.publish({
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
                        await event_bus.publish({
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
                    await event_bus.publish({
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
        """等待特定类型的 Omni 事件，超时或收到 error 则抛异常"""
        loop = asyncio.get_running_loop()
        end_time = loop.time() + timeout
        async for raw in ws:
            if isinstance(raw, bytes):
                continue
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if msg.get("type") == event_type:
                return msg
            if msg.get("type") == "error":
                err_msg = msg.get("error", {}).get("message", str(msg))
                raise RuntimeError(f"Omni server error during {event_type}: {err_msg}")
            if loop.time() > end_time:
                break
        raise RuntimeError(f"Omni timeout waiting for {event_type} ({timeout}s)")


class OmniVadSession:
    """
    VAD 模式持久会话：维护与 Omni Realtime 的长连接。
    前端实时发送音频分片，服务端自动检测语音起止并生成响应。

    生命周期：start() → (send_audio/send_frame 循环) → stop()
    """

    def __init__(
        self,
        api_key: str,
        model: str,
        voice: str,
        instructions: str,
        event_bus,  # EventBus（替代旧的 sse_queue）
    ):
        self._api_key = api_key
        self._model = model
        self._voice = voice
        self._instructions = instructions
        self._event_bus = event_bus
        self._ws = None
        self._recv_task = None
        self._started = False
        self._closed = False

    async def start(self):
        """建立 WS 连接，发送 session.update（VAD 模式），启动接收循环"""
        if self._started:
            return

        url = f"wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model={self._model}"
        headers = {"Authorization": f"Bearer {self._api_key}"}

        self._ws = await websockets.connect(url, additional_headers=headers, ping_interval=20)
        self._started = True
        self._closed = False

        # 配置 VAD 模式
        await self._ws.send(json.dumps({
            "event_id": f"evt_{uuid.uuid4().hex[:16]}",
            "type": "session.update",
            "session": {
                "modalities": ["text", "audio"],
                "voice": self._voice,
                "input_audio_format": "pcm",
                "output_audio_format": "pcm",
                "instructions": self._instructions,
                "turn_detection": {
                    "type": "semantic_vad",
                    "threshold": 0.5,
                    "silence_duration_ms": 800,
                },
                "input_audio_transcription": {
                    "model": "paraformer-zh",
                },
            },
        }))

        # 等待 session.updated
        try:
            await asyncio.wait_for(self._wait_for("session.updated"), timeout=10.0)
        except (asyncio.TimeoutError, RuntimeError) as e:
            print(f"[OmniVad] Failed to start session: {e}")
            await self.stop()
            raise

        # 启动接收循环
        self._recv_task = asyncio.create_task(self._recv_loop())
        print("[OmniVad] Session started, VAD active")

    async def send_audio(self, chunk_b64: str):
        """实时转发音频分片到 Omni WS"""
        if not self._started or self._closed or self._ws is None:
            print(f"[OmniVad] send_audio SKIPPED: started={self._started} closed={self._closed} ws={self._ws is not None}")
            return
        try:
            await self._ws.send(json.dumps({
                "event_id": f"evt_{uuid.uuid4().hex[:16]}",
                "type": "input_audio_buffer.append",
                "audio": chunk_b64,
            }))
        except Exception as e:
            print(f"[OmniVad] send_audio error: {e}")

    async def send_frame(self, frame_b64: str):
        """转发图像帧到 Omni WS"""
        if not self._started or self._closed or self._ws is None:
            return
        try:
            await self._ws.send(json.dumps({
                "event_id": f"evt_{uuid.uuid4().hex[:16]}",
                "type": "input_image_buffer.append",
                "image": frame_b64,
            }))
        except Exception as e:
            print(f"[OmniVad] send_frame error: {e}")

    async def stop(self):
        """关闭 WS 连接"""
        self._closed = True
        if self._recv_task:
            self._recv_task.cancel()
            self._recv_task = None
        if self._ws:
            try:
                await self._ws.close()
            except Exception:
                pass
            self._ws = None
        self._started = False
        print("[OmniVad] Session stopped")

    async def _recv_loop(self):
        """持续接收服务端事件，发布到 event_bus"""
        full_text = ""
        audio_seconds = 0.0
        audio_chunk_count = 0
        user_transcript_parts = []
        model_transcript_parts = []

        try:
            async for raw in self._ws:
                if self._closed:
                    break
                if isinstance(raw, bytes):
                    continue
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    continue

                msg_type = msg.get("type", "")

                if msg_type == "input_audio_buffer.speech_started":
                    print("[OmniVad] >>> speech_started")
                    await self._event_bus.publish({
                        "event": "omni_speech_started",
                        "data": json.dumps({}),
                    })

                elif msg_type == "input_audio_buffer.speech_stopped":
                    print("[OmniVad] >>> speech_stopped")
                    await self._event_bus.publish({
                        "event": "omni_speech_stopped",
                        "data": json.dumps({}),
                    })

                elif msg_type == "input_audio_buffer.committed":
                    print("[OmniVad] >>> committed")
                    await self._event_bus.publish({
                        "event": "omni_committed",
                        "data": json.dumps({}),
                    })
                    # 新一轮开始，重置状态
                    full_text = ""
                    audio_seconds = 0.0
                    audio_chunk_count = 0
                    user_transcript_parts = []
                    model_transcript_parts = []

                elif msg_type == "conversation.item.input_audio_transcription.delta":
                    text_part = msg.get("text", "") or ""
                    stash_part = msg.get("stash", "") or ""
                    display_text = text_part + stash_part
                    if display_text:
                        await self._event_bus.publish({
                            "event": "text",
                            "data": json.dumps({"text": display_text, "is_final": False, "source": "user"}),
                        })

                elif msg_type == "conversation.item.input_audio_transcription.completed":
                    transcript = msg.get("transcript", "") or ""
                    print(f"[OmniVad] >>> user transcript: {transcript}")
                    if transcript and not user_transcript_parts:
                        user_transcript_parts.append(transcript)

                elif msg_type == "response.audio.delta":
                    delta = msg.get("delta", "")
                    if delta:
                        try:
                            audio_chunk_count += 1
                            chunk_bytes_len = len(delta) * 3 // 4
                            audio_seconds += chunk_bytes_len / (24000 * 2)
                            await self._event_bus.publish({
                                "event": "omni_audio",
                                "data": json.dumps({"audio": delta, "index": audio_chunk_count}),
                            })
                        except Exception:
                            pass

                elif msg_type == "response.audio_transcript.delta":
                    delta = msg.get("delta", "") or ""
                    if delta:
                        model_transcript_parts.append(delta)
                        full_text = "".join(model_transcript_parts)
                        await self._event_bus.publish({
                            "event": "text",
                            "data": json.dumps({"text": delta, "is_final": False, "source": "assistant"}),
                        })

                elif msg_type == "response.audio.done":
                    transcript = msg.get("transcript", "") or ""
                    if transcript:
                        model_transcript_parts = [transcript]
                        full_text = transcript

                elif msg_type == "response.done":
                    if not full_text and user_transcript_parts:
                        full_text = "".join(user_transcript_parts)
                    print(f"[OmniVad] >>> response.done, full_text={full_text!r}")
                    await self._event_bus.publish({
                        "event": "end",
                        "data": json.dumps({"full_text": full_text, "audio_seconds": audio_seconds}),
                    })

                elif msg_type == "error":
                    print(f"[OmniVad] Server error: {msg}")
                    await self._event_bus.publish({
                        "event": "error",
                        "data": json.dumps({
                            "code": msg.get("error", {}).get("code", "omni_vad_error"),
                            "message": msg.get("error", {}).get("message", str(msg)),
                        }),
                    })

        except websockets.ConnectionClosed as e:
            print(f"[OmniVad] Connection closed: code={e.code} reason={e.reason}")
        except asyncio.CancelledError:
            pass
        except Exception as e:
            print(f"[OmniVad] Recv loop error: {e}")

    async def _wait_for(self, event_type: str, timeout: float = 10.0):
        """等待特定事件"""
        loop = asyncio.get_running_loop()
        end_time = loop.time() + timeout
        async for raw in self._ws:
            if isinstance(raw, bytes):
                continue
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if msg.get("type") == event_type:
                return msg
            if msg.get("type") == "error":
                err_msg = msg.get("error", {}).get("message", str(msg))
                raise RuntimeError(f"Omni server error: {err_msg}")
            if loop.time() > end_time:
                break
        raise RuntimeError(f"Omni timeout waiting for {event_type}")
