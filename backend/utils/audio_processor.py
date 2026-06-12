"""工具函数"""
import base64


def decode_audio(audio_b64: str) -> bytes:
    """base64解码音频"""
    return base64.b64decode(audio_b64)


def encode_audio(audio_bytes: bytes) -> str:
    """音频base64编码"""
    return base64.b64encode(audio_bytes).decode()
