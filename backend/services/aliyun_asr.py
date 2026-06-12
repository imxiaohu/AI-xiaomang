"""阿里云实时ASR服务（智能语音交互 短音频识别 HTTP API）"""
import base64
import httpx
from config import (
    ALIYUN_ASR_APP_KEY,
    ALIYUN_REGION,
)


class AliyunASR:
    """
    阿里云智能语音交互 — 短音频识别 HTTP API

    认证方式：AppKey（项目 AppKey）+ Token
    Token 获取：阿里云控制台 → 语音服务 → 项目管理 → 复制 Token
    若不填 Token 则走匿名调用（有 QPS 限制）。

    文档：https://help.aliyun.com/zh/model-studio/asr-model/
    """

    def __init__(self, token: str = ""):
        self._app_key = ALIYUN_ASR_APP_KEY
        self._token = token
        self._region = ALIYUN_REGION

    @property
    def is_configured(self) -> bool:
        return bool(self._app_key)

    async def recognize(self, pcm_base64: str) -> str:
        """
        识别一段 PCM 音频（base64编码），返回识别文本。
        适用于短音频（<60s）识别。
        """
        if not self.is_configured:
            raise RuntimeError("ALIYUN_ASR_APP_KEY not configured")

        endpoint = (
            f"https://llm.{self._region}.aliyuncs.com"
            "/api/v1/workspace/default/service/a2xygq/score"
        )

        headers = {
            "Content-Type": "application/json",
        }

        # Token 鉴权（可选，不填走匿名调用）
        if self._token:
            headers["Authorization"] = f"Bearer {self._token}"

        payload = {
            "service_type": "asr",
            "appkey": self._app_key,
            "audio_format": "pcm",
            "sample_rate": 16000,
            "enable_punctuation_prediction": True,
            "enable_inverse_text_normalization": True,
            "audio_data": pcm_base64,
        }

        async with httpx.AsyncClient(timeout=httpx.Timeout(30.0)) as client:
            resp = await client.post(endpoint, headers=headers, json=payload)
            resp.raise_for_status()
            data = resp.json()

        # 返回格式: { "result": { "text": "...", "duration_ms": xxx } }
        result = data.get("result", {})
        if isinstance(result, dict):
            return result.get("text", "")
        if isinstance(result, str):
            return result
        return ""
