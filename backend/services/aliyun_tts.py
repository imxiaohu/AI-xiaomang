"""阿里云实时语音合成（DashScope CosyVoice / Qwen-TTS WebSocket 流式）"""
import asyncio
import json
import base64
import websockets
from typing import Callable
from config import DASHSCOPE_API_KEY, DAILY_TTS_QUOTA


# 每日已使用额度（简单内存计数，生产环境应持久化到 Redis/数据库）
_daily_tts_usage = 0.0


class AliyunTTS:
    """
    阿里云实时语音合成 — DashScope WebSocket 流式接口

    认证：DASHSCOPE_API_KEY（百炼平台 API Key）
    模型：cosyvoice-v3-flash（推荐，CosyVoice v3 最新版）
          qwen3-tts-flash-realtime（Qwen-TTS）
    协议：wss://dashscope.aliyuncs.com/api-ws/v1/inference
          （与实时 ASR 同一端点，共用连接）

    server_commit 模式：服务端自动处理文本分段与合成时机（适合大段文本）
    commit 模式：客户端主动提交触发合成（适合对话逐轮合成）

    文档：https://help.aliyun.com/zh/model-studio/realtime-tts-user-guide/
    """

    # CosyVoice v3-flash 音色列表（中文普通话）
    VOICE_LONGANYANG = "longanyang"    # 女声，自然大方
    VOICE_LONGXIAOCHUN_V2 = "longxiaochun_v2"  # 女声，活泼可爱

    def __init__(
        self,
        model: str = "cosyvoice-v3-flash",
        voice: str = "longanyang",
    ):
        self._api_key = DASHSCOPE_API_KEY
        self._model = model
        self._voice = voice
        self._ws = None
        self._task: asyncio.Task | None = None
        self._connected = False

    def check_quota(self) -> bool:
        """检查额度，超限返回 False"""
        return _daily_tts_usage < DAILY_TTS_QUOTA

    def add_usage(self, seconds: float):
        """记录使用量（估算）"""
        global _daily_tts_usage
        _daily_tts_usage += seconds

    @property
    def is_configured(self) -> bool:
        return bool(self._api_key)

    async def synthesize_stream(
        self,
        text: str,
        on_chunk: Callable[[str, int], None],
    ):
        """
        流式合成（server_commit 模式，文本分段追加给服务端）
        text: 完整文本
        on_chunk: 回调，接收 (mp3_base64, chunk_index)
        """
        if not self.is_configured:
            raise RuntimeError("DASHSCOPE_API_KEY not configured")

        if not self.check_quota():
            raise RuntimeError("Daily TTS quota exceeded")

        url = "wss://dashscope.aliyuncs.com/api-ws/v1/inference"
        headers = {"Authorization": f"Bearer {self._api_key}"}

        chunk_index = 0

        try:
            async with websockets.connect(url, extra_headers=headers, ping_interval=30) as ws:
                self._connected = True
                self._ws = ws

                # 发送会话参数
                await ws.send(json.dumps({
                    "type": "session.update",
                    "session": {
                        "model": self._model,
                        "audio": {
                            "format": "mp3",
                        },
                        # server_commit：服务端自动处理文本分段
                        "mode": "server_commit",
                    },
                }))

                # 等待会话就绪
                await self._wait_for("session.started", ws)

                # 按句子分批发送文本
                sentences = self._split_sentences(text)
                for sentence in sentences:
                    if len(sentence.strip()) < 5:
                        continue
                    await ws.send(json.dumps({
                        "type": "input_text.append",
                        "text": sentence,
                    }))

                # 通知服务端文本发送完毕
                await ws.send(json.dumps({"type": "input_text.flush"}))

                # 接收音频流
                mp3_buffer = b""
                async for raw in ws:
                    if isinstance(raw, bytes):
                        mp3_buffer += raw
                    else:
                        msg = json.loads(raw)
                        msg_type = msg.get("type", "")

                        if msg_type == "content":
                            audio_data = msg.get("audio", {})
                            data_b64 = audio_data.get("data", "")
                            if data_b64:
                                chunk_bytes = base64.b64decode(data_b64)
                                if chunk_bytes:
                                    mp3_base64 = base64.b64encode(chunk_bytes).decode()
                                    # 估算：每字约 0.3 秒音频
                                    self.add_usage(len(sentence) * 0.3)
                                    on_chunk(mp3_base64, chunk_index)
                                    chunk_index += 1

                        elif msg_type == "session.finish":
                            # 服务端完成合成
                            break

                        elif msg_type == "error":
                            print(f"[AliyunTTS] Error: {msg}")

                # 有完整 MP3 数据时也发一次（CosyVoice 可能一次性返回）
                if mp3_buffer and chunk_index == 0:
                    mp3_base64 = base64.b64encode(mp3_buffer).decode()
                    self.add_usage(len(text) * 0.3)
                    on_chunk(mp3_base64, 0)

        except Exception as e:
            print(f"[AliyunTTS] WebSocket TTS failed: {e}")
            raise

        finally:
            self._connected = False
            self._ws = None

    async def _wait_for(self, event_type: str, ws, timeout: float = 10.0):
        """等待特定类型的消息"""
        import asyncio
        loop = asyncio.get_event_loop()
        end_time = loop.time() + timeout

        async for raw in ws:
            if isinstance(raw, bytes):
                continue
            try:
                msg = json.loads(raw)
                if msg.get("type") == event_type:
                    return msg
                if msg.get("type") == "error":
                    print(f"[AliyunTTS] Wait error: {msg}")
            except json.JSONDecodeError:
                pass
            if loop.time() > end_time:
                break
        return None

    def _split_sentences(self, text: str) -> list[str]:
        """按标点分句，每段尽量 >=5 字（阿里云计费要求）"""
        import re
        parts = re.split(r"(?<=[。！？.!?；;，,])", text)
        result = []
        current = ""
        for part in parts:
            if len(current) + len(part) < 80:
                current += part
            else:
                if current.strip():
                    result.append(current.strip())
                current = part
        if current.strip():
            result.append(current.strip())
        return result if result else [text]
