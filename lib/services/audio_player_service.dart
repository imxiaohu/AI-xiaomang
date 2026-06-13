import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

/// 音频播放器服务
/// 接收 base64 MP3/PCM 分片，串行播放，暴露音量回调用于球体动画
///
/// 实现要点：
/// 1. Omni 模式每次 turn 收到一段连续的 PCM 24kHz mono S16LE 流（~16 个 chunk）。
///    旧实现（audioplayers）每个 chunk 写一次临时文件 + AVPlayer.setSource，
///    iOS 上小 chunk 切换开销大、出现卡顿。
/// 2. 新实现（just_audio）：把同一 turn 内的所有 WAV/PCM 分片**拼接**成一个临时文件
///    一次性 setFilePath 播放，整段音频顺滑；播放完或新 turn 到达时清空。
class AudioPlayerService {
  // WAV header size (RIFF/fmt/data subchunks)
  static const int _wavHeaderSize = 44;
  // 触发"实际播放"的待播放字节数阈值（约 200ms @ 24kHz mono S16LE）
  static const int _flushThresholdBytes = 24000 * 2 * 1 * 200 ~/ 1000; // = 9600

  final List<({Uint8List bytes, String mimeType})> _queue = [];
  Uint8List? _pendingPcm; // Omni 累积的纯 PCM 数据（去掉 WAV header）
  int _pendingPcmBytes = 0;
  bool _isPlaying = false;
  final AudioPlayer _player = AudioPlayer();
  int _turnId = 0; // 每次 startNewTurn 自增，用于隔离旧 turn 的回调

  // 音量回调（0.0~1.0）
  double _currentVolume = 0.5;
  Function(double volume)? onVolumeChanged;

  // 播放状态回调
  VoidCallback? onPlaybackStart;
  VoidCallback? onPlaybackComplete;
  Function(String error)? onError;

  AudioPlayerService() {
    _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        _onPlayComplete();
      }
    });
  }

  double get currentVolume => _currentVolume;

  /// 开始新 turn：丢弃上一 turn 未播放完的内容，重置累积缓冲
  void startNewTurn() {
    _turnId++;
    _queue.clear();
    _pendingPcm = null;
    _pendingPcmBytes = 0;
    _isPlaying = false;
    _player.stop();
  }

  /// 接收一个 base64 编码的 MP3 分片
  void enqueue(String base64Audio) {
    try {
      final bytes = base64Decode(base64Audio);
      _queue.add((bytes: Uint8List.fromList(bytes), mimeType: 'audio/mpeg'));
      _scheduleFlush();
    } catch (e) {
      onError?.call('音频分片解码失败: $e');
    }
  }

  /// 接收一个 base64 编码的 PCM 24kHz mono 分片
  /// Omni 模式专用：把多个 PCM 分片拼成一段 WAV 再一次性播放
  void enqueuePcm(String base64Pcm) {
    try {
      final pcmBytes = base64Decode(base64Pcm);
      // Omni 总是 24kHz mono S16LE：每个样本 2 字节
      if (_pendingPcm == null) {
        _pendingPcm = Uint8List(0);
      }
      final merged = Uint8List(_pendingPcmBytes + pcmBytes.length)
        ..setRange(0, _pendingPcmBytes, _pendingPcm!)
        ..setRange(_pendingPcmBytes, _pendingPcmBytes + pcmBytes.length, pcmBytes);
      _pendingPcm = merged;
      _pendingPcmBytes = merged.length;
      _scheduleFlush();
    } catch (e) {
      onError?.call('PCM音频解码失败: $e');
    }
  }

  /// 决定是否要把累积的内容真正送去播放器
  /// 触发条件：
  /// 1) MP3 队列里有 chunk 且当前没在播放（每个 MP3 chunk 独立播放）
  /// 2) PCM 累积超过 ~200ms（拼成 WAV 一次播）
  /// 3) endTurn 主动 flush（由调用方在收到 end 事件时调 flushPending）
  void _scheduleFlush() {
    if (_isPlaying) {
      // 已经在播：让当前 turn 的内容留到播放完再播
      return;
    }
    if (_queue.isNotEmpty) {
      // MP3 分片：直接出队第一个播放
      _playNextMp3();
      return;
    }
    if (_pendingPcmBytes >= _flushThresholdBytes) {
      _flushPcm();
    }
  }

  /// 把累积的 PCM 拼成 WAV 并播放
  Future<void> _flushPcm() async {
    if (_pendingPcm == null || _pendingPcmBytes == 0) return;
    final pcm = _pendingPcm!;
    _pendingPcm = null;
    _pendingPcmBytes = 0;

    final wav = _pcmToWav(pcm);
    _isPlaying = true;
    onPlaybackStart?.call();

    _currentVolume = _estimateVolume(wav);
    onVolumeChanged?.call(_currentVolume);

    try {
      // 写到临时文件（带 .wav 扩展名，让 iOS AVPlayer 识别格式）
      final file = await _writeTempFile(wav, 'omni_$_turnId.wav');
      await _player.setFilePath(file.path);
      await _player.play();
    } catch (e) {
      onError?.call('音频播放失败: $e');
      _isPlaying = false;
      _scheduleFlush();
    }
  }

  Future<void> _playNextMp3() async {
    if (_queue.isEmpty) return;
    final item = _queue.removeAt(0);
    _isPlaying = true;
    onPlaybackStart?.call();

    _currentVolume = _estimateVolume(item.bytes);
    onVolumeChanged?.call(_currentVolume);

    try {
      final file = await _writeTempFile(item.bytes, 'mp3_$_turnId.mp3');
      await _player.setFilePath(file.path);
      await _player.play();
    } catch (e) {
      onError?.call('音频播放失败: $e');
      _isPlaying = false;
      _scheduleFlush();
    }
  }

  void _onPlayComplete() {
    _isPlaying = false;
    onPlaybackComplete?.call();
    // 继续播放剩余内容
    _scheduleFlush();
  }

  /// PCM 24kHz mono S16LE → WAV (RIFF header)
  Uint8List _pcmToWav(Uint8List pcm) {
    const sampleRate = 24000;
    const numChannels = 1;
    const bitsPerSample = 16;
    final byteRate = sampleRate * numChannels * bitsPerSample ~/ 8;
    final blockAlign = numChannels * bitsPerSample ~/ 8;
    final dataSize = pcm.length;
    final fileSize = 36 + dataSize;

    final wav = ByteData(_wavHeaderSize + dataSize);
    // RIFF header
    wav.setUint8(0, 0x52); wav.setUint8(1, 0x49); // RIFF
    wav.setUint8(2, 0x46); wav.setUint8(3, 0x46);
    wav.setUint32(4, fileSize, Endian.little);
    wav.setUint8(8, 0x57); wav.setUint8(9, 0x41); // WAVE
    wav.setUint8(10, 0x56); wav.setUint8(11, 0x45);
    // fmt subchunk
    wav.setUint8(12, 0x66); wav.setUint8(13, 0x6D); // fmt
    wav.setUint8(14, 0x74); wav.setUint8(15, 0x20);
    wav.setUint32(16, 16, Endian.little);           // subchunk1 size
    wav.setUint16(20, 1, Endian.little);            // PCM format
    wav.setUint16(22, numChannels, Endian.little);
    wav.setUint32(24, sampleRate, Endian.little);
    wav.setUint32(28, byteRate, Endian.little);
    wav.setUint16(32, blockAlign, Endian.little);
    wav.setUint16(34, bitsPerSample, Endian.little);
    // data subchunk
    wav.setUint8(36, 0x64); wav.setUint8(37, 0x61); // data
    wav.setUint8(38, 0x74); wav.setUint8(39, 0x61);
    wav.setUint32(40, dataSize, Endian.little);
    // PCM samples
    for (int i = 0; i < dataSize; i++) {
      wav.setUint8(44 + i, pcm[i]);
    }
    return wav.buffer.asUint8List();
  }

  /// 估算音频分片音量（简单RMS）
  double _estimateVolume(Uint8List bytes) {
    if (bytes.length < 100) return 0.5;
    int sum = 0;
    int count = 0;
    final int start = bytes.length > 100 ? _wavHeaderSize : 0;
    for (int i = start; i < bytes.length - 1 && count < 1000; i += 2) {
      final sample = bytes[i] | (bytes[i + 1] << 8);
      final signed = sample > 32767 ? sample - 65536 : sample;
      sum += signed.abs();
      count++;
    }
    return count > 0 ? (sum / count / 32768.0).clamp(0.0, 1.0) : 0.5;
  }

  /// 写入临时文件（带正确扩展名，iOS AVPlayer 必需）
  Future<File> _writeTempFile(Uint8List bytes, String name) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// 强制把当前 turn 剩余的 PCM 拼出来播放（end 事件到达时调用）
  Future<void> flushPending() async {
    if (_isPlaying) return;
    if (_pendingPcm != null && _pendingPcmBytes > 0) {
      await _flushPcm();
    }
  }

  /// 清空队列并停止
  void clear() {
    _queue.clear();
    _pendingPcm = null;
    _pendingPcmBytes = 0;
    _player.stop();
    _isPlaying = false;
  }

  /// 暂停
  Future<void> pause() async {
    await _player.pause();
  }

  /// 恢复
  Future<void> resume() async {
    await _player.play();
  }

  void dispose() {
    _player.dispose();
  }
}
