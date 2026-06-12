"""阿里云通义千问 VL/文本服务（OpenAI 兼容端点，流式/非流式）"""
import json
import httpx
from typing import AsyncIterator, Callable, Awaitable
from config import DASHSCOPE_API_KEY, ALIYUN_REGION


class AliyunVL:
    """
    通义千问 VL/文本服务 — OpenAI 兼容流式接口

    base_url: https://dashscope.aliyuncs.com/compatible-mode/v1
    认证: DASHSCOPE_API_KEY

    模型:
      - qwen-vl-plus / qwen-vl-max  (图文对话)
      - qwen-plus / qwen-max        (纯文本)
      - qwen3-vl-plus / qwen3-vl-max (Qwen3 视觉)
      - qwen3-plus / qwen3-max      (Qwen3 文本)

    文档: https://help.aliyun.com/zh/model-studio/stream
    """

    # OpenAI 兼容端点（流式推荐用这个）
    BASE_URL = "https://dashscope.aliyuncs.com/compatible-mode/v1"

    def __init__(self, model: str = "qwen-vl-plus"):
        self._api_key = DASHSCOPE_API_KEY
        self._model = model
        self._region = ALIYUN_REGION

    @property
    def is_configured(self) -> bool:
        return bool(self._api_key)

    def _make_headers(self) -> dict:
        return {
            "Authorization": f"Bearer {self._api_key}",
            "Content-Type": "application/json",
        }

    async def chat_stream(
        self,
        messages: list[dict],
        on_token: Callable[[str], Awaitable[None]] | None = None,
    ) -> AsyncIterator[str]:
        """
        流式对话（真实 SSE，逐 token yield）

        messages: OpenAI 格式消息列表
        on_token: 每个 token 的回调（可选，用于实时处理）

        Yields:
            每个文本 token（可能含标点，逐字符或逐词）

        Usage:
            async for token in vl.chat_stream(messages):
                print(token, end="", flush=True)
        """
        if not self.is_configured:
            raise RuntimeError("DASHSCOPE_API_KEY not configured")

        payload = {
            "model": self._model,
            "messages": messages,
            "stream": True,
        }

        async with httpx.AsyncClient(timeout=httpx.Timeout(120.0)) as client:
            async with client.stream(
                "POST",
                f"{self.BASE_URL}/chat/completions",
                headers=self._make_headers(),
                json=payload,
            ) as resp:
                resp.raise_for_status()
                async for line in resp.aiter_lines():
                    if not line.strip() or not line.startswith("data:"):
                        continue

                    data_str = line[5:].strip()
                    if data_str == "[DONE]":
                        break

                    try:
                        chunk = json.loads(data_str)
                    except json.JSONDecodeError:
                        continue

                    # OpenAI 流式格式
                    choices = chunk.get("choices", [])
                    if not choices:
                        continue

                    delta = choices[0].get("delta", {})
                    content = delta.get("content")

                    # 思考模型：reasoning_content 先于 content
                    # visual 模型不会有 reasoning_content
                    if content:
                        yield content
                        if on_token:
                            await on_token(content)

    async def chat(
        self,
        messages: list[dict],
    ) -> str:
        """
        非流式对话（一次性返回完整文本）
        """
        if not self.is_configured:
            raise RuntimeError("DASHSCOPE_API_KEY not configured")

        payload = {
            "model": self._model,
            "messages": messages,
            "stream": False,
        }

        async with httpx.AsyncClient(timeout=httpx.Timeout(120.0)) as client:
            resp = await client.post(
                f"{self.BASE_URL}/chat/completions",
                headers=self._make_headers(),
                json=payload,
            )
            resp.raise_for_status()
            data = resp.json()

        choices = data.get("choices", [])
        if choices:
            return choices[0].get("message", {}).get("content", "") or ""
        return ""

    # ── 快捷构造方法 ────────────────────────────────────────────

    async def chat_with_image_stream(
        self,
        image_base64: str,
        prompt: str,
        context: list[dict],
        on_token: Callable[[str], Awaitable[None]] | None = None,
    ) -> AsyncIterator[str]:
        """
        图文流式对话（流式 SSE，逐 token yield）
        context: 消息历史，每条 { "role": "user"|"assistant", "content": str 或 list }
        """
        messages = self._build_messages(context, prompt, image_base64)
        async for token in self.chat_stream(messages, on_token=on_token):
            yield token

    async def chat_with_image(
        self,
        image_base64: str,
        prompt: str,
        context: list[dict],
    ) -> str:
        """
        图文非流式对话
        """
        messages = self._build_messages(context, prompt, image_base64)
        return await self.chat(messages)

    def _build_messages(
        self,
        context: list[dict],
        prompt: str,
        image_base64: str,
    ) -> list[dict]:
        """构造 OpenAI 格式消息列表（含图片）"""
        messages = []
        for msg in context:
            role = msg.get("role", "user")
            content = msg.get("content", "")
            if isinstance(content, str):
                messages.append({"role": role, "content": content})
            elif isinstance(content, list):
                messages.append({"role": role, "content": content})

        messages.append({
            "role": "user",
            "content": [
                {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{image_base64}"}},
                {"type": "text", "text": prompt},
            ],
        })
        return messages

    async def chat_text_only_stream(
        self,
        prompt: str,
        context: list[dict],
        on_token: Callable[[str], Awaitable[None]] | None = None,
    ) -> AsyncIterator[str]:
        """
        纯文本流式对话
        context: 消息历史，每条 { "role": "user"|"assistant", "content": str }
        """
        messages = []
        for msg in context:
            messages.append({"role": msg.get("role", "user"), "content": msg.get("content", "")})
        messages.append({"role": "user", "content": prompt})

        async for token in self.chat_stream(messages, on_token=on_token):
            yield token

    async def chat_text_only(
        self,
        prompt: str,
        context: list[dict],
    ) -> str:
        """纯文本非流式对话"""
        messages = []
        for msg in context:
            messages.append({"role": msg.get("role", "user"), "content": msg.get("content", "")})
        messages.append({"role": "user", "content": prompt})
        return await self.chat(messages)
