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

# 额度管控
DAILY_TTS_QUOTA = float(os.getenv('DAILY_TTS_QUOTA', '10.0'))

# 会话配置
SESSION_TIMEOUT = int(os.getenv('SESSION_TIMEOUT', '600'))
SSE_HEARTBEAT_INTERVAL = int(os.getenv('SSE_HEARTBEAT_INTERVAL', '3'))
MAX_CONTEXT_ROUNDS = int(os.getenv('MAX_CONTEXT_ROUNDS', '10'))

# 开发模式
DEBUG = os.getenv('DEBUG', 'false').lower() == 'true'
