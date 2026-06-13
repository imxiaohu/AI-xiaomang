"""应用配置，从环境变量加载"""
import os
from dotenv import load_dotenv

load_dotenv()

# 阿里云凭证
ALIYUN_ACCESS_KEY_ID = os.getenv('ALIYUN_ACCESS_KEY_ID', '')
ALIYUN_ACCESS_KEY_SECRET = os.getenv('ALIYUN_ACCESS_KEY_SECRET', '')
ALIYUN_REGION = os.getenv('ALIYUN_REGION', 'cn-shanghai')

# ASR
ALIYUN_ASR_APP_KEY = os.getenv('ALIYUN_ASR_APP_KEY', '')

# 通义千问VL
DASHSCOPE_API_KEY = os.getenv('DASHSCOPE_API_KEY', '')

# 系统提示词（用于显式上下文缓存标记）
# 占位符 {round} 会替换为当前对话轮次
SYSTEM_PROMPT = os.getenv(
    'SYSTEM_PROMPT',
    '你是一位多模态AI助手，拥有视觉理解能力。你可以看图说话、回答问题、进行有深度的分析。',
)

# TTS
ALIYUN_TTS_APP_KEY = os.getenv('ALIYUN_TTS_APP_KEY', '')

# Qwen-TTS 模型和音色（默认 qwen3-tts-flash-realtime + Cherry）
# 模型列表：qwen3-tts-flash-realtime / qwen-tts-realtime / qwen3-tts-instruct-flash-realtime
# 音色列表（支持中文方言）：
#   中文普通话：Cherry(芊悦), Serena(苏瑶), Ethan(晨煦), Chelsie(千雪), Momo(茉兔),
#             Vivian(十三), Moon(月白), Maia(四月), Kai(凯), Nofish(不吃鱼),
#             Bella(萌宝), Jennifer(詹妮弗), Ryan(甜茶), Katerina(卡捷琳娜),
#             Aiden(艾登), Eldric Sage(沧明子), Mia(乖小妹), Mochi(沙小弥),
#             Bellona(燕铮莺), Vincent(田叔), Bunny(萌小姬), Neil(阿闻),
#             Elias(墨讲师), Arthur(徐大爷), Nini(邻家妹妹), Seren(小婉),
#             Pip(顽屁小孩), Stella(少女阿月)
#   中文方言：Jada(上海阿珍), Dylan(北京晓东), Li(南京老李), Marcus(陕西秦川),
#            Roy(闽南阿杰), Peter(天津李彼得), Sunny(四川晴儿), Eric(四川程川),
#            Rocky(粤语阿强), Kiki(粤语阿清)
TTS_MODEL = os.getenv('TTS_MODEL', 'qwen3-tts-flash-realtime')
TTS_VOICE = os.getenv('TTS_VOICE', 'Cherry')

# ── Qwen-Omni-Realtime（一体化实时音视频，OMNI_MODE=true 时启用）─────
# Omni 模型：qwen3.5-omni-plus-realtime / qwen3.5-omni-flash-realtime
# 注意：voice 参数必须与模型系列匹配
#   - qwen3.5-omni-*-realtime：默认 Tina，可选 Tina/Serena/Cindy/Ethan/Momo
#   - qwen3-omni-flash-realtime：默认 Cherry，可选 Cherry/Serena/Ethan/Chelsie/Momo
#   - qwen-omni-turbo-realtime：默认 Chelsie
OMNI_MODE = os.getenv('OMNI_MODE', 'false').lower() == 'true'
OMNI_MODEL = os.getenv('OMNI_MODEL', 'qwen3.5-omni-flash-realtime')
# ⚠️ 修复：3.5 系列不支持 Cherry，runtime 报 "Voice 'Cherry' is not supported"
OMNI_VOICE = os.getenv('OMNI_VOICE', 'Tina')
OMNI_INSTRUCTIONS = os.getenv(
    'OMNI_INSTRUCTIONS',
    '你是一位友好的AI助手，名叫小芒。你能用视觉理解图像，能用语音自然对话。请始终用中文回答。',
)

# 额度管控
DAILY_TTS_QUOTA = float(os.getenv('DAILY_TTS_QUOTA', '10.0'))

# 会话配置
SESSION_TIMEOUT = int(os.getenv('SESSION_TIMEOUT', '600'))
SSE_HEARTBEAT_INTERVAL = int(os.getenv('SSE_HEARTBEAT_INTERVAL', '3'))
MAX_CONTEXT_ROUNDS = int(os.getenv('MAX_CONTEXT_ROUNDS', '10'))

# 开发模式
DEBUG = os.getenv('DEBUG', 'false').lower() == 'true'

# 3D 形象市场
# 新生成 3D 模型的默认可见性：public（公开） | unlisted | private
DEFAULT_MODEL_VISIBILITY = os.getenv('DEFAULT_MODEL_VISIBILITY', 'public')

# 测试模式（跳过认证校验，方便本地/测试环境联调）
# true=不校验 token，false=校验 token
TEST_MODE = os.getenv('TEST_MODE', 'false').lower() == 'true'

# ════════════════════════════════════════════════════════════════════
#  离线模型下载（端侧 ASR/VL 模型的统一分发入口）
# ════════════════════════════════════════════════════════════════════
#
#  客户端通过 GET /models/manifest 拉取模型清单（带版本号），
#  再用 GET /models/{name} 流式下载（支持 Range 断点续传 + 磁盘缓存 + 上游透传）。
#
#  流程：客户端 → 后端 → （首次）上游 ModelScope/HuggingFace → 缓存到磁盘
#                       （后续）直接读磁盘返回
#
#  当任一模型更新（量化方案、mmproj 版本等），只需：
#   1) 把新文件放到 CACHE_DIR
#   2) 更新 MODEL_REGISTRY 里的 version
#   3) 客户端下次启动会因 manifest 哈希变化自动重下

MODELS_CACHE_DIR = os.getenv(
    'MODELS_CACHE_DIR',
    # 默认 <backend>/models_cache/offline_models
    # 注意：models_cache/ 下还有 tripo 3D 的临时文件，必须用子目录隔离
    os.path.join(os.path.dirname(os.path.abspath(__file__)), 'models_cache', 'offline_models'),
)

# ════════════════════════════════════════════════════════════════════
#  本地预置模型目录（最高优先级，零延迟、零流量）
# ════════════════════════════════════════════════════════════════════
#
#  与运行时下载缓存（MODELS_CACHE_DIR）的区别：
#    - assets/models/：随代码仓库发布或运维手动放置的"出厂预置"模型
#    - models_cache/：运行时由后端从上游拉取的下载缓存
#
#  客户端请求解析路径（model_download.py）：
#    1) assets/models/<local_assets_filename>  ← 命中则直接 serve（最高优）
#    2) models_cache/offline_models/<name>.bin  ← 命中则 serve 缓存
#    3) 上游 ModelScope / HuggingFace  ← 兜底：边下边写边回传
#
#  注意 local_assets_filename 字段：assets/ 下用的是原文件名
#  （如 Qwen2-VL-2B-Instruct-Q4_K_M.gguf），不是 name.bin；
#  后端负责做映射。
MODELS_ASSETS_DIR = os.getenv(
    'MODELS_ASSETS_DIR',
    # 默认 <backend>/assets/models/（与项目自带模型目录一致）
    os.path.join(os.path.dirname(os.path.abspath(__file__)), 'assets', 'models'),
)

# 公开给客户端的模型清单（key = 客户端请求的 name）
# 每次模型文件更新，把 version 字符串改一下即可
# local_assets_filename：assets/models/ 下的实际文件名（缺失则视为"未预置"）
MODEL_REGISTRY: dict = {
    'vosk-cn': {
        'kind': 'zip',  # 客户端需要解压
        'version': '0.22',
        'size': 40 * 1024 * 1024,  # 约 40MB（zip 包）
        'extracted_size': 42 * 1024 * 1024,  # 解压后约 42MB
        'sha256_hint': '',  # 客户端可选校验
        'local_assets_filename': 'vosk-model-small-cn-0.22.zip',  # 预置 zip（未提供则用目录）
        'upstream_urls': [
            'https://alphacephei.com/vosk/models/vosk-model-small-cn-0.22.zip',
        ],
    },
    'qwen-vl-q4km': {
        'kind': 'gguf',
        'version': 'Q4_K_M',
        'size': 940 * 1024 * 1024,  # 约 940MB
        'sha256_hint': '',
        'local_assets_filename': 'Qwen2-VL-2B-Instruct-Q4_K_M.gguf',  # 仓库自带的原文件名
        'upstream_urls': [
            # 优先魔搭（国内快）
            'https://www.modelscope.cn/models/bartowski/Qwen2-VL-2B-Instruct-GGUF/resolve/main/Qwen2-VL-2B-Instruct-Q4_K_M.gguf',
            'https://huggingface.co/bartowski/Qwen2-VL-2B-Instruct-GGUF/resolve/main/Qwen2-VL-2B-Instruct-Q4_K_M.gguf',
        ],
    },
    'qwen-vl-mmproj-f16': {
        'kind': 'gguf',
        'version': 'f16',
        'size': 1.2 * 1024 * 1024 * 1024,  # 约 1.2GB
        'sha256_hint': '',
        'local_assets_filename': 'mmproj-Qwen2-VL-2B-Instruct-f16.gguf',
        'upstream_urls': [
            'https://www.modelscope.cn/models/bartowski/Qwen2-VL-2B-Instruct-GGUF/resolve/main/mmproj-Qwen2-VL-2B-Instruct-f16.gguf',
            'https://huggingface.co/bartowski/Qwen2-VL-2B-Instruct-GGUF/resolve/main/mmproj-Qwen2-VL-2B-Instruct-f16.gguf',
        ],
    },
}

# 整体清单版本（客户端用这个判断要不要重下 manifest）
MANIFEST_VERSION = os.getenv('OFFLINE_MODELS_MANIFEST_VERSION', '2026-06-14.1')
