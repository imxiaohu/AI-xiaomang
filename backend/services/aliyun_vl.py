"""阿里云通义千问VL服务（HTTP+图片，流式响应）"""
import json
from typing import Callable
import httpx
from config import DASHSCOPE_API_KEY, ALIYUN_REGION


class AliyunVL:
    """
    通义千问VL服务

    HTTP调用通义千问VL API，
    接收前端上传的640x480 JPG图像 + 文本，
    返回推理结果（支持流式分词）。

    API文档：https://help.aliyun.com/zh/model-studio/text-generation-model/?spm=a2c4g.11186623.help-menu-2400256.d_0_3_0.4a5a1457HPnHeC/
    百炼平台：https://bailian.console.aliyun.com/
    """

    def __init__(self):
        self._api_key = DASHSCOPE_API_KEY
        self._region = ALIYUN_REGION
        self._base_url = "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"

    async def chat_with_image(
        self,
        image_base64: str,
        prompt: str,
        context: list[dict[str, str]],
    ) -> str:
        """
        图文对话（非流式版本，返回完整文本）
        返回LLM推理文本
        """
        if not self._api_key:
            raise RuntimeError("DASHSCOPE_API_KEY not configured")

        headers = {
            "Authorization": f"Bearer {self._api_key}",
            "Content-Type": "application/json",
        }

        # 构建消息历史
        messages = list(context)
        messages.append({
            "role": "user",
            "content": [
                {"type": "text", "text": prompt},
                {
                    "type": "image_url",
                    "image_url": {"url": f"data:image/jpeg;base64,{image_base64}"},
                },
            ],
        })

        payload = {
            "model": "qwen-vl-plus",
            "input": {"messages": messages},
            "parameters": {"stream": False},
        }

        async with httpx.AsyncClient(timeout=120.0) as client:
            resp = await client.post(
                self._base_url,
                headers=headers,
                json=payload,
            )
            resp.raise_for_status()
            data = resp.json()
            return data["output"]["choices"][0]["message"]["content"]

    async def chat_with_image_stream(
        self,
        image_base64: str,
        prompt: str,
        context: list[dict[str, str]],
        on_token: Callable[[str], None] | None = None,
    ) -> str:
        """
        图文对话（流式版本，通过回调逐token返回）
        返回完整文本
        """
        if not self._api_key:
            raise RuntimeError("DASHSCOPE_API_KEY not configured")

        headers = {
            "Authorization": f"Bearer {self._api_key}",
            "Content-Type": "application/json",
        }

        messages = list(context)
        messages.append({
            "role": "user",
            "content": [
                {"type": "text", "text": prompt},
                {
                    "type": "image_url",
                    "image_url": {"url": f"data:image/jpeg;base64,{image_base64}"},
                },
            ],
        })

        payload = {
            "model": "qwen-vl-plus",
            "input": {"messages": messages},
            "parameters": {"stream": True},
        }

        full_text = ""
        async with httpx.AsyncClient(timeout=120.0) as client:
            async with client.stream("POST", self._base_url, headers=headers, json=payload) as resp:
                resp.raise_for_status()
                async for line in resp.aiter_lines():
                    if not line.strip() or not line.startswith("data:"):
                        continue
                    data_str = line[5:].strip()
                    if not data_str or data_str == "[DONE]":
                        continue
                    try:
                        chunk = json.loads(data_str)
                        token = chunk.get("output", {}).get("choices", [{}])[0].get("message", {}).get("content", "")
                        if token:
                            full_text += token
                            on_token and on_token(token)
                    except json.JSONDecodeError:
                        continue

        return full_text

    @property
    def is_configured(self) -> bool:
        return bool(self._api_key)
