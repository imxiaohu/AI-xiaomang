import 'dart:typed_data';

/// 单条对话消息
class ChatMessage {
  final String text;
  final bool isUser; // true=用户提问, false=AI回答
  final DateTime timestamp;
  final Uint8List? thumbnailBytes; // 提问时刻摄像头画面小图
  final Uint8List? audioBytes; // AI回答音频数据（云端TTS）

  const ChatMessage({
    required this.text,
    required this.isUser,
    required this.timestamp,
    this.thumbnailBytes,
    this.audioBytes,
  });
}
