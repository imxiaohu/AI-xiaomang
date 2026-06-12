"""阿里云流式TTS服务"""
import base64
import re
from typing import Callable, Any
import httpx
from config import ALIYUN_ACCESS_KEY_ID, ALIYUN_ACCESS_KEY_SECRET, ALIYUN_TTS_APP_KEY, ALIYUN_REGION, DAILY_TTS_QUOTA

# 每日已使用额度（简单内存计数，生产环境应持久化到Redis/数据库）
_daily_tts_usage = 0.0
_daily_reset_hour = 0


class AliyunTTS:
    """
    阿里云流式TTS服务

    接收文本流，按句子分段合成MP3，
    base64编码后通过SSE推送。
    注意：阿里云单片段文本不得少于5字，否则无效计费。

    文档参考：https://help.aliyun.com/zh/model-studio/realtime-tts-user-guide?spm=a2c4g.11186623.help-menu-2400256.d_0_3_5_0.218a14579uxm25
    """

    def __init__(self):
        self._app_key = ALIYUN_TTS_APP_KEY
        self._access_key = ALIYUN_ACCESS_KEY_ID
        self._secret = ALIYUN_ACCESS_KEY_SECRET
        self._region = ALIYUN_REGION

    def check_quota(self) -> bool:
        """检查额度，超限返回False"""
        global _daily_tts_usage
        return _daily_tts_usage < DAILY_TTS_QUOTA

    def add_usage(self, seconds: float):
        """记录使用量"""
        global _daily_tts_usage
        _daily_tts_usage += seconds

    async def synthesize_stream(
        self,
        text: str,
        on_chunk: Callable[[str, int], None],
    ):
        """
        流式合成
        text: 完整文本
        on_chunk: 回调，接收 (mp3_base64, chunk_index)
        """
        if not self._app_key:
            raise RuntimeError("ALIYUN_TTS_APP_KEY not configured")

        if not self.check_quota():
            raise RuntimeError("Daily TTS quota exceeded")

        # 分段：每>=5字一段，避免碎片
        sentences = self._split_sentences(text)

        chunk_index = 0
        for sentence in sentences:
            if len(sentence.strip()) < 5:
                continue  # 跳过少于5字的片段

            mp3_base64 = await self._synthesize_sentence(sentence)
            if mp3_base64:
                # 粗略估计：每字约0.3秒音频
                self.add_usage(len(sentence) * 0.3)
                on_chunk(mp3_base64, chunk_index)
                chunk_index += 1

    def _split_sentences(self, text: str) -> list[str]:
        """按句子分词，每段尽量>=5字"""
        # 按标点符号分句
        parts = re.split(r'(?<=[。！？.!?；;，,])', text)
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

    async def _synthesize_sentence(self, sentence: str) -> str | None:
        """
        合成单个句子为MP3（base64）

        阿里云TTS调用方式：
        方式1：HTTP API（适合短文本，一次性返回）
        方式2：WebSocket流式（适合长文本，逐步返回）

        此处使用HTTP API，适合短句子合成
        """
        if not self._app_key:
            return None

        headers = {
            "Content-Type": "application/json",
        }

        payload = {
            "appkey": self._app_key,
            "text": sentence,
            "format": "mp3",
            "voice": "zhixiaobai",  # 活泼女声，适合助手场景
            "sample_rate": 16000,
            "speech_rate": 0,       # 语速：0为正常
            "pitch_rate": 0,        # 音调：0为正常
        }

        try:
            # 阿里云TTS HTTP API
            async with httpx.AsyncClient(timeout=30.0) as client:
                resp = await client.post(
                    f"https://nls-gateway-{self._region}.aliyuncs.com/stream/v1/tts",
                    headers=headers,
                    json=payload,
                )
                if resp.status_code == 200:
                    # 直接返回MP3二进制
                    return base64.b64encode(resp.content).decode()
                else:
                    print(f"[AliyunTTS] HTTP {resp.status_code}: {resp.text[:200]}")
        except httpx.ConnectError as e:
            print(f"[AliyunTTS] Connection failed: {e}")
        except Exception as e:
            print(f"[AliyunTTS] Synthesize failed: {e}")
        return None

    @property
    def is_configured(self) -> bool:
        return bool(self._app_key and self._access_key and self._secret)
