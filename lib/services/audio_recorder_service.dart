import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:flutter/foundation.dart';

/// 音频录制服务
/// 固定16KHz、mono、PCM格式，每200ms封装一个分片，base64编码后HTTP上传
/// 录音结束后将PCM数据写入临时文件，供Whisper ASR使用
class AudioRecorderService {
  static const int _chunkDurationMs = 200;

  final String baseUrl;
  final String sessionId;

  final AudioRecorder _recorder = AudioRecorder();
  Timer? _chunkTimer;
  http.Client? _httpClient;
  bool _isRecording = false;
  File? _pcmFile;
  IOSink? _pcmSink;

  // 回调
  void Function(Uint8List chunk, int durationMs)? onChunkReady;
  VoidCallback? onRecordingStart;
  VoidCallback? onRecordingStop;
  void Function(String error)? onError;

  AudioRecorderService({required this.baseUrl, required this.sessionId});

  bool get isRecording => _isRecording;

  /// 获取最近一次录制的完整 PCM 数据
  /// 供离线模式 Whisper ASR 使用
  Future<Uint8List?> getLatestPcmData() async {
    if (_pcmFile == null || !await _pcmFile!.exists()) return null;
    try {
      final bytes = await _pcmFile!.readAsBytes();
      await _pcmFile!.delete();
      _pcmFile = null;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// 开始录音
  Future<void> startRecording() async {
    if (_isRecording) return;

    if (!await _recorder.hasPermission()) {
      onError?.call('麦克风权限未授权');
      return;
    }

    _httpClient = http.Client();

    // 创建临时PCM文件（用于Whisper）
    final dir = await getTemporaryDirectory();
    _pcmFile = File('${dir.path}/recording_${DateTime.now().millisecondsSinceEpoch}.pcm');
    _pcmSink = _pcmFile!.openWrite();

    // 16KHz mono PCM：每秒 32000 字节
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 256000,
      ),
      path: _pcmFile!.path,
    );

    _isRecording = true;
    onRecordingStart?.call();

    // 每200ms读一次文件内容并上传
    _chunkTimer = Timer.periodic(
      const Duration(milliseconds: _chunkDurationMs),
      (_) => _flushChunk(),
    );
  }

  Future<void> _flushChunk() async {
    if (!_isRecording || _pcmFile == null) return;
    try {
      final stat = await _pcmFile!.stat();
      if (stat.size < 640) return; // 不到20ms数据，跳过
      final bytes = await _pcmFile!.readAsBytes();
      final encoded = base64Encode(bytes);
      onChunkReady?.call(bytes, _chunkDurationMs);
      await _uploadChunk(encoded);
    } catch (_) {}
  }

  Future<void> _uploadChunk(String base64Audio) async {
    if (_httpClient == null) return;
    try {
      await _httpClient!.post(
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

    await _recorder.stop();

    // 读取并上传最后一块
    await _flushChunk();

    await _pcmSink?.flush();
    await _pcmSink?.close();
    _pcmSink = null;

    // 发送结束标识
    try {
      await _httpClient?.post(
        Uri.parse('$baseUrl/upload/audio_chunk'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'ctxId': sessionId, 'audio': '', 'end': true}),
      );
    } catch (_) {}

    _httpClient?.close();
    _httpClient = null;
    onRecordingStop?.call();
  }

  void dispose() {
    _chunkTimer?.cancel();
    _recorder.stop();
    _pcmSink?.close();
    _pcmFile?.delete();
    _httpClient?.close();
    _recorder.dispose();
  }
}
