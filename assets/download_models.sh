#!/bin/bash
# AI小芒 模型下载脚本（开发/调试工具）
#
# 注意：自 2026-06 起，app 改为**运行时下载**到设备 Documents/models/ 目录。
# 本脚本仅供桌面端调试、CI 预下载、或向 iOS 模拟器注入模型时使用。
# 移动端 app 不读取 assets/models/，仅通过 HTTP 拉取。
#
# 用法: ./download_models.sh [hf|ms|auto]
#   hf     - 强制使用 HuggingFace
#   ms     - 强制使用魔搭社区
#   auto   - 自动选择（默认）：Vosk 走 alphacephei.com 一手，
#                            Qwen-VL GGUF 走魔搭（国内快）
#
# 环境变量:
#   HF_TOKEN         - HuggingFace Access Token
#   MS_TOKEN         - 魔搭社区 Access Token
#   HF_TOKEN_COOKIE  - HF 的完整 Cookie（绕过 WAF，更稳）
#   PROXY            - 代理地址（默认 http://127.0.0.1:7897）
set -e

ASSETS_DIR="$(cd "$(dirname "$0")" && pwd)"
MODELS_DIR="$ASSETS_DIR/models"
mkdir -p "$MODELS_DIR"
cd "$MODELS_DIR"

echo "============================================"
echo "AI小芒 模型下载脚本"
echo "目标目录: $MODELS_DIR"
echo "============================================"

# ----------------------------------------------------------------
# 代理配置（Clash 默认端口 7890/7897）
# ----------------------------------------------------------------
PROXY="${PROXY:-http://127.0.0.1:7897}"

check_proxy() {
    curl -sI --max-time 5 -x "$PROXY" "https://huggingface.co/" 2>/dev/null | grep -q "HTTP" && return 0 || return 1
}

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

resolve_source() {
    local model_name="$1"
    if [ "$USE_MS" = "auto" ]; then
        case "$model_name" in
            vosk)    echo "vosk" ;;   # 官方一手
            qwen*|mmproj*) echo "ms" ;; # 魔搭
            *)       echo "ms" ;;
        esac
    else
        [ "$USE_MS" = "true" ] && echo "ms" || echo "hf"
    fi
}

# ----------------------------------------------------------------
# 环境变量检查
# ----------------------------------------------------------------
if [ -z "$HF_TOKEN" ] && [ -z "$HF_TOKEN_COOKIE" ]; then
    echo "[提示] 未设置 HF_TOKEN / HF_TOKEN_COOKIE，将尝试匿名下载"
fi
if [ -z "$MS_TOKEN" ]; then
    echo "[提示] 未设置 MS_TOKEN，将使用匿名下载"
fi
echo ""

echo -n "[检测] 代理 $PROXY ... "
if check_proxy; then
    echo "可用 ✓"
    PROXY_AVAILABLE=true
else
    echo "不可用，将尝试直连"
    PROXY_AVAILABLE=false
fi
echo ""

BROWSER_UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36"

# ----------------------------------------------------------------
# 下载函数：wget 封装
# ----------------------------------------------------------------
download_with_retry() {
    local url="$1"
    local output="$2"
    local token="${3:-}"
    local cookie="${4:-}"
    local max_retry=3
    local retry=0

    while [ $retry -lt $max_retry ]; do
        local wget_args=("-q" "--timeout=120" "-O" "$output")
        if [ "$PROXY_AVAILABLE" = "true" ]; then
            wget_args+=("-e" "use_proxy=on" "-x" "$PROXY")
        fi
        wget_args+=("--header=User-Agent: $BROWSER_UA")
        if [ "$cookie" != "" ]; then
            wget_args+=("--header=Cookie: $cookie")
        elif [ "$token" != "" ]; then
            wget_args+=("--header=Authorization: Bearer $token")
        fi
        wget "${wget_args[@]}" "$url" && return 0
        retry=$((retry + 1))
        echo "  [重试] ($retry/$max_retry) $url"
        sleep 3
    done
    echo "  [失败] 下载失败: $url"
    return 1
}

# ----------------------------------------------------------------
# 文件校验
# ----------------------------------------------------------------
validate_download() {
    local file="$1"
    local expected_name="$2"
    if [ ! -f "$file" ]; then
        return 1
    fi
    local size_kb=$(du -k "$file" 2>/dev/null | cut -f1)
    if [ -z "$size_kb" ] || [ "$size_kb" -lt 1000 ]; then
        echo "  [错误] $expected_name 文件过小 (${size_kb}KB)，可能是 HTML 或错误页"
        rm -f "$file"
        return 1
    fi
    local magic=$(head -c 20 "$file" 2>/dev/null | xxd -p 2>/dev/null | head -c 40)
    if echo "$magic" | grep -q "^3c21444f435459"; then
        echo "  [错误] $expected_name 是 HTML 页面，未登录或被拦截"
        rm -f "$file"
        return 1
    fi
    if echo "$magic" | grep -q "^7b22"; then
        echo "  [错误] $expected_name 是 JSON 响应"
        rm -f "$file"
        return 1
    fi
    return 0
}

# ----------------------------------------------------------------
# 1) Vosk 中文小模型（多文件目录）
# ----------------------------------------------------------------
VOSK_DIR="vosk-model-small-cn-0.22"
VOSK_SIZE_ESTIMATED="40MB"
VOSK_URL="https://alphacephei.com/vosk/models/${VOSK_DIR}.zip"

echo "[1/3] 下载 Vosk 中文小模型 (${VOSK_SIZE_ESTIMATED})..."

if [ -d "$VOSK_DIR" ] && [ -f "$VOSK_DIR/README" ]; then
    echo "  ✓ $VOSK_DIR 已存在，跳过下载"
else
    echo "  [下载] $VOSK_URL"
    if download_with_retry "$VOSK_URL" "${VOSK_DIR}.zip"; then
        echo "  [解压] ${VOSK_DIR}.zip"
        if command -v unzip >/dev/null 2>&1; then
            unzip -q "${VOSK_DIR}.zip"
            rm -f "${VOSK_DIR}.zip"
            echo "  ✓ 解压完成: $VOSK_DIR"
        else
            echo "  [错误] 未找到 unzip，请先安装 (brew install unzip) 后手动解压 ${VOSK_DIR}.zip"
            exit 1
        fi
    else
        echo "  [错误] Vosk 模型下载失败"
        exit 1
    fi
fi

# ----------------------------------------------------------------
# 2) Qwen2-VL 主模型 GGUF
# ----------------------------------------------------------------
VL_FILE="Qwen2-VL-2B-Instruct-Q4_K_M.gguf"
VL_SIZE_ESTIMATED="0.99GB"

echo ""
echo "[2/3] 下载 Qwen2-VL-2B-Instruct GGUF (Q4_K_M, ${VL_SIZE_ESTIMATED})..."

if [ -f "$VL_FILE" ] && [ -s "$VL_FILE" ]; then
    echo "  ✓ $VL_FILE 已存在，跳过下载"
else
    VL_SRC=$(resolve_source "qwen")

    if [ "$VL_SRC" = "ms" ]; then
        MS_URL="https://www.modelscope.cn/models/bartowski/Qwen2-VL-2B-Instruct-GGUF/resolve/master/${VL_FILE}"
        echo "  [下载] 魔搭: $MS_URL"
        if download_with_retry "$MS_URL" "$VL_FILE" "$MS_TOKEN" ""; then
            if validate_download "$VL_FILE" "Qwen-VL GGUF"; then
                echo "  ✓ 下载完成: $VL_FILE"
            fi
        fi
    fi

    # 兜底 1: AI-ModelScope 镜像
    if [ ! -f "$VL_FILE" ] || [ ! -s "$VL_FILE" ]; then
        MS_URL_ALT="https://modelscope.cn/models/AI-ModelScope/Qwen2-VL-2B-Instruct-GGUF/resolve/master/${VL_FILE}"
        echo "  [备用] AI-ModelScope: $MS_URL_ALT"
        if download_with_retry "$MS_URL_ALT" "$VL_FILE" "$MS_TOKEN" ""; then
            validate_download "$VL_FILE" "Qwen-VL GGUF" && echo "  ✓ 下载完成: $VL_FILE"
        fi
    fi

    # 兜底 2: HuggingFace
    if [ ! -f "$VL_FILE" ] || [ ! -s "$VL_FILE" ]; then
        HF_URL="https://huggingface.co/bartowski/Qwen2-VL-2B-Instruct-GGUF/resolve/main/${VL_FILE}"
        echo "  [备用] HuggingFace: $HF_URL"
        if download_with_retry "$HF_URL" "$VL_FILE" "$HF_TOKEN" "$HF_TOKEN_COOKIE"; then
            validate_download "$VL_FILE" "Qwen-VL GGUF" && echo "  ✓ 下载完成: $VL_FILE"
        fi
    fi

    # 兜底 3: modelscope SDK
    if [ ! -f "$VL_FILE" ] || [ ! -s "$VL_FILE" ]; then
        echo "  [备用] modelscope SDK..."
        if python3 -c "
from modelscope import snapshot_download
snapshot_download('bartowski/Qwen2-VL-2B-Instruct-GGUF',
    allow_patterns='*Q4_K_M.gguf',
    cache_dir='/tmp/ms_qwen_gguf',
    local_dir='.')
" 2>/dev/null; then
            found=$(find /tmp/ms_qwen_gguf -name "*Q4_K_M.gguf" 2>/dev/null | head -1)
            if [ -n "$found" ] && [ -s "$found" ]; then
                cp "$found" "$VL_FILE"
                echo "  ✓ 从 SDK 缓存复制: $VL_FILE"
            fi
        fi
    fi

    if [ ! -f "$VL_FILE" ] || [ ! -s "$VL_FILE" ]; then
        echo "  [错误] Qwen-VL GGUF 下载失败"
        exit 1
    fi
fi

# ----------------------------------------------------------------
# 3) mmproj 视觉投影器（Qwen2-VL 多模态必需）
# ----------------------------------------------------------------
MMPROJ_FILE="mmproj-Qwen2-VL-2B-Instruct-f16.gguf"
MMPROJ_SIZE_ESTIMATED="1.3GB"

echo ""
echo "[3/3] 下载 mmproj 视觉投影器 (${MMPROJ_SIZE_ESTIMATED})..."

if [ -f "$MMPROJ_FILE" ] && [ -s "$MMPROJ_FILE" ]; then
    echo "  ✓ $MMPROJ_FILE 已存在，跳过下载"
else
    MMPROJ_SRC=$(resolve_source "mmproj")

    if [ "$MMPROJ_SRC" = "ms" ]; then
        MS_URL="https://www.modelscope.cn/models/bartowski/Qwen2-VL-2B-Instruct-GGUF/resolve/master/${MMPROJ_FILE}"
        echo "  [下载] 魔搭: $MS_URL"
        if download_with_retry "$MS_URL" "$MMPROJ_FILE" "$MS_TOKEN" ""; then
            validate_download "$MMPROJ_FILE" "mmproj GGUF" && echo "  ✓ 下载完成: $MMPROJ_FILE"
        fi
    fi

    # 兜底: HuggingFace
    if [ ! -f "$MMPROJ_FILE" ] || [ ! -s "$MMPROJ_FILE" ]; then
        HF_URL="https://huggingface.co/bartowski/Qwen2-VL-2B-Instruct-GGUF/resolve/main/${MMPROJ_FILE}"
        echo "  [备用] HuggingFace: $HF_URL"
        if download_with_retry "$HF_URL" "$MMPROJ_FILE" "$HF_TOKEN" "$HF_TOKEN_COOKIE"; then
            validate_download "$MMPROJ_FILE" "mmproj GGUF" && echo "  ✓ 下载完成: $MMPROJ_FILE"
        fi
    fi

    if [ ! -f "$MMPROJ_FILE" ] || [ ! -s "$MMPROJ_FILE" ]; then
        echo "  [错误] mmproj GGUF 下载失败"
        echo "  [提示] 视觉理解功能将不可用（纯文本对话仍可工作）"
    fi
fi

# ----------------------------------------------------------------
# 完成
# ----------------------------------------------------------------
echo ""
echo "============================================"
echo "模型下载完成！"
echo "============================================"
ls -lh models/*.gguf 2>/dev/null || ls -lh "$MODELS_DIR"/*.gguf 2>/dev/null || true
echo ""
echo "Vosk 模型目录:"
ls -la "$VOSK_DIR" 2>/dev/null | head -10 || true
