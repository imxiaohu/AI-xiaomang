import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// 音频录制服务
/// 固定16KHz、mono、PCM格式，每200ms封装一个分片，base64编码后HTTP上传
class AudioRecorderService {
  // 固定16KHz采样率（record插件实际使用时配置）
  static const int _chunkDurationMs = 200;
  static const int _maxChunkSizeBytes = 32 * 1024; // 32KB

  final String baseUrl;
  final String sessionId;

  http.Client? _client;
  bool _isRecording = false;
  Timer? _chunkTimer;
  final List<Int16List> _buffer = [];

  // 回调
  Function(Uint8List chunk, int durationMs)? onChunkReady;
  VoidCallback? onRecordingStart;
  VoidCallback? onRecordingStop;
  Function(String error)? onError;

  AudioRecorderService({required this.baseUrl, required this.sessionId});

  bool get isRecording => _isRecording;

  /// 开始录音（平台相关实现需注入 Record 插件）
  /// 此处为骨架：实际调用 record 插件的 start() 方法
  Future<void> startRecording() async {
    if (_isRecording) return;
    _client = http.Client();
    _buffer.clear();
    _isRecording = true;
    onRecordingStart?.call();

    // 每200ms封装一次分片（实际由 record 插件触发）
    _chunkTimer = Timer.periodic(
      const Duration(milliseconds: _chunkDurationMs),
      (_) => _flushChunk(),
    );
  }

  /// 喂入PCM数据（由 record 插件回调）
  void feedPcmData(Int16List pcmData) {
    if (!_isRecording) return;
    _buffer.add(pcmData);

    // 超限保护：超过32KB直接丢弃最早分片
    int totalBytes = _buffer.fold(0, (sum, chunk) => sum + chunk.length * 2);
    while (totalBytes > _maxChunkSizeBytes && _buffer.length > 1) {
      final removed = _buffer.removeAt(0);
      totalBytes -= removed.length * 2;
    }
  }

  void _flushChunk() {
    if (!_isRecording || _buffer.isEmpty) return;

    // 合并缓冲区
    int totalSamples = _buffer.fold(0, (sum, chunk) => sum + chunk.length);
    final merged = Int16List(totalSamples);
    int offset = 0;
    for (final chunk in _buffer) {
      merged.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    _buffer.clear();

    final bytes = Uint8List.fromList(merged.buffer.asUint8List());
    final encoded = base64Encode(bytes);
    onChunkReady?.call(bytes, _chunkDurationMs);

    // HTTP上传
    _uploadChunk(encoded);
  }

  Future<void> _uploadChunk(String base64Audio) async {
    if (_client == null) return;
    try {
      await _client!.post(
        Uri.parse('$baseUrl/upload/audio_chunk'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'ctxId': sessionId, 'audio': base64Audio}),
      );
    } catch (e) {
      onError?.call('音频分片上传失败: $e');
    }
  }

  /// 结束录音
  Future<void> stopRecording() async {
    if (!_isRecording) return;
    _isRecording = false;
    _chunkTimer?.cancel();
    _chunkTimer = null;

    // 发送结束标识
    try {
      await _client?.post(
        Uri.parse('$baseUrl/upload/audio_chunk'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'ctxId': sessionId, 'audio': '', 'end': true}),
      );
    } catch (_) {}

    _client?.close();
    _client = null;
    onRecordingStop?.call();
  }

  void dispose() {
    stopRecording();
  }
}

