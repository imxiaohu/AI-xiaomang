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
        self._connected = False
        self._task: asyncio.Task | None = None

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

    # ──────────────────────────────────────────────────────────────
    # 场景一：批量合成（一次性提交全部文本）
    # ──────────────────────────────────────────────────────────────

    async def synthesize(
        self,
        text: str,
    ) -> str:
        """
        一次性合成（等待完整 MP3，返回 base64）
        返回完整 MP3 base64 字符串
        """
        if not self.is_configured:
            raise RuntimeError("DASHSCOPE_API_KEY not configured")

        url = "wss://dashscope.aliyuncs.com/api-ws/v1/inference"
        headers = {"Authorization": f"Bearer {self._api_key}"}

        sentences = self._split_sentences(text)
        if not sentences:
            return ""

        mp3_buffer = b""

        async with websockets.connect(url, extra_headers=headers, ping_interval=30) as ws:
            await ws.send(json.dumps({
                "type": "session.update",
                "session": {
                    "model": self._model,
                    "audio": {"format": "mp3"},
                    "mode": "server_commit",
                },
            }))

            await self._wait_for("session.started", ws)

            for sentence in sentences:
                if len(sentence.strip()) < 5:
                    continue
                await ws.send(json.dumps({
                    "type": "input_text.append",
                    "text": sentence,
                }))

            await ws.send(json.dumps({"type": "input_text.flush"}))

            mp3_buffer = b""
            async for raw in ws:
                if isinstance(raw, bytes):
                    mp3_buffer += raw
                else:
                    msg = json.loads(raw)
                    msg_type = msg.get("type", "")
                    if msg_type == "session.finish":
                        break
                    if msg_type == "error":
                        print(f"[AliyunTTS] Error: {msg}")

        if mp3_buffer:
            return base64.b64encode(mp3_buffer).decode()
        return ""

    # ──────────────────────────────────────────────────────────────
    # 场景二：流式合成（增量追加文本，实时推送 MP3 分片）
    # ──────────────────────────────────────────────────────────────

    async def synthesize_stream(
        self,
        on_audio: Callable[[str], None] | None = None,
    ) -> "TTSStreamContext":
        """
        启动流式 TTS 连接，返回 TTSStreamContext（上下文管理器）。

        on_audio: 回调，接收 MP3 分片 base64，实时推送
                  调用方在回调中把 MP3 base64 发给前端播放

        用法（asyncio 并行）：
            tts_ctx = await tts.synthesize_stream(on_audio=my_callback)
            async for token in vl.chat_stream(...):
                await tts_ctx.append_text(token)
            await tts_ctx.flush()

        或简化为：
            async for token in vl.chat_stream(...):
                await tts_ctx.append_text(token)
                if len(buffer) >= 30:
                    await tts_ctx.flush()
            await tts_ctx.finish()
        """
        if not self.is_configured:
            raise RuntimeError("DASHSCOPE_API_KEY not configured")

        if not self.check_quota():
            raise RuntimeError("Daily TTS quota exceeded")

        ctx = TTSStreamContext(
            api_key=self._api_key,
            model=self._model,
            voice=self._voice,
            on_audio=on_audio,
        )
        await ctx.connect()
        return ctx

    def _split_sentences(self, text: str) -> list[str]:
        """按标点分句，每段尽量 >=5 字"""
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

    async def _wait_for(self, event_type: str, ws, timeout: float = 10.0):
        """等待特定类型的消息"""
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


class TTSStreamContext:
    """
    TTS 流式上下文管理器。

    用于：VL 流式 token → TTS 增量追加 → MP3 分片实时推送。
    """

    def __init__(
        self,
        api_key: str,
        model: str,
        voice: str,
        on_audio: Callable[[str], None] | None = None,
    ):
        self._api_key = api_key
        self._model = model
        self._voice = voice
        self._on_audio = on_audio
        self._ws = None
        self._connected = False
        self._text_buffer = ""
        self._session_started = False
        self._closed = False
        self._task: asyncio.Task | None = None
        # 累积估算使用量
        self._total_chars = 0

    async def connect(self):
        """建立 WebSocket 连接并初始化会话"""
        url = "wss://dashscope.aliyuncs.com/api-ws/v1/inference"
        headers = {"Authorization": f"Bearer {self._api_key}"}

        self._ws = await websockets.connect(
            url, extra_headers=headers, ping_interval=30
        )
        self._connected = True

        # 发送会话参数
        await self._ws.send(json.dumps({
            "type": "session.update",
            "session": {
                "model": self._model,
                "audio": {"format": "mp3"},
                "voice": self._voice,
                # commit 模式：客户端控制提交时机（适合逐 token 追加）
                "mode": "commit",
            },
        }))

        # 等待 session.started
        await self._wait_for("session.started")
        self._session_started = True

        # 启动接收循环
        self._task = asyncio.create_task(self._recv_loop())

    async def append_text(self, text: str):
        """
        增量追加文本（发送给 TTS 服务）。
        每次调用会将文本追加到音频缓冲区。
        建议每次积累 10-20 字再调用（避免过碎的分片）。
        """
        if not self._connected or self._ws is None or self._closed:
            return

        self._text_buffer += text
        self._total_chars += len(text)

        # 积累足够文本（>=5 字）才发送，避免 TTS 无内容报错
        if len(self._text_buffer.strip()) >= 5:
            await self._ws.send(json.dumps({
                "type": "input_text.append",
                "text": self._text_buffer,
            }))
            self._text_buffer = ""

    async def flush(self):
        """
        主动提交当前文本缓冲区，触发服务端合成音频。
        调用后清空 buffer，服务端开始处理之前追加的所有文本。
        """
        if not self._connected or self._ws is None or self._closed:
            return

        if self._text_buffer.strip():
            await self._ws.send(json.dumps({
                "type": "input_text.append",
                "text": self._text_buffer,
            }))
            self._text_buffer = ""

        await self._ws.send(json.dumps({"type": "input_text.flush"}))

    async def finish(self):
        """结束会话，等待所有音频返回后关闭连接"""
        if not self._connected or self._closed:
            return

        # 最后一次 flush
        if self._text_buffer.strip():
            try:
                await self._ws.send(json.dumps({
                    "type": "input_text.append",
                    "text": self._text_buffer,
                }))
                self._text_buffer = ""
                await self._ws.send(json.dumps({"type": "input_text.flush"}))
            except Exception:
                pass

        # 通知会话结束
        try:
            await self._ws.send(json.dumps({"type": "session.finish"}))
        except Exception:
            pass

        # 等待接收循环结束
        if self._task:
            try:
                await asyncio.wait_for(self._task, timeout=5.0)
            except (asyncio.TimeoutError, asyncio.CancelledError):
                pass

        self._closed = True

    async def close(self):
        """强制关闭连接（不等待音频）"""
        self._closed = True
        if self._task:
            self._task.cancel()
            self._task = None
        if self._ws:
            try:
                await self._ws.close()
            except Exception:
                pass
            self._ws = None
        self._connected = False

    async def _recv_loop(self):
        """接收 TTS 音频分片，触发 on_audio 回调"""
        if self._ws is None:
            return

        mp3_buffer = b""
        try:
            async for raw in self._ws:
                if self._closed:
                    break

                if isinstance(raw, bytes):
                    mp3_buffer += raw
                    continue

                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    continue

                msg_type = msg.get("type", "")

                # 音频分片（CosyVoice v3-flash 流式分片）
                if msg_type == "content":
                    audio_data = msg.get("audio", {})
                    data_b64 = audio_data.get("data", "")
                    if data_b64:
                        chunk_bytes = base64.b64decode(data_b64)
                        if chunk_bytes:
                            chunk_b64 = base64.b64encode(chunk_bytes).decode()
                            if self._on_audio:
                                self._on_audio(chunk_b64)
                            # 估算使用量：每中文字约 0.3 秒音频
                            self._total_chars += 0

                    # 累积二进制 MP3 数据
                    # （CosyVoice 也可能直接返回二进制帧）

                # 会话结束
                elif msg_type == "session.finish":
                    # 最后残留的 MP3 数据
                    if mp3_buffer:
                        chunk_b64 = base64.b64encode(mp3_buffer).decode()
                        if self._on_audio:
                            self._on_audio(chunk_b64)
                    break

                # 错误
                elif msg_type == "error":
                    print(f"[AliyunTTS] Error: {msg}")

                # task 结束时也发残留 MP3
                elif msg_type == "task-finished":
                    if mp3_buffer:
                        chunk_b64 = base64.b64encode(mp3_buffer).decode()
                        if self._on_audio:
                            self._on_audio(chunk_b64)
                    break

        except websockets.ConnectionClosed:
            print("[AliyunTTS] Connection closed")
        except asyncio.CancelledError:
            pass
        except Exception as e:
            print(f"[AliyunTTS] Recv loop error: {e}")
        finally:
            # 估算使用量
            global _daily_tts_usage
            _daily_tts_usage += self._total_chars * 0.3

    async def _wait_for(self, event_type: str, timeout: float = 10.0):
        """等待特定类型的消息"""
        if self._ws is None:
            return None

        loop = asyncio.get_event_loop()
        end_time = loop.time() + timeout

        async for raw in self._ws:
            if self._closed:
                return None
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
