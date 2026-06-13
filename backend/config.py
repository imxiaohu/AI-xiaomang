"""应用配置，从环境变量加载"""
import os
from dotenv import load_dotenv

load_dotenv()

# 百炼平台 API Key（VL / TTS / ASR / Omni 全量服务共用此 Key）
# 获取路径：阿里云百炼控制台 → API-KEY 管理
# 网址：https://bailian.console.aliyun.com/
DASHSCOPE_API_KEY = os.getenv('DASHSCOPE_API_KEY', '')

# 阿里云区域（百炼服务部署区域）
ALIYUN_REGION = os.getenv('ALIYUN_REGION', 'cn-shanghai')

# 系统提示词（用于显式上下文缓存标记）
# 占位符 {round} 会替换为当前对话轮次
SYSTEM_PROMPT = os.getenv(
    'SYSTEM_PROMPT',
    '你是一位多模态AI助手，拥有视觉理解能力。你可以看图说话、回答问题、进行有深度的分析。',
)

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
# Omni 音色：同 TTS_VOICE 音色列表
# 注意：OMNI_MODE=true 时覆盖 VL+TTS 分离模式，Omni 更智能但费用更高
OMNI_MODE = os.getenv('OMNI_MODE', 'false').lower() == 'true'
OMNI_MODEL = os.getenv('OMNI_MODEL', 'qwen3.5-omni-flash-realtime')
OMNI_VOICE = os.getenv('OMNI_VOICE', 'Cherry')
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
