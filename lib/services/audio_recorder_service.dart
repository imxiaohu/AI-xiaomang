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

  int _lastReadOffset = 0; // track how many bytes have been read so far

  AudioRecorderService({required this.baseUrl, required this.sessionId});

  bool get isRecording => _isRecording;

  /// 录音是否已被用户/编排显式暂停
  /// （底层 `_recorder` 处于 paused 状态，但 `_isRecording` 仍为 true，
  /// 这样 `_flushChunk` 守卫会放行：暂停期间文件没有新数据，guard 在 size 校验处自然早返回，
  /// 不会上传静默帧。）
  bool _isPaused = false;
  bool get isPaused => _isPaused;

  /// 暂停录音（不释放资源、不关闭分片上传 timer）
  /// VAD 模式下用于在 AI 播报 TTS 时切断 mic 输入，避免 TTS 串扰导致循环触发
  Future<void> pauseRecording() async {
    if (!_isRecording || _isPaused) return;
    try {
      await _recorder.pause();
      _isPaused = true;
      debugPrint('[AudioRecorder] pauseRecording() done');
    } catch (e) {
      debugPrint('[AudioRecorder] pauseRecording error: $e');
    }
  }

  /// 恢复录音（与 pauseRecording 配对使用）
  Future<void> resumeRecording() async {
    if (!_isRecording || !_isPaused) return;
    try {
      await _recorder.resume();
      _isPaused = false;
      debugPrint('[AudioRecorder] resumeRecording() done');
    } catch (e) {
      debugPrint('[AudioRecorder] resumeRecording error: $e');
    }
  }

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
    print('[AudioRecorder] startRecording() entered, _isRecording=$_isRecording');
    if (_isRecording) return;

    final hasPerm = await _recorder.hasPermission();
    print('[AudioRecorder] hasPermission=$hasPerm');
    if (!hasPerm) {
      onError?.call('麦克风权限未授权');
      return;
    }

    _httpClient = http.Client();

    // 创建临时PCM文件（用于Whisper）
    final dir = await getTemporaryDirectory();
    _pcmFile = File('${dir.path}/recording_${DateTime.now().millisecondsSinceEpoch}.pcm');
    _pcmSink = _pcmFile!.openWrite();
    print('[AudioRecorder] pcm file=${_pcmFile!.path}');

    // 禁用 record 插件的音频会话管理，由 AppDelegate 统一配置
    // 避免 record 启动时覆盖 SoLoud 的 AVAudioEngine 回调导致 SIGABRT
    await _recorder.ios?.manageAudioSession(false);

    // 16KHz mono PCM：每秒 32000 字节
    await _recorder.start(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 256000,
        iosConfig: const IosRecordConfig(
          categoryOptions: [
            IosAudioCategoryOption.mixWithOthers,
            IosAudioCategoryOption.defaultToSpeaker,
            IosAudioCategoryOption.allowBluetooth,
          ],
        ),
      ),
      path: _pcmFile!.path,
    );
    print('[AudioRecorder] recorder.start() returned');

    _isRecording = true;
    _isPaused = false;
    _lastReadOffset = 0;
    print('[AudioRecorder] startRecording done, file=${_pcmFile!.path}');
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
      debugPrint('[AudioRecorder] _flushChunk: size=${stat.size} lastRead=$_lastReadOffset');
      if (stat.size <= _lastReadOffset) return; // no new data
      final raf = await _pcmFile!.open(mode: FileMode.read);
      await raf.setPosition(_lastReadOffset);
      final bytes = await raf.read(stat.size - _lastReadOffset);
      _lastReadOffset = stat.size;
      await raf.close();
      if (bytes.isEmpty) return;
      final encoded = base64Encode(bytes);
      debugPrint('[AudioRecorder] uploading chunk bytes=${bytes.length} b64_len=${encoded.length}');
      onChunkReady?.call(bytes, _chunkDurationMs);
      await _uploadChunk(encoded);
    } catch (e) {
      debugPrint('[AudioRecorder] _flushChunk error: $e');
    }
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
    // ⚠️ 修复：不能在这里先 _isRecording = false，否则 _flushChunk 第 90 行
    // 的 guard `if (!_isRecording) return` 会让最后一块 chunk 永远丢失，
    // 后端 session.audio_buffer 收不到任何 audio。
    // 改为：先 cancel timer、stop recorder，再 flush 最后一块，再标记结束。

    _chunkTimer?.cancel();
    _chunkTimer = null;

    await _recorder.stop();

    // 读取并上传最后一块（_isRecording 仍为 true，guard 放行）
    await _flushChunk();

    // 标记真正结束（在最后一块已 flush 之后）
    _isRecording = false;
    _isPaused = false;

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

  Future<void> dispose() async {
    _chunkTimer?.cancel();
    _chunkTimer = null;
    // ⚠️ 必须先 await stop，让 iOS / Android 原生录音线程结束，
    // 否则 dispose() 释放 MethodChannel 后，回调仍会投递给已销毁的 this，
    // 触发 "Callback invoked after it has been deleted" SIGABRT。
    if (_isRecording) {
      try {
        await _recorder.stop();
      } catch (_) {}
    }
    await _pcmSink?.flush();
    await _pcmSink?.close();
    _pcmSink = null;
    try {
      await _pcmFile?.delete();
    } catch (_) {}
    _pcmFile = null;
    _httpClient?.close();
    _httpClient = null;
    // 关键修复（H_Rec_Dispose）：dispose() 内部回调链可能抛
    // "Callback invoked after it has been deleted"（iOS native 偶发）。
    // 兜底：吞掉异常，避免 dispose 链把异常冒泡到 AppState.dispose()。
    try {
      await _recorder.dispose();
    } catch (e) {
      // #region agent log
      debugPrint('[AudioRecorder] dispose ERROR: $e');
      // #endregion
    }
  }
}
