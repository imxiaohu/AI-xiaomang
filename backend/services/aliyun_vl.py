"""阿里云通义千问 VL/文本服务（OpenAI 兼容端点，流式/非流式）"""
import json
import httpx
from typing import AsyncIterator, Callable, Awaitable
from config import DASHSCOPE_API_KEY, ALIYUN_REGION, SYSTEM_PROMPT


def _build_system_message(round_count: int = 0) -> dict:
    """
    构造 system 消息，带显式缓存标记。
    占位符 {round} 会被替换为当前对话轮次。
    """
    text = SYSTEM_PROMPT.replace("{round}", str(round_count))
    msg = {
        "role": "system",
        "content": [
            {
                "type": "text",
                "text": text,
            }
        ],
    }
    # #region agent log
    # 假设 E：DashScope 兼容模式是否识别 OpenAI 风格的 cache_control
    try:
        import json as _json
        import time as _time
        with open("/Users/xiaohu/Downloads/AIVideo/.cursor/debug-b10e1d.log", "a", encoding="utf-8") as _f:
            _f.write(_json.dumps({
                "sessionId": "b10e1d",
                "runId": "initial",
                "hypothesisId": "E-cache-control",
                "location": "aliyun_vl.py:_build_system_message",
                "message": "system message has cache_control?",
                "data": {"text_len": len(text), "has_cache_control_marker": False},
                "timestamp": int(_time.time() * 1000),
            }, ensure_ascii=False) + "\n")
    except Exception:
        pass
    # #endregion
    return msg


def _build_user_message(
    text: str,
    image_b64: str | None = None,
    with_cache: bool = False,
) -> dict:
    """
    构造 user 消息。
    with_cache=True 时加 cache_control 标记（用于历史消息）。
    """
    if image_b64:
        content = [
            {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{image_b64}"}},
            {"type": "text", "text": text},
        ]
    else:
        content = [{"type": "text", "text": text}]

    if with_cache:
        # cache_control 放在最后一个 content 块
        content.append({"type": "text", "text": "", "cache_control": {"type": "ephemeral"}})

    return {"role": "user", "content": content}


def _apply_cache_control(msg: dict) -> dict:
    """
    对历史消息追加 cache_control 标记。
    规则：从后往前取最近 1 个 content 块打标记。
    （最多 4 个标记，这里只打最后一条历史消息，节省标记额度）
    """
    msg = dict(msg)  # shallow copy
    content = msg.get("content", "")
    if isinstance(content, str):
        msg["content"] = [
            {"type": "text", "text": content, "cache_control": {"type": "ephemeral"}}
        ]
    elif isinstance(content, list):
        # 末尾追加空文本带 cache_control
        content = list(content) + [{"type": "text", "text": "", "cache_control": {"type": "ephemeral"}}]
        msg["content"] = content
    return msg


def build_streaming_messages(
    history: list[dict],
    user_text: str,
    user_image_b64: str | None = None,
    round_count: int = 0,
    enable_cache: bool = True,
) -> list[dict]:
    """
    构造流式请求消息列表，自动加 cache_control 标记。

    缓存策略：
    - System prompt 永远带 cache_control（标记 1）
    - 最后一条历史消息带 cache_control（标记 2）
    - 当前 user message 不带标记

    这样第一轮请求创建两个缓存块，后续请求命中这两个块。
    """
    messages: list[dict] = []

    # System message（带缓存标记）
    messages.append(_build_system_message(round_count))

    if not enable_cache:
        # 不启用缓存：直接拼接历史和当前消息
        for msg in history:
            messages.append(dict(msg))
        messages.append(_build_user_message(user_text, user_image_b64, with_cache=False))
        return messages

    # 历史消息
    if history:
        # 除最后一条外的历史消息：无标记
        for msg in history[:-1]:
            messages.append(dict(msg))
        # 最后一条历史消息：加 cache_control（提高第二轮命中率）
        last = _apply_cache_control(history[-1])
        messages.append(last)

    # 当前用户消息（无 cache_control，触发缓存命中）
    messages.append(_build_user_message(user_text, user_image_b64, with_cache=False))

    return messages


class AliyunVL:
    """
    通义千问 VL/文本服务 — OpenAI 兼容流式接口

    base_url: https://dashscope.aliyuncs.com/compatible-mode/v1
    认证: DASHSCOPE_API_KEY

    模型:
      - qwen-vl-plus / qwen-vl-max        (图文对话，Qwen2)
      - qwen3-vl-plus / qwen3-vl-flash    (图文对话，Qwen3)
      - qwen-plus / qwen3.5-plus / qwen3.5-flash  (纯文本)

    上下文缓存：build_streaming_messages() 自动在 system/history 消息上
    加 cache_control 标记，触发显式缓存（命中后 10% 计费）。

    文档: https://help.aliyun.com/zh/model-studio/stream
    """

    BASE_URL = "https://dashscope.aliyuncs.com/compatible-mode/v1"

    def __init__(self, model: str = "qwen3-vl-plus"):
        self._api_key = DASHSCOPE_API_KEY
        self._model = model
        self._region = ALIYUN_REGION

    @property
    def is_configured(self) -> bool:
        return bool(self._api_key)

    def _headers(self) -> dict:
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
        messages: 完整消息列表（含 system/history/user）
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
                headers=self._headers(),
                json=payload,
            ) as resp:
                # #region agent log
                try:
                    import json as _json
                    import time as _time
                    with open("/Users/xiaohu/Downloads/AIVideo/.cursor/debug-b10e1d.log", "a", encoding="utf-8") as _f:
                        _f.write(_json.dumps({
                            "sessionId": "b10e1d",
                            "runId": "initial",
                            "hypothesisId": "E-cache-control",
                            "location": "aliyun_vl.py:chat_stream:resp",
                            "message": "vl chat_stream HTTP response",
                            "data": {
                                "status_code": resp.status_code,
                                "model": self._model,
                                "msg_count": len(messages),
                            },
                            "timestamp": int(_time.time() * 1000),
                        }, ensure_ascii=False) + "\n")
                except Exception:
                    pass
                # #endregion
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

                    choices = chunk.get("choices", [])
                    if not choices:
                        continue

                    delta = choices[0].get("delta", {})
                    content = delta.get("content")
                    if content:
                        yield content
                        if on_token:
                            await on_token(content)

    async def chat(
        self,
        messages: list[dict],
    ) -> str:
        """非流式对话"""
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
                headers=self._headers(),
                json=payload,
            )
            resp.raise_for_status()
            data = resp.json()

        choices = data.get("choices", [])
        if choices:
            return choices[0].get("message", {}).get("content", "") or ""
        return ""

    # ── 快捷入口：直接传入历史/用户信息，自动构造 messages ──

    async def chat_with_image_stream(
        self,
        image_base64: str,
        prompt: str,
        context: list[dict],
        round_count: int = 0,
        on_token: Callable[[str], Awaitable[None]] | None = None,
    ) -> AsyncIterator[str]:
        """
        图文流式对话（自动加 cache_control 标记）
        context: 历史消息列表
        """
        messages = build_streaming_messages(context, prompt, image_base64, round_count)
        async for token in self.chat_stream(messages, on_token=on_token):
            yield token

    async def chat_with_image(
        self,
        image_base64: str,
        prompt: str,
        context: list[dict],
        round_count: int = 0,
    ) -> str:
        """图文非流式对话"""
        messages = build_streaming_messages(context, prompt, image_base64, round_count)
        return await self.chat(messages)

    async def chat_text_only_stream(
        self,
        prompt: str,
        context: list[dict],
        round_count: int = 0,
        on_token: Callable[[str], Awaitable[None]] | None = None,
    ) -> AsyncIterator[str]:
        """纯文本流式对话"""
        messages = build_streaming_messages(context, prompt, None, round_count)
        async for token in self.chat_stream(messages, on_token=on_token):
            yield token

    async def chat_text_only(
        self,
        prompt: str,
        context: list[dict],
        round_count: int = 0,
    ) -> str:
        """纯文本非流式对话"""
        messages = build_streaming_messages(context, prompt, None, round_count)
        return await self.chat(messages)
