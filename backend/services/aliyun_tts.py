"""阿里云流式TTS服务（实时语音合成 WebSocket 流式）"""
import base64
import hashlib
import hmac
import json
import time
import asyncio
import websockets
from typing import Callable
import httpx
from config import (
    ALIYUN_ACCESS_KEY_ID,
    ALIYUN_ACCESS_KEY_SECRET,
    ALIYUN_TTS_APP_KEY,
    ALIYUN_REGION,
    DAILY_TTS_QUOTA,
)


# 每日已使用额度（简单内存计数，生产环境应持久化到Redis/数据库）
_daily_tts_usage = 0.0


class AliyunTTS:
    """
    阿里云实时流式TTS服务

    通过 WebSocket 连接流式TTS服务，边合成边通过回调推送MP3分片。
    同时支持短文本 HTTP API 作为备选。

    文档：https://help.aliyun.com/zh/model-studio/realtime-tts-user-guide/
    """

    def __init__(self):
        self._app_key = ALIYUN_TTS_APP_KEY
        self._access_key = ALIYUN_ACCESS_KEY_ID
        self._secret = ALIYUN_ACCESS_KEY_SECRET
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
        return bool(self._app_key and self._access_key and self._secret)

    async def synthesize_stream(
        self,
        text: str,
        on_chunk: Callable[[str, int], None],
    ):
        """
        流式合成（WebSocket实时TTS）
        text: 完整文本
        on_chunk: 回调，接收 (mp3_base64, chunk_index)

        注意：阿里云实时TTS要求单次请求文本不少于5字。
        """
        if not self.is_configured:
            raise RuntimeError("Aliyun TTS credentials not configured")

        if not self.check_quota():
            raise RuntimeError("Daily TTS quota exceeded")

        # 按句子分句，每句>=5字
        sentences = self._split_sentences(text)
        chunk_index = 0
        total_chars = 0

        for sentence in sentences:
            if len(sentence.strip()) < 5:
                continue
            total_chars += len(sentence)

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

        # ── 生成签名 URL ──────────────────────────────────────────────
        # 阿里云流式TTS WebSocket 鉴权文档：
        # https://help.aliyun.com/zh/model-studio/realtime-tts-user-guide/
        timestamp = int(time.time() * 1000)
        query_params = (
            f"appkey={self._app_key}"
            f"&token="
            f"&v=2"
            f"&ts={timestamp}"
            f"&region={self._region}"
        )

        # 简化鉴权（正式环境请按阿里云文档生成 Token 或使用 STS 鉴权）
        # 此处使用 appkey + timestamp 基础鉴权，production 应启用 Token
        url = (
            f"wss://nls-gateway-{self._region}.aliyuncs.com/ws/v1/tts"
            f"?{query_params}"
        )

        try:
            async with websockets.connect(url, ping_interval=None) as ws:
                # 发送开始请求
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
                        # 控制帧
                        try:
                            ctrl = json.loads(msg)
                            if ctrl.get("code") != 200000000:
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
        HTTP API 合成（备选，适合短文本）
        endpoint: POST /stream/v1/tts
        """
        if not self._app_key:
            return None

        headers = {"Content-Type": "application/json"}
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
