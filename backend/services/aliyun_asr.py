"""阿里云实时ASR服务（Model Studio 语音识别 HTTP API）"""
import base64
import httpx
from config import (
    ALIYUN_ACCESS_KEY_ID,
    ALIYUN_ACCESS_KEY_SECRET,
    ALIYUN_ASR_APP_KEY,
    ALIYUN_REGION,
)


class AliyunASR:
    """
    阿里云 Model Studio ASR 客户端

    调用短音频识别 HTTP API：
    - POST https://llm.cn-beijing.aliyuncs.com/api/v1/workspace/default/service/a2xygq/score
    - 认证：阿里云 AccessKey/SecretKey（SDK签名，非token）

    文档：https://help.aliyun.com/zh/model-studio/asr-model/
    """

    def __init__(self):
        self._app_key = ALIYUN_ASR_APP_KEY
        self._access_key = ALIYUN_ACCESS_KEY_ID
        self._secret = ALIYUN_ACCESS_KEY_SECRET
        self._region = ALIYUN_REGION

    @property
    def is_configured(self) -> bool:
        return bool(self._app_key and self._access_key and self._secret)

    async def recognize(self, pcm_base64: str) -> str:
        """
        识别一段 PCM 音频（base64编码），返回识别文本。
        适用于短音频（<60s）识别。
        """
        if not self.is_configured:
            raise RuntimeError("Aliyun ASR credentials not configured")

        # API endpoint — 语音识别服务地址
        endpoint = (
            f"https://llm.{self._region}.aliyuncs.com"
            "/api/v1/workspace/default/service/a2xygq/score"
        )

        headers = {
            "Content-Type": "application/json",
            "X-Api-Key": self._access_key,          # 或 Authorization Bearer
        }

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

        # 解析返回结果（字段名以实际API文档为准）
        # 标准格式: { "result": { "text": "...", "duration_ms": xxx } }
        result = data.get("result", {})
        if isinstance(result, dict):
            return result.get("text", "")
        if isinstance(result, str):
            return result
        return ""
