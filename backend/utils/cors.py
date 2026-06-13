"""SSE 跨域处理与 URL 鉴权参数工具

SSE 不支持跨域自定义 Header（如 Authorization），
因此客户端通过 URL query parameters 传递鉴权 token。
"""
import os
from typing import Optional


def _is_test_mode() -> bool:
    """从 .env 读取 TEST_MODE 配置，避免直接依赖 config.py 循环导入"""
    try:
        from dotenv import load_dotenv
        load_dotenv()
        return os.getenv('TEST_MODE', 'false').lower() == 'true'
    except Exception:
        return False


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

    TEST_MODE=true 时跳过 token 校验，方便本地/测试环境联调。
    与 DEBUG 模式（是否用 mock 响应）完全解耦。

    Returns:
        (is_valid, error_message)
    """
    if not ctx_id:
        return False, "会话ID不能为空"

    # TEST_MODE 跳过 token 校验（测试/开发联调用）
    if not _is_test_mode():
        if not token:
            return False, "鉴权token不能为空"
        if len(token) > 512:
            return False, "token格式非法"

    if len(ctx_id) > 128:
        return False, "会话ID格式非法"

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
