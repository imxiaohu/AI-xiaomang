"""阿里云实时ASR服务（WebSocket流式）"""
import asyncio
import json
import base64
from typing import Callable, Awaitable
from config import ALIYUN_ACCESS_KEY_ID, ALIYUN_ACCESS_KEY_SECRET, ALIYUN_ASR_APP_KEY, ALIYUN_REGION


class AliyunASR:
    """
    阿里云实时ASR客户端

    通过WebSocket连接阿里云实时语音识别服务，
    接收Flutter上传的PCM音频分片，转发识别结果到回调。
    """

    def __init__(self):
        self._ws = None
        self._connected = False
        self._text_callback: Callable[[str], Awaitable[None]] | None = None

    async def connect(self, on_text: Callable[[str], Awaitable[None]]):
        """
        建立WebSocket连接
        on_text: 识别文本回调
        """
        if not ALIYUN_ASR_APP_KEY:
            raise RuntimeError("ALIYUN_ASR_APP_KEY not configured")

        self._text_callback = on_text
        # 阿里云实时ASR WebSocket地址（具体URL需参考阿里云文档）
        # 此处为占位实现，实际对接时请替换为真实WebSocket URL
        try:
            import websockets
            url = (
                f"wss://nls-gateway-{ALIYUN_REGION}.aliyuncs.com/ws/v1"
                f"?appkey={ALIYUN_ASR_APP_KEY}"
            )
            self._ws = await websockets.connect(url)
            self._connected = True
            asyncio.create_task(self._recv_loop())
        except Exception as e:
            print(f"[AliyunASR] Connection failed: {e}")
            self._connected = False

    async def send_audio(self, pcm_base64: str):
        """发送PCM音频分片（base64编码）"""
        if not self._connected or self._ws is None:
            return
        try:
            # 阿里云ASR协议：发送音频二进制帧
            audio_bytes = base64.b64decode(pcm_base64)
            await self._ws.send(audio_bytes)
        except Exception as e:
            print(f"[AliyunASR] Send audio failed: {e}")

    async def _recv_loop(self):
        """接收识别结果"""
        if self._ws is None:
            return
        try:
            async for msg in self._ws:
                # 阿里云ASR返回JSON格式的识别结果
                try:
                    data = json.loads(msg) if isinstance(msg, str) else msg
                    if data.get("task_id") and data.get("result"):
                        text = data["result"].get("text", "")
                        if text and self._text_callback:
                            await self._text_callback(text)
                except Exception:
                    pass
        except Exception as e:
            print(f"[AliyunASR] Recv loop error: {e}")
        finally:
            self._connected = False

    async def close(self):
        self._connected = False
        if self._ws:
            await self._ws.close()
            self._ws = None
