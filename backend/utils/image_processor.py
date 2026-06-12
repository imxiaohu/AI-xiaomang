"""工具函数"""
import base64


def decode_image(image_b64: str) -> bytes:
    """base64解码图像"""
    return base64.b64decode(image_b64)


def encode_image(image_bytes: bytes) -> str:
    """图像base64编码"""
    return base64.b64encode(image_bytes).decode()
