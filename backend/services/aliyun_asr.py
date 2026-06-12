"""阿里云实时ASR服务（WebSocket流式）"""
import asyncio
import json
import base64
import time
import hashlib
import hmac
import httpx
from typing import Callable, Awaitable
from config import (
    ALIYUN_ACCESS_KEY_ID,
    ALIYUN_ACCESS_KEY_SECRET,
    ALIYUN_ASR_APP_KEY,
    ALIYUN_REGION,
)


class AliyunASR:
    """
    阿里云实时ASR客户端

    通过WebSocket连接阿里云实时语音识别服务，
    接收Flutter上传的PCM音频分片，转发识别结果到回调。

    文档参考：https://help.aliyun.com/zh/model-studio/asr-model/?spm=a2c4g.11186623.help-menu-2400256.d_0_3_7.2ba211076ZT2Dm/
    """

    def __init__(self):
        self._ws = None
        self._connected = False
        self._text_callback: Callable[[str], Awaitable[None]] | None = None
        self._task: asyncio.Task | None = None

    async def connect(self, on_text: Callable[[str], Awaitable[None]]):
        """
        建立WebSocket连接
        on_text: 识别文本回调
        """
        if not ALIYUN_ASR_APP_KEY:
            raise RuntimeError("ALIYUN_ASR_APP_KEY not configured")

        self._text_callback = on_text

        try:
            import websockets

            url = self._build_websocket_url()
            self._ws = await websockets.connect(url, ping_interval=None)
            self._connected = True
            self._task = asyncio.create_task(self._recv_loop())
        except Exception as e:
            print(f"[AliyunASR] Connection failed: {e}")
            self._connected = False

    def _build_websocket_url(self) -> str:
        """
        构建阿里云实时ASR WebSocket鉴权URL
        阿里云智能语音服务WebSocket地址需要生成签名
        """
        # 阿里云实时ASR WebSocket地址（上海region为例）
        # 实际地址请参考阿里云文档中「实时语音识别WebSocket API」
        host = f"nls-gateway-{ALIYUN_REGION}.aliyuncs.com"
        path = "/ws/v1"

        timestamp = int(time.time())
        params = (
            f"appkey={ALIYUN_ASR_APP_KEY}"
            f"&timestamp={timestamp}"
            f"&v=1.0"
            f"&token="
        )

        # 简化URL（生产环境需按阿里云文档生成完整签名）
        url = f"wss://{host}{path}?appkey={ALIYUN_ASR_APP_KEY}&timestamp={timestamp}"
        return url

    async def send_audio(self, pcm_base64: str):
        """
        发送PCM音频分片（base64编码）
        阿里云实时ASR协议：
        1. 发送音频帧（binary类型）
        2. 接收识别结果（text类型JSON）
        """
        if not self._connected or self._ws is None:
            return

        try:
            audio_bytes = base64.b64decode(pcm_base64)
            await self._ws.send(audio_bytes)
        except Exception as e:
            print(f"[AliyunASR] Send audio failed: {e}")

    async def send_audio_raw(self, audio_bytes: bytes):
        """发送原始二进制音频数据"""
        if not self._connected or self._ws is None:
            return
        try:
            await self._ws.send(audio_bytes)
        except Exception as e:
            print(f"[AliyunASR] Send raw audio failed: {e}")

    async def _recv_loop(self):
        """接收识别结果循环"""
        if self._ws is None:
            return
        try:
            async for msg in self._ws:
                if isinstance(msg, bytes):
                    # 二进制帧（可能是音频确认）
                    continue
                # 文本帧（JSON格式识别结果）
                try:
                    data = json.loads(msg)
                    # 阿里云实时ASR返回格式示例：
                    # {"task_id": "xxx", "result": {"text": "识别文本", "begin_time": 0, "end_time": 3000}}
                    if "result" in data:
                        result_data = data["result"]
                        if isinstance(result_data, dict):
                            text = result_data.get("text", "")
                        elif isinstance(result_data, str):
                            text = result_data
                        else:
                            text = ""
                        if text and self._text_callback:
                            await self._text_callback(text)
                except json.JSONDecodeError:
                    # 非JSON帧，可能是控制消息
                    print(f"[AliyunASR] Received non-JSON: {msg[:100]}")
        except Exception as e:
            print(f"[AliyunASR] Recv loop error: {e}")
        finally:
            self._connected = False

    async def close(self):
        """关闭连接"""
        self._connected = False
        if self._task:
            self._task.cancel()
            self._task = None
        if self._ws:
            try:
                await self._ws.close()
            except Exception:
                pass
            self._ws = None
