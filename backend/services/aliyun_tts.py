"""阿里云流式TTS服务（智能语音交互 实时语音合成 WebSocket 流式）"""
import base64
import json
import time
import websockets
from typing import Callable
import httpx
from config import (
    ALIYUN_TTS_APP_KEY,
    ALIYUN_REGION,
    DAILY_TTS_QUOTA,
)


# 每日已使用额度（简单内存计数，生产环境应持久化到Redis/数据库）
_daily_tts_usage = 0.0


class AliyunTTS:
    """
    阿里云智能语音交互 — 实时流式语音合成

    认证方式：AppKey（项目 AppKey）+ Token
    Token 获取：阿里云控制台 → 语音服务 → 项目管理 → 复制 Token
    若不填 Token 则走匿名调用。

    文档：https://help.aliyun.com/zh/model-studio/realtime-tts-user-guide/
    """

    def __init__(self, token: str = ""):
        self._app_key = ALIYUN_TTS_APP_KEY
        self._token = token
        self._region = ALIYUN_REGION

    def check_quota(self) -> bool:
        """检查额度，超限返回False"""
        return _daily_tts_usage < DAILY_TTS_QUOTA

    def add_usage(self, seconds: float):
        """记录使用量（估算）"""
        global _daily_tts_usage
        _daily_tts_usage += seconds

    @property
    def is_configured(self) -> bool:
        return bool(self._app_key)

    async def synthesize_stream(
        self,
        text: str,
        on_chunk: Callable[[str, int], None],
    ):
        """
        流式合成（WebSocket 实时 TTS）
        text: 完整文本
        on_chunk: 回调，接收 (mp3_base64, chunk_index)

        注意：阿里云实时 TTS 要求单次请求文本不少于5字。
        """
        if not self.is_configured:
            raise RuntimeError("ALIYUN_TTS_APP_KEY not configured")

        if not self.check_quota():
            raise RuntimeError("Daily TTS quota exceeded")

        sentences = self._split_sentences(text)
        chunk_index = 0

        for sentence in sentences:
            if len(sentence.strip()) < 5:
                continue

            mp3_base64 = await self._synthesize_ws(sentence)
            if mp3_base64:
                self.add_usage(len(sentence) * 0.3)
                on_chunk(mp3_base64, chunk_index)
                chunk_index += 1

    async def _synthesize_ws(self, sentence: str) -> str | None:
        """
        WebSocket 流式合成单个句子。
        返回 MP3 base64 数据。
        """
        if not self._app_key:
            return None

        timestamp = int(time.time() * 1000)
        params = [
            ("appkey", self._app_key),
            ("token", self._token),
            ("v", "2"),
            ("ts", str(timestamp)),
            ("region", self._region),
        ]
        query = "&".join(f"{k}={v}" for k, v in params if v)
        url = f"wss://nls-gateway-{self._region}.aliyuncs.com/ws/v1/tts?{query}"

        try:
            async with websockets.connect(url, ping_interval=None) as ws:
                start_req = {
                    "appkey": self._app_key,
                    "text": sentence,
                    "format": "mp3",
                    "sample_rate": 16000,
                    "voice": "zhixiaobai",
                    "speech_rate": 0,
                    "pitch_rate": 0,
                }
                await ws.send(json.dumps(start_req))

                mp3_chunks = []
                async for msg in ws:
                    if isinstance(msg, bytes):
                        mp3_chunks.append(msg)
                    else:
                        try:
                            ctrl = json.loads(msg)
                            if ctrl.get("code", 0) != 200000000:
                                print(f"[AliyunTTS] Ctrl: {ctrl}")
                        except json.JSONDecodeError:
                            pass

                if mp3_chunks:
                    return base64.b64encode(b"".join(mp3_chunks)).decode()
        except Exception as e:
            print(f"[AliyunTTS] WebSocket TTS failed, falling back to HTTP: {e}")
            return await self._synthesize_http(sentence)

        return None

    async def _synthesize_http(self, sentence: str) -> str | None:
        """
        HTTP API 合成（备选，适合短文本）。
        认证：AppKey 同上，Token 可选。
        """
        if not self._app_key:
            return None

        headers = {"Content-Type": "application/json"}
        if self._token:
            headers["Authorization"] = f"Bearer {self._token}"

        payload = {
            "appkey": self._app_key,
            "text": sentence,
            "format": "mp3",
            "voice": "zhixiaobai",
            "sample_rate": 16000,
            "speech_rate": 0,
            "pitch_rate": 0,
        }

        try:
            async with httpx.AsyncClient(timeout=httpx.Timeout(30.0)) as client:
                resp = await client.post(
                    f"https://nls-gateway-{self._region}.aliyuncs.com/stream/v1/tts",
                    headers=headers,
                    json=payload,
                )
                if resp.status_code == 200:
                    return base64.b64encode(resp.content).decode()
                else:
                    print(f"[AliyunTTS] HTTP {resp.status_code}: {resp.text[:200]}")
        except Exception as e:
            print(f"[AliyunTTS] HTTP TTS failed: {e}")

        return None

    def _split_sentences(self, text: str) -> list[str]:
        """按标点分句，每段尽量 >=5 字"""
        import re
        parts = re.split(r"(?<=[。！？.!?；;，,])", text)
        result = []
        current = ""
        for part in parts:
            if len(current) + len(part) < 50:
                current += part
            else:
                if current.strip():
                    result.append(current.strip())
                current = part
        if current.strip():
            result.append(current.strip())
        return result if result else [text]
