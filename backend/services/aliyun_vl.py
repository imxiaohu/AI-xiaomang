"""阿里云通义千问VL服务（HTTP+图片）"""
import base64
import json
import httpx
from config import DASHSCOPE_API_KEY, ALIYUN_REGION


class AliyunVL:
    """
    通义千问VL服务

    HTTP调用通义千问VL API，
    接收前端上传的640x480 JPG图像 + 文本，
    返回推理结果，流式分词推送。
    """

    def __init__(self):
        self._api_key = DASHSCOPE_API_KEY
        self._region = ALIYUN_REGION

    async def chat_with_image(
        self,
        image_base64: str,
        prompt: str,
        context: list[dict[str, str]],
    ) -> str:
        """
        图文对话
        返回完整LLM推理文本（非流式，用于离线模式回退）
        """
        if not self._api_key:
            raise RuntimeError("DASHSCOPE_API_KEY not configured")

        headers = {
            "Authorization": f"Bearer {self._api_key}",
            "Content-Type": "application/json",
        }

        # 构建消息
        messages = context + [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:image/jpeg;base64,{image_base64}"},
                    },
                ],
            }
        ]

        payload = {
            "model": "qwen-vl-plus",
            "messages": messages,
            "stream": False,
        }

        async with httpx.AsyncClient(timeout=60.0) as client:
            resp = await client.post(
                "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation",
                headers=headers,
                json=payload,
            )
            resp.raise_for_status()
            data = resp.json()
            return data["output"]["choices"][0]["message"]["content"]

    def build_stream_payload(
        self,
        image_base64: str,
        prompt: str,
        context: list[dict[str, str]],
    ) -> dict:
        """构建流式请求payload"""
        messages = context + [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:image/jpeg;base64,{image_base64}"},
                    },
                ],
            }
        ]
        return {
            "model": "qwen-vl-plus",
            "messages": messages,
            "stream": True,
        }

    @property
    def is_configured(self) -> bool:
        return bool(self._api_key)
