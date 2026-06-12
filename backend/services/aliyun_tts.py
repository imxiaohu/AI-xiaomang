"""阿里云流式TTS服务"""
import base64
import json
import httpx
from config import ALIYUN_ACCESS_KEY_ID, ALIYUN_ACCESS_KEY_SECRET, ALIYUN_TTS_APP_KEY, ALIYUN_REGION, DAILY_TTS_QUOTA

# 每日已使用额度（简单内存计数，生产环境应持久化
_daily_tts_usage = 0.0
_daily_reset_hour = 0  # 每小时重置（演示用）


class AliyunTTS:
    """
    阿里云流式TTS服务

    接收文本流，每>=5字合成一段MP3，
    base64编码后通过SSE推送。
    注意：阿里云单片段文本不得少于5字，否则无效计费。
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
        on_chunk: callable,
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

        # 分段：每>=5字一段
        sentences = self._split_sentences(text)

        for idx, sentence in enumerate(sentences):
            if len(sentence.strip()) < 5:
                continue  # 跳过少于5字的片段

            mp3_base64 = await self._synthesize_sentence(sentence)
            if mp3_base64:
                self.add_usage(len(sentence) / 10.0)  # 粗估计费
                await on_chunk(mp3_base64, idx)

    def _split_sentences(self, text: str) -> list[str]:
        """按句子分词，每段尽量>=5字"""
        # 简单按标点或字数分
        result = []
        current = ""
        for char in text:
            current += char
            if len(current) >= 15:
                result.append(current)
                current = ""
        if current:
            result.append(current)
        return result

    async def _synthesize_sentence(self, sentence: str) -> str | None:
        """合成单个句子为MP3（base64）"""
        # 阿里云TTS HTTP调用占位
        # 实际对接请替换为阿里云TTS API
        # 此处返回None，实际使用时需接入真实API
        headers = {
            "Content-Type": "application/json",
        }
        payload = {
            "appkey": self._app_key,
            "text": sentence,
            "format": "mp3",
            "voice": "xiaoyun",
            "sample_rate": 16000,
        }
        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                resp = await client.post(
                    f"https://nls-gateway-{self._region}.aliyuncs.com/stream/v1/tts",
                    headers=headers,
                    json=payload,
                )
                if resp.status_code == 200:
                    return base64.b64encode(resp.content).decode()
        except Exception as e:
            print(f"[AliyunTTS] Synthesize failed: {e}")
        return None

    @property
    def is_configured(self) -> bool:
        return bool(self._app_key and self._access_key and self._secret)
