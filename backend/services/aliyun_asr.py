"""阿里云实时语音识别（DashScope Fun-ASR / Qwen-ASR WebSocket 流式）"""
import asyncio
import json
import base64
import websockets
from typing import Callable, Awaitable
from config import DASHSCOPE_API_KEY, ALIYUN_REGION


class AliyunASR:
    """
    阿里云实时语音识别 — DashScope WebSocket 流式接口

    认证：DASHSCOPE_API_KEY（百炼平台 API Key）
    模型：fun-asr-realtime（Fun-ASR，支持多方言、时间戳）
          qwen3-asr-flash-realtime（Qwen-ASR，支持 VAD 断句、情绪识别）
    协议：wss://dashscope.aliyuncs.com/api-ws/v1/realtime

    Qwen-ASR VAD 模式（默认）：
      - 服务端自动检测语音起点/终点（断句），适合实时对话
      - 通过 session.update 的 turn_detection 参数控制灵敏度
    Manual 模式：
      - 客户端控制断句，通过 input_audio_buffer.commit 触发

    文档：https://help.aliyun.com/zh/model-studio/asr-model/
    """

    def __init__(self):
        self._api_key = DASHSCOPE_API_KEY
        self._region = ALIYUN_REGION
        self._ws = None
        self._task: asyncio.Task | None = None
        self._connected = False
        self._text_callback: Callable[[str], Awaitable[None]] | None = None
        self._final_callback: Callable[[str], Awaitable[None]] | None = None

    @property
    def is_configured(self) -> bool:
        return bool(self._api_key)

    async def connect(
        self,
        on_interim: Callable[[str], Awaitable[None]] | None = None,
        on_final: Callable[[str], Awaitable[None]] | None = None,
    ):
        """
        建立 WebSocket 连接，开始实时识别。
        on_interim: 中间结果回调（实时打字）
        on_final:   最终结果回调（句子结束）
        """
        if not self.is_configured:
            raise RuntimeError("DASHSCOPE_API_KEY not configured")

        self._text_callback = on_interim
        self._final_callback = on_final

        url = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
        headers = {"Authorization": f"Bearer {self._api_key}"}

        try:
            self._ws = await websockets.connect(url, additional_headers=headers, ping_interval=30)
            self._connected = True
            self._task = asyncio.create_task(self._recv_loop())
            # 发送会话参数
            await self._send_session_update()
        except Exception as e:
            print(f"[AliyunASR] Connection failed: {e}")
            self._connected = False

    async def _send_session_update(self):
        """发送会话参数配置（Qwen-ASR VAD 模式）"""
        msg = {
            "type": "session.update",
            "session": {
                "model": "qwen3-asr-flash-realtime",
                "audio": {
                    "format": "pcm",
                    "sample_rate": 16000,
                    "channels": 1,
                },
                # VAD 模式：自动断句，silence_duration_ms 控制断句延迟（ms）
                # 400ms = 快速断句，适合对话；800ms = 默认
                "turn_detection": {
                    "type": "semantic",
                    "threshold": 0.2,
                    "silence_duration_ms": 400,
                },
            },
        }
        await self._ws.send(json.dumps(msg))

    async def send_audio(self, pcm_bytes: bytes):
        """发送 PCM 音频分片（二进制）"""
        if not self._connected or self._ws is None:
            return
        try:
            await self._ws.send(pcm_bytes)
        except Exception as e:
            print(f"[AliyunASR] Send audio failed: {e}")

    async def send_audio_base64(self, pcm_base64: str):
        """发送 base64 编码的 PCM 音频"""
        audio_bytes = base64.b64decode(pcm_base64)
        await self.send_audio(audio_bytes)

    async def commit(self):
        """
        Manual 模式：客户端主动提交当前音频缓冲区，请求识别结果。
        VAD 模式下通常不需要调用。
        """
        if not self._connected or self._ws is None:
            return
        msg = {"type": "input_audio_buffer.commit"}
        await self._ws.send(json.dumps(msg))

    async def _recv_loop(self):
        """接收识别结果循环"""
        if self._ws is None:
            return
        try:
            async for raw in self._ws:
                if isinstance(raw, bytes):
                    # DashScope 实时 ASR 以二进制传输音频确认，跳过
                    continue

                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    continue

                msg_type = msg.get("type", "")

                # ── 实时中间结果（Qwen-ASR VAD 模式逐字返回）──────────
                if msg_type == "conversation.item.input_audio_transcription.text":
                    text = msg.get("text", "")
                    if text and self._text_callback:
                        await self._text_callback(text)

                # ── 句子结束，最终结果（sentence_end=true）────────────
                elif msg_type == "conversation.item.input_audio_transcription.completed":
                    text = msg.get("text", "")
                    if text and self._final_callback:
                        await self._final_callback(text)

                # ── Fun-ASR / Paraformer 格式 ────────────────────────
                elif msg_type == "content":
                    payload = msg.get("payload", {})
                    sentence = payload.get("output", {}).get("sentence", {})
                    text = sentence.get("text", "")
                    sentence_end = sentence.get("sentence_end", False)
                    if text:
                        if sentence_end and self._final_callback:
                            await self._final_callback(text)
                        elif self._text_callback:
                            await self._text_callback(text)

                # ── 会话就绪确认 ───────────────────────────────────
                elif msg_type == "session.started":
                    print("[AliyunASR] Session started")

                # ── 错误处理 ───────────────────────────────────────
                elif msg_type == "error":
                    print(f"[AliyunASR] Error: {msg}")

        except websockets.ConnectionClosed:
            print("[AliyunASR] Connection closed")
        except Exception as e:
            print(f"[AliyunASR] Recv loop error: {e}")
        finally:
            self._connected = False

    async def close(self):
        """关闭连接"""
        self._connected = False
        if self._task:
            self._task.cancel()
            self._task = None
        if self._ws:
            try:
                # 发送停止信号
                await self._ws.send(json.dumps({"type": "session.finish"}))
                await self._ws.close()
            except Exception:
                pass
            self._ws = None
