#!/bin/bash
# AI小芒模型下载脚本
# 支持 HuggingFace 和魔搭社区（ModelScope）两种下载源
# 用法: ./download_models.sh [hf|ms|auto]
#   hf     - 强制使用 HuggingFace
#   ms     - 强制使用魔搭社区
#   auto   - 自动选择（默认）：Whisper TFLite 用 HF，Qwen-VL GGUF 用魔搭
# 环境变量:
#   HF_TOKEN  - HuggingFace Access Token（用于私有模型）
#   MS_TOKEN  - 魔搭社区 Access Token（用于私有模型）

set -e

ASSETS_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ASSETS_DIR"

echo "============================================"
echo "AI小芒 模型下载脚本"
echo "============================================"

# ----------------------------------------------------------------
# 解析下载源参数
# ----------------------------------------------------------------
SOURCE="${1:-auto}"
case "$SOURCE" in
    hf)   USE_MS=false ;;
    ms)   USE_MS=true ;;
    auto) USE_MS=auto ;;
    *)    echo "[错误] 未知的下载源: $SOURCE"; exit 1 ;;
esac

# 自动选择策略: Whisper TFLite 用 HF，Qwen-VL GGUF 用魔搭
resolve_source() {
    local model_name="$1"
    if [ "$USE_MS" = "auto" ]; then
        case "$model_name" in
            whisper) echo "hf" ;;
            qwen*)   echo "ms" ;;
            *)       echo "ms" ;;
        esac
    else
        [ "$USE_MS" = "true" ] && echo "ms" || echo "hf"
    fi
}

# ----------------------------------------------------------------
# 环境变量检查
# ----------------------------------------------------------------
if [ -z "$HF_TOKEN" ]; then
    echo "[提示] 未设置 HF_TOKEN 环境变量，将使用匿名下载"
    echo "[提示] 部分模型需要登录后才能下载，请设置: export HF_TOKEN=your_token"
fi

if [ -z "$MS_TOKEN" ]; then
    echo "[提示] 未设置 MS_TOKEN 环境变量，将使用匿名下载"
    echo "[提示] 私有模型需要魔搭登录后获取 Token: export MS_TOKEN=your_token"
fi

echo ""

# ----------------------------------------------------------------
# 下载函数：wget 封装（支持重试）
# ----------------------------------------------------------------
download_with_retry() {
    local url="$1"
    local output="$2"
    local token="${3:-}"
    local max_retry=3
    local retry=0

    while [ $retry -lt $max_retry ]; do
        if [ -n "$token" ]; then
            wget -q --header="Authorization: Bearer $token" "$url" -O "$output" && return 0
        else
            wget -q "$url" -O "$output" && return 0
        fi
        retry=$((retry + 1))
        echo "  [重试] ($retry/$max_retry) $url"
        sleep 2
    done
    echo "  [失败] 下载失败: $url"
    return 1
}

# ----------------------------------------------------------------
# 模型信息
# ----------------------------------------------------------------

# 1. Whisper-tiny-int8 TFLite
WHISPER_FILE="whisper-tiny-int8.tflite"
WHISPER_SIZE_ESTIMATED="31MB"

# 2. Qwen2-VL-2B-Instruct GGUF (Q4_K_M)
VL_FILE="Qwen-VL-2B-Q4_K_M.gguf"
VL_SIZE_ESTIMATED="0.99GB"

# ----------------------------------------------------------------
# 下载 Whisper TFLite
# ----------------------------------------------------------------
echo "[1/2] 下载 Whisper-tiny-int8 TFLite (${WHISPER_SIZE_ESTIMATED})..."

if [ -f "$WHISPER_FILE" ] && [ -s "$WHISPER_FILE" ]; then
    echo "  ✓ $WHISPER_FILE 已存在，跳过下载 ($(du -h $WHISPER_FILE | cut -f1))"
else
    WHISPER_SRC=$(resolve_source "whisper")

    if [ "$WHISPER_SRC" = "ms" ]; then
        # 魔搭: 检查是否有等价镜像，兜底回 HF
        echo "  [提示] Whisper TFLite 在魔搭无官方镜像，尝试 HuggingFace..."

        HF_URL="https://huggingface.co/onnx-community/whisper-tiny-int8/resolve/main/whisper-tiny-int8.tflite"
        echo "  [下载] $HF_URL"

        if download_with_retry "$HF_URL" "$WHISPER_FILE" "$HF_TOKEN"; then
            actual_size=$(du -k "$WHISPER_FILE" 2>/dev/null | cut -f1)
            if [ "$actual_size" -lt 1000 ]; then
                echo "  [错误] 文件过小 (${actual_size}KB)，可能是 HTML 或错误页，删除后重试"
                rm -f "$WHISPER_FILE"
                exit 1
            fi
            echo "  ✓ 下载完成: $WHISPER_FILE ($(du -h $WHISPER_FILE | cut -f1))"
        else
            echo "  [错误] Whisper TFLite 下载失败"
            exit 1
        fi
    else
        # HuggingFace
        HF_URL="https://huggingface.co/onnx-community/whisper-tiny-int8/resolve/main/whisper-tiny-int8.tflite"
        echo "  [下载] $HF_URL"

        if download_with_retry "$HF_URL" "$WHISPER_FILE" "$HF_TOKEN"; then
            actual_size=$(du -k "$WHISPER_FILE" 2>/dev/null | cut -f1)
            if [ "$actual_size" -lt 1000 ]; then
                echo "  [错误] 文件过小 (${actual_size}KB)，可能是 HTML 或错误页，删除后重试"
                rm -f "$WHISPER_FILE"
                exit 1
            fi
            echo "  ✓ 下载完成: $WHISPER_FILE ($(du -h $WHISPER_FILE | cut -f1))"
        else
            echo "  [错误] Whisper TFLite 下载失败"
            exit 1
        fi
    fi
fi

# ----------------------------------------------------------------
# 下载 Qwen2-VL GGUF
# ----------------------------------------------------------------
echo ""
echo "[2/2] 下载 Qwen2-VL-2B-Instruct GGUF (Q4_K_M, ${VL_SIZE_ESTIMATED})..."

if [ -f "$VL_FILE" ] && [ -s "$VL_FILE" ]; then
    echo "  ✓ $VL_FILE 已存在，跳过下载 ($(du -h $VL_FILE | cut -f1))"
else
    VL_SRC=$(resolve_source "qwen")

    if [ "$VL_SRC" = "ms" ]; then
        # 魔搭社区
        MS_URL="https://www.modelscope.cn/models/bartowski/Qwen2-VL-2B-Instruct-GGUF/resolve/master/Qwen2-VL-2B-Instruct-Q4_K_M.gguf"
        echo "  [下载] $MS_URL"

        if download_with_retry "$MS_URL" "$VL_FILE" "$MS_TOKEN"; then
            actual_size=$(du -k "$VL_FILE" 2>/dev/null | cut -f1)
            if [ "$actual_size" -lt 1000 ]; then
                echo "  [错误] 文件过小 (${actual_size}KB)，可能是 HTML 或错误页，删除后重试"
                rm -f "$VL_FILE"
                exit 1
            fi
            echo "  ✓ 下载完成: $VL_FILE ($(du -h $VL_FILE | cut -f1))"
        else
            # 魔搭失败，尝试备用镜像
            MS_URL_ALT="https://modelscope.cn/models/AI-ModelScope/Qwen2-VL-2B-Instruct-GGUF/resolve/master/Qwen2-VL-2B-Instruct-Q4_K_M.gguf"
            echo "  [备用] 尝试 AI-ModelScope 镜像..."

        if download_with_retry "$MS_URL_ALT" "$VL_FILE" "$MS_TOKEN"; then
            actual_size=$(du -k "$VL_FILE" 2>/dev/null | cut -f1)
            if [ "$actual_size" -lt 1000 ]; then
                echo "  [错误] 文件过小 (${actual_size}KB)，可能是 HTML 或错误页"
                rm -f "$VL_FILE"
                exit 1
            fi
            echo "  ✓ 下载完成: $VL_FILE ($(du -h $VL_FILE | cut -f1))"
            else
                echo "  [警告] 魔搭下载失败，尝试 HuggingFace 兜底..."
                HF_URL="https://huggingface.co/bartowski/Qwen2-VL-2B-Instruct-GGUF/resolve/main/Qwen2-VL-2B-Instruct-Q4_K_M.gguf"

                if download_with_retry "$HF_URL" "$VL_FILE" "$HF_TOKEN"; then
                    actual_size=$(du -k "$VL_FILE" 2>/dev/null | cut -f1)
                    if [ "$actual_size" -lt 1000 ]; then
                        echo "  [错误] 文件过小 (${actual_size}KB)，可能是 HTML 或错误页"
                        rm -f "$VL_FILE"
                        exit 1
                    fi
                    echo "  ✓ 下载完成: $VL_FILE ($(du -h $VL_FILE | cut -f1))"
                else
                    echo "  [错误] Qwen-VL GGUF 下载失败（魔搭和 HuggingFace 均失败）"
                    exit 1
                fi
            fi
        fi
    else
        # HuggingFace
        HF_URL="https://huggingface.co/bartowski/Qwen2-VL-2B-Instruct-GGUF/resolve/main/Qwen2-VL-2B-Instruct-Q4_K_M.gguf"
        echo "  [下载] $HF_URL"

        if download_with_retry "$HF_URL" "$VL_FILE" "$HF_TOKEN"; then
            echo "  ✓ 下载完成: $VL_FILE ($(du -h $VL_FILE | cut -f1))"
        else
            # HF 失败，尝试魔搭兜底
            echo "  [警告] HuggingFace 下载失败，尝试魔搭社区..."
            MS_URL="https://www.modelscope.cn/models/bartowski/Qwen2-VL-2B-Instruct-GGUF/resolve/master/Qwen2-VL-2B-Instruct-Q4_K_M.gguf"

            if download_with_retry "$MS_URL" "$VL_FILE" "$MS_TOKEN"; then
                echo "  ✓ 下载完成: $VL_FILE ($(du -h $VL_FILE | cut -f1))"
            else
                echo "  [错误] Qwen-VL GGUF 下载失败（HuggingFace 和魔搭均失败）"
                exit 1
            fi
        fi
    fi
fi

# ----------------------------------------------------------------
# 完成
# ----------------------------------------------------------------
echo ""
echo "============================================"
echo "模型下载完成！"
echo "============================================"
ls -lh *.tflite *.gguf 2>/dev/null || true
