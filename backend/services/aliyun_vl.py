"""阿里云通义千问VL服务（dashscope API，支持图文对话）"""
import json
import httpx
from typing import Callable
from config import DASHSCOPE_API_KEY, ALIYUN_REGION


class AliyunVL:
    """
    通义千问 VL 服务

    HTTP 调用 dashscope API，支持图文多模态对话。
    模型：qwen-vl-plus（视觉理解）或 qwen-vl-max（更强视觉）

    文档：
    - https://help.aliyun.com/zh/model-studio/text-generation-model/
    - 百炼平台：https://bailian.console.aliyun.com/
    """

    def __init__(self):
        self._api_key = DASHSCOPE_API_KEY
        self._region = ALIYUN_REGION
        self._base_url = "https://dashscope.aliyuncs.com/api/v1"

    @property
    def is_configured(self) -> bool:
        return bool(self._api_key)

    async def chat_with_image(
        self,
        image_base64: str,
        prompt: str,
        context: list[dict[str, str]],
    ) -> str:
        """
        图文对话（非流式，返回完整文本）
        context: 消息历史，每条 { "role": "user"|"assistant", "content": str }
        """
        if not self.is_configured:
            raise RuntimeError("DASHSCOPE_API_KEY not configured")

        headers = {
            "Authorization": f"Bearer {self._api_key}",
            "Content-Type": "application/json",
        }

        # 构建消息历史
        messages = []
        for msg in context:
            if isinstance(msg.get("content"), str):
                messages.append({"role": msg["role"], "content": msg["content"]})
            elif isinstance(msg.get("content"), list):
                messages.append(msg)

        # 当前用户消息：文本 + 图片
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

        # dashscope 多模态生成接口（qwen-vl-plus）
        payload = {
            "model": "qwen-vl-plus",
            "input": {"messages": messages},
            "parameters": {"stream": False},
        }

        async with httpx.AsyncClient(timeout=httpx.Timeout(120.0)) as client:
            resp = await client.post(
                f"{self._base_url}/services/aigc/multimodal-generation/generation",
                headers=headers,
                json=payload,
            )
            resp.raise_for_status()
            data = resp.json()

        # 解析返回：{ "output": { "choices": [{ "message": { "content": "..." } }] } }
        output = data.get("output", {})
        choices = output.get("choices", [])
        if choices:
            return choices[0].get("message", {}).get("content", "")
        return ""

    async def chat_with_image_stream(
        self,
        image_base64: str,
        prompt: str,
        context: list[dict[str, str]],
        on_token: Callable[[str], None] | None = None,
    ) -> str:
        """
        图文对话（流式，通过 on_token 回调逐 token 返回）
        注意：qwen-vl-plus 视觉模型不支持 SSE 流式，
        此方法通过逐 token 模拟流式效果（实际为非流式一次性返回）。
        如需真实流式视觉回答，请使用 qwen-vl-max 或 text-generation 端点。
        """
        if not self.is_configured:
            raise RuntimeError("DASHSCOPE_API_KEY not configured")

        headers = {
            "Authorization": f"Bearer {self._api_key}",
            "Content-Type": "application/json",
        }

        messages = []
        for msg in context:
            if isinstance(msg.get("content"), str):
                messages.append({"role": msg["role"], "content": msg["content"]})
            elif isinstance(msg.get("content"), list):
                messages.append(msg)

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
            "parameters": {"stream": True},  # dashscope 支持流式
        }

        full_text = ""
        async with httpx.AsyncClient(timeout=httpx.Timeout(120.0)) as client:
            async with client.stream(
                "POST",
                f"{self._base_url}/services/aigc/multimodal-generation/generation",
                headers=headers,
                json=payload,
            ) as resp:
                resp.raise_for_status()
                async for line in resp.aiter_lines():
                    if not line.strip() or not line.startswith("data:"):
                        continue
                    data_str = line[5:].strip()
                    if not data_str or data_str == "[DONE]":
                        continue
                    try:
                        chunk = json.loads(data_str)
                        # 视觉模型流式返回格式
                        choices = chunk.get("output", {}).get("choices", [])
                        if choices:
                            token = choices[0].get("message", {}).get("content", "")
                        else:
                            token = chunk.get("output", {}).get("text", "")
                        if token:
                            full_text += token
                            if on_token:
                                on_token(token)
                    except json.JSONDecodeError:
                        continue

        return full_text

    async def chat_text_only(
        self,
        prompt: str,
        context: list[dict[str, str]],
    ) -> str:
        """
        纯文本对话（不使用视觉），调用 text-generation 端点。
        适合没有图片输入时的对话，可支持真实 SSE 流式。
        """
        if not self.is_configured:
            raise RuntimeError("DASHSCOPE_API_KEY not configured")

        headers = {
            "Authorization": f"Bearer {self._api_key}",
            "Content-Type": "application/json",
        }

        messages = []
        for msg in context:
            messages.append({"role": msg["role"], "content": msg.get("content", "")})

        messages.append({"role": "user", "content": prompt})

        payload = {
            "model": "qwen-plus",
            "input": {"messages": messages},
            "parameters": {"stream": False},
        }

        async with httpx.AsyncClient(timeout=httpx.Timeout(60.0)) as client:
            resp = await client.post(
                f"{self._base_url}/services/aigc/text-generation/generation",
                headers=headers,
                json=payload,
            )
            resp.raise_for_status()
            data = resp.json()

        choices = data.get("output", {}).get("choices", [])
        if choices:
            return choices[0].get("message", {}).get("content", "")
        return ""
