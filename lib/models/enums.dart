/// AI全局运行模式
enum AppRunMode {
  offlineLocal, // 离线本地模式: Whisper + Qwen-VL
  cloudAliyun, // 阿里云云端模式: 阿里云VL/TTS
}

/// AI球体交互状态（控制动效、文案、球体样式）
enum AiStatus {
  idle, // 空闲待机
  listening, // 聆听收音
  thinking, // 模型推理思考
  speaking, // TTS播报回答
}

/// 自动降级等级
enum AiDegradationLevel {
  full, // 全功能：3D球体 + 视觉模型 + 云端/离线全链路
  reduced, // 降级版：2D球体 + 语音模型 + 视觉模型禁用
  minimal, // 最小版：2D球体 + 仅语音对话（Qwen-VL完全禁用）
}

/// SSE连接状态
enum ConnectionStatus {
  connected, // 已连接
  reconnecting, // 重新连接中
  disconnected, // 断开
  error, // 异常
}
