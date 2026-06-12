// SSE消息类型定义
// 对应后端 SSE 下行事件类型

/// 文本分片事件
class SseTextChunk {
  final String text;
  final bool isFinal;

  const SseTextChunk({required this.text, required this.isFinal});
}

/// 音频分片事件（base64编码的MP3）
class SseAudioChunk {
  final String base64Audio;
  final int sampleIndex;

  const SseAudioChunk({required this.base64Audio, required this.sampleIndex});
}

/// 推理结束事件
class SseEnd {
  final String? fullText;
  final int totalAudioChunks;

  const SseEnd({this.fullText, required this.totalAudioChunks});
}

/// 心跳事件（每3秒一次）
class SseHeartbeat {
  final DateTime timestamp;

  const SseHeartbeat({required this.timestamp});
}

/// 错误事件
class SseError {
  final String code;
  final String message;

  const SseError({required this.code, required this.message});
}

/// 额度超限事件
class SseQuotaExceeded {
  final String reason;

  const SseQuotaExceeded({required this.reason});
}
