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
#   PROXY     - 代理地址（默认: http://127.0.0.1:7897）
#   HF_TOKEN_COOKIE - HF 的完整 Cookie（用于绕过 WAF）
#                 获取方法: 浏览器登录 HF 后，在 DevTools -> Application -> Cookies 复制完整的 cookie 字符串
set -e

ASSETS_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ASSETS_DIR"

echo "============================================"
echo "AI小芒 模型下载脚本"
echo "============================================"

# ----------------------------------------------------------------
# 代理配置（Clash 类代理默认端口 7890/7897）
# ----------------------------------------------------------------
PROXY="${PROXY:-http://127.0.0.1:7897}"
PROXY_HOST="$(echo "$PROXY" | sed 's|http://||; s|https://||')"

# 检测代理是否可用（通过 curl 代理 HEAD 请求）
check_proxy() {
    curl -sI --max-time 5 -x "$PROXY" "https://huggingface.co/" 2>/dev/null | grep -q "HTTP" && return 0 || return 1
}

# 检测是否有 HF Token Cookie（比 Bearer Token 更有效绕过 WAF）
HAS_COOKIE=false
if [ -n "$HF_TOKEN_COOKIE" ]; then
    HAS_COOKIE=true
fi

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
if [ -z "$HF_TOKEN" ] && [ -z "$HF_TOKEN_COOKIE" ]; then
    echo "[提示] 未设置 HF_TOKEN 和 HF_TOKEN_COOKIE，将尝试匿名下载"
    echo "[提示] 部分模型需要登录后才能下载"
    echo "[提示] 推荐: export HF_TOKEN_COOKIE='从浏览器复制的完整 cookie'"
fi

if [ -z "$MS_TOKEN" ]; then
    echo "[提示] 未设置 MS_TOKEN 环境变量，将使用匿名下载"
fi

echo ""

# ----------------------------------------------------------------
# 代理检测与提示
# ----------------------------------------------------------------
echo -n "[检测] 代理 $PROXY ... "
if check_proxy; then
    echo "可用 ✓"
    PROXY_AVAILABLE=true
else
    echo "不可用，将尝试直连"
    PROXY_AVAILABLE=false
fi

echo ""

# ----------------------------------------------------------------
# 浏览器 UA（用于绕过 HF WAF）
# ----------------------------------------------------------------
BROWSER_UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36"

# ----------------------------------------------------------------
# 下载函数：wget 封装（支持重试、代理、Cookie）
# ----------------------------------------------------------------
download_with_retry() {
    local url="$1"
    local output="$2"
    local token="${3:-}"
    local cookie="${4:-}"
    local max_retry=3
    local retry=0

    while [ $retry -lt $max_retry ]; do
        local wget_args=("-q" "--timeout=60" "-O" "$output")

        # 代理（-x 设置代理，http_proxy 环境变量兜底）
        if [ "$PROXY_AVAILABLE" = "true" ]; then
            wget_args+=("-x" "$PROXY")
        fi

        # User-Agent
        wget_args+=("--header=User-Agent: $BROWSER_UA")

        # Cookie（优先，比 Bearer Token 更有效绕过 WAF）
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
# 模型信息
# ----------------------------------------------------------------

# 1. Whisper-tiny-int8 TFLite
WHISPER_FILE="whisper-tiny-transcribe-translate.tflite"
WHISPER_SIZE_ESTIMATED="42MB"

# 2. Qwen2-VL-2B-Instruct GGUF (Q4_K_M)
VL_FILE="Qwen-VL-2B-Q4_K_M.gguf"
VL_SIZE_ESTIMATED="0.99GB"

# ----------------------------------------------------------------
# 文件校验：确保下载的是二进制文件而非 HTML
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
    # 检查文件头魔数，排除 HTML/XML/JSON
    local magic=$(head -c 20 "$file" 2>/dev/null | xxd -p 2>/dev/null | head -c 40)
    if echo "$magic" | grep -q "^3c21444f435459"; then  # "<!DOCT" HTML
        echo "  [错误] $expected_name 是 HTML 页面，未登录或被拦截"
        rm -f "$file"
        return 1
    fi
    if echo "$magic" | grep -q "^7b22"; then  # "{\" JSON
        echo "  [错误] $expected_name 是 JSON 响应（可能 API 错误）"
        rm -f "$file"
        return 1
    fi
    return 0
}

# ----------------------------------------------------------------
# 下载 Whisper TFLite
# ----------------------------------------------------------------
echo "[1/2] 下载 Whisper-tiny-transcribe-translate TFLite (${WHISPER_SIZE_ESTIMATED})..."

if [ -f "$WHISPER_FILE" ] && [ -s "$WHISPER_FILE" ]; then
    echo "  ✓ $WHISPER_FILE 已存在，跳过下载 ($(du -h $WHISPER_FILE | cut -f1))"
else
    WHISPER_SRC=$(resolve_source "whisper")

    if [ "$WHISPER_SRC" = "hf" ] || [ "$WHISPER_SRC" = "ms" ]; then
        # 优先 HF（Whisper TFLite 在魔搭无官方镜像）
        # 正确地址: DocWolle/whisper_tflite_models（多语言，完整 transcribe+translate 功能）
        # 已弃用: onnx-community/whisper-tiny-int8 不存在（404）
        HF_URL="https://huggingface.co/DocWolle/whisper_tflite_models/resolve/main/whisper-tiny-transcribe-translate.tflite"
        echo "  [下载] HF: $HF_URL"

        if download_with_retry "$HF_URL" "$WHISPER_FILE" "$HF_TOKEN" "$HF_TOKEN_COOKIE"; then
            if validate_download "$WHISPER_FILE" "Whisper TFLite"; then
                echo "  ✓ 下载完成: $WHISPER_FILE ($(du -h $WHISPER_FILE | cut -f1))"
            else
                # Cookie/Token 方式失败，尝试模型scope（兜底）
                echo "  [警告] HF 下载结果无效，尝试 ModelScope 兜底..."
                rm -f "$WHISPER_FILE"
                try_ms_whisper=false
            fi
        else
            echo "  [警告] HF 下载失败，尝试 ModelScope 兜底..."
            try_ms_whisper=false
        fi
    fi

    # 兜底：魔搭（虽然 openai-mirror/whisper-tiny 没有 tflite，但作为备用提示）
    if [ ! -f "$WHISPER_FILE" ] || [ ! -s "$WHISPER_FILE" ]; then
        echo "  [提示] Whisper TFLite 在魔搭无官方镜像"
        echo "  [提示] 方案 A: 设置 HF_TOKEN_COOKIE 环境变量（从浏览器复制完整 Cookie）"
        echo "  [提示] 方案 B: 手动下载: https://huggingface.co/DocWolle/whisper_tflite_models"
        echo "  [提示] 方案 C: 使用 hf download: DocWolle/whisper_tflite_models --include whisper-tiny-transcribe-translate.tflite"

        # 尝试用 Python + modelscope SDK 下载
        echo "  [尝试] 通过 modelscope SDK 搜索替代模型..."
        if python3 -c "
from modelscope import snapshot_download
snapshot_download('openai-mirror/whisper-tiny', allow_patterns='*.tflite', cache_dir='/tmp/ms_whisper_tflite', local_dir='.')
" 2>/dev/null | grep -q "tflite"; then
            echo "  ✓ 找到 tflite 文件"
        fi

        if [ ! -f "$WHISPER_FILE" ] || [ ! -s "$WHISPER_FILE" ]; then
            echo "  [错误] Whisper TFLite 下载失败，请手动处理"
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
        # 魔搭社区（主力源）
        MS_URL="https://www.modelscope.cn/models/bartowski/Qwen2-VL-2B-Instruct-GGUF/resolve/master/Qwen2-VL-2B-Instruct-Q4_K_M.gguf"
        echo "  [下载] 魔搭: $MS_URL"

        if download_with_retry "$MS_URL" "$VL_FILE" "$MS_TOKEN" ""; then
            if validate_download "$VL_FILE" "Qwen-VL GGUF"; then
                echo "  ✓ 下载完成: $VL_FILE ($(du -h $VL_FILE | cut -f1))"
            fi
        fi
    fi

    # 兜底 1: AI-ModelScope 镜像
    if [ ! -f "$VL_FILE" ] || [ ! -s "$VL_FILE" ]; then
        MS_URL_ALT="https://modelscope.cn/models/AI-ModelScope/Qwen2-VL-2B-Instruct-GGUF/resolve/master/Qwen2-VL-2B-Instruct-Q4_K_M.gguf"
        echo "  [备用] 尝试 AI-ModelScope 镜像..."
        if download_with_retry "$MS_URL_ALT" "$VL_FILE" "$MS_TOKEN" ""; then
            if validate_download "$VL_FILE" "Qwen-VL GGUF"; then
                echo "  ✓ 下载完成: $VL_FILE ($(du -h $VL_FILE | cut -f1))"
            fi
        fi
    fi

    # 兜底 2: HuggingFace
    if [ ! -f "$VL_FILE" ] || [ ! -s "$VL_FILE" ]; then
        HF_URL="https://huggingface.co/bartowski/Qwen2-VL-2B-Instruct-GGUF/resolve/main/Qwen2-VL-2B-Instruct-Q4_K_M.gguf"
        echo "  [备用] 尝试 HuggingFace: $HF_URL"
        if download_with_retry "$HF_URL" "$VL_FILE" "$HF_TOKEN" "$HF_TOKEN_COOKIE"; then
            if validate_download "$VL_FILE" "Qwen-VL GGUF"; then
                echo "  ✓ 下载完成: $VL_FILE ($(du -h $VL_FILE | cut -f1))"
            fi
        fi
    fi

    # 兜底 3: modelscope SDK
    if [ ! -f "$VL_FILE" ] || [ ! -s "$VL_FILE" ]; then
        echo "  [备用] 尝试 modelscope SDK..."
        if python3 -c "
from modelscope import snapshot_download
snapshot_download('bartowski/Qwen2-VL-2B-Instruct-GGUF',
    allow_patterns='*Q4_K_M.gguf',
    cache_dir='/tmp/ms_qwen_gguf',
    local_dir='.')
" 2>/dev/null; then
            # SDK 可能下载到缓存目录，需要找到文件
            found=$(find /tmp/ms_qwen_gguf -name "*Q4_K_M.gguf" 2>/dev/null | head -1)
            if [ -n "$found" ] && [ -s "$found" ]; then
                cp "$found" "$VL_FILE"
                echo "  ✓ 从缓存复制: $VL_FILE ($(du -h $VL_FILE | cut -f1))"
            fi
        fi
    fi

    # 最终检查
    if [ ! -f "$VL_FILE" ] || [ ! -s "$VL_FILE" ]; then
        echo "  [错误] Qwen-VL GGUF 下载失败"
        echo "  [提示] 模型约 1GB，下载慢可耐心等待"
        exit 1
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
