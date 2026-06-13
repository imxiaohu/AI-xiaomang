"""SSE 跨域处理与 URL 鉴权参数工具

SSE 不支持跨域自定义 Header（如 Authorization），
因此客户端通过 URL query parameters 传递鉴权 token。
"""
from typing import Optional


def extract_token_from_query(token: Optional[str]) -> Optional[str]:
    """
    从 URL query 参数中提取鉴权 token。

    SSE 跨域场景下无法通过 Authorization Header 传递 token，
    故客户端在 GET /sse/chat?token=xxx 中携带。
    生产环境应验证 token 合法性。
    """
    if not token:
        return None
    # 简单非空校验，生产环境可扩展 JWT 验证等逻辑
    return token.strip() or None


def validate_session_params(ctx_id: Optional[str], token: Optional[str]) -> tuple[bool, str]:
    """
    校验 SSE 连接请求参数。

    Returns:
        (is_valid, error_message)
    """
    if not ctx_id:
        return False, "会话ID不能为空"

    if not token:
        return False, "鉴权token不能为空"

    if len(ctx_id) > 128:
        return False, "会话ID格式非法"

    if len(token) > 512:
        return False, "token格式非法"

    return True, ""


def build_sse_headers() -> dict[str, str]:
    """
    构建 SSE 响应标准 Header。

    关键点：
    - Content-Type: text/event-stream 声明流式响应
    - Cache-Control: no-cache 防止缓存
    - X-Accel-Buffering: no 禁用 Nginx 缓冲（服务端推送必须）
    - Access-Control-Allow-Origin: * 支持跨域（移动端）
    """
    return {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        "X-Accel-Buffering": "no",
        "Access-Control-Allow-Origin": "*",
        "Connection": "keep-alive",
    }
