#!/bin/bash
# AI小芒模型下载脚本
# 用法: ./download_models.sh
# 需要 HuggingFace 账号和登录 token

set -e

ASSETS_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ASSETS_DIR"

echo "============================================"
echo "AI小芒 模型下载脚本"
echo "============================================"

# 检查 HuggingFace token
if [ -z "$HF_TOKEN" ]; then
    echo "[提示] 未设置 HF_TOKEN 环境变量，将使用匿名下载"
    echo "[提示] 部分模型需要登录后才能下载，请设置: export HF_TOKEN=your_token"
    echo ""
fi

# 1. 下载 Whisper-tiny-int8 TFLite
echo "[1/2] 下载 Whisper-tiny-int8 TFLite..."
WHISPER_FILE="whisper-tiny-int8.tflite"
if [ -f "$WHISPER_FILE" ]; then
    echo "  ✓ $WHISPER_FILE 已存在，跳过下载"
else
    if [ -n "$HF_TOKEN" ]; then
        wget -q --header="Authorization: Bearer $HF_TOKEN" \
            "https://huggingface.co/onnx-community/whisper-tiny-int8/resolve/main/whisper-tiny-int8.tflite" \
            -O "$WHISPER_FILE"
    else
        wget -q "https://huggingface.co/onnx-community/whisper-tiny-int8/resolve/main/whisper-tiny-int8.tflite" \
            -O "$WHISPER_FILE"
    fi
    echo "  ✓ 下载完成: $WHISPER_FILE ($(du -h $WHISPER_FILE | cut -f1))"
fi

# 2. 下载 Qwen2-VL-1.8B Q4_K_M GGUF
echo "[2/2] 下载 Qwen2-VL-1.8B-Instruct GGUF (Q4_K_M 量化)..."
VL_FILE="Qwen-VL-1.8B-Q4_K_M.gguf"
if [ -f "$VL_FILE" ]; then
    echo "  ✓ $VL_FILE 已存在，跳过下载"
else
    if [ -n "$HF_TOKEN" ]; then
        wget -q --header="Authorization: Bearer $HF_TOKEN" \
            "https://huggingface.co/Qwen/Qwen2-VL-1.8B-Instruct-GGUF/resolve/main/qwen2-vl-1.8b-instruct-q4_k_m.gguf" \
            -O "$VL_FILE"
    else
        wget -q "https://huggingface.co/Qwen/Qwen2-VL-1.8B-Instruct-GGUF/resolve/main/qwen2-vl-1.8b-instruct-q4_k_m.gguf" \
            -O "$VL_FILE"
    fi
    echo "  ✓ 下载完成: $VL_FILE ($(du -h $VL_FILE | cut -f1))"
fi

echo ""
echo "============================================"
echo "模型下载完成！"
echo "============================================"
ls -lh *.tflite *.gguf 2>/dev/null || true
