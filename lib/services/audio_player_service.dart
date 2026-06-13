import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

/// 音频播放器服务
/// 接收 base64 PCM/MP3 分片，边收边播，0 间隙。
///
/// 关键设计（2026-06-14 第 5 次重写 — 切换到 flutter_soloud）：
///
/// 旧实现链：
///  1. just_audio setFilePath：每次切换有 130-200ms prepare 间隙 → "一截一截"
///  2. just_audio ConcatenatingAudioSource.add：AVQueuePlayer transition 风暴 → 卡死
///  3. in-memory seek 续播：setFilePath + seek 在 iOS 上不可靠 → 重复说话
///  4. 攒 1 个完整 WAV end 一次播：砍掉流式感
///
/// 新实现（flutter_soloud = SoLoud C++ 引擎，iOS 上跑在 AVAudioEngine 之上）：
///  - 用 setBufferStream() 建一个 raw PCM streaming source
///  - 每收到一份 PCM chunk → addAudioDataStream() 追加到同一个 stream
///  - 整段 turn 期间只有 1 个 active audio source 在播放
///  - SoLoud 内部用 ring buffer + AVAudioPlayerNode，**原生 gapless、无 prepare 间隙**
///
/// 延迟：setBufferStream 第一次拿够 bufferingTimeNeeds（~300ms）即开始播；
///       之后 addAudioDataStream 是 O(1) append。
class AudioPlayerService {
  static const int _sampleRate = 24000;

  final SoLoud _soloud = SoLoud.instance;
  AudioSource? _streamHandle; // 当前 turn 的 streaming source
  SoundHandle? _activeHandle; // 当前正在播放的 handle
  bool _playing = false;
  bool _ended = false;

  // 音量（估算）
  double _currentVolume = 0.5;
  Function(double volume)? onVolumeChanged;
  VoidCallback? onPlaybackStart;
  VoidCallback? onPlaybackComplete;
  Function(String error)? onError;

  bool _initialized = false;
  Timer? _progressTimer;

  Future<void> _ensureInit() async {
    if (_initialized) return;
    try {
      await _soloud.init();
      _initialized = true;
    } catch (e) {
      debugPrint('[AudioPlayer] SoLoud init ERROR: $e');
      onError?.call('音频引擎初始化失败: $e');
      rethrow;
    }
  }

  double get currentVolume => _currentVolume;

  /// 开始新 turn：建一个新的 streaming source
  Future<void> startNewTurn() async {
    _ended = false;
    _playing = false;
    _chunkCount = 0;
    await _ensureInit();
    // 停掉旧的（如果有）
    if (_streamHandle != null) {
      try {
        if (_activeHandle != null) {
          await _soloud.stop(_activeHandle!);
        }
        await _soloud.disposeSource(_streamHandle!);
      } catch (_) {}
      _streamHandle = null;
      _activeHandle = null;
    }
    _progressTimer?.cancel();
    try {
      _streamHandle = _soloud.setBufferStream(
        maxBufferSizeBytes: 4 * 1024 * 1024,
        bufferingType: BufferingType.released,
        bufferingTimeNeeds: 0.15,
        sampleRate: _sampleRate,
        channels: Channels.mono,
        format: BufferType.s16le,
      );
      _soloud.play(_streamHandle!);
    } catch (e) {
      debugPrint('[AudioPlayer] setBufferStream ERROR: $e');
      onError?.call('创建音频流失败: $e');
      _streamHandle = null;
    }
  }

  /// chat/end 事件到达时调用：告诉 SoLoud 数据流已经结束
  Future<void> flushPending() async {
    _ended = true;
    if (_streamHandle != null) {
      try {
        _soloud.setDataIsEnded(_streamHandle!);
        _startProgressWatcher();
      } catch (e) {
        debugPrint('[AudioPlayer] setDataIsEnded ERROR: $e');
      }
    }
  }

  void _startProgressWatcher() {
    _progressTimer?.cancel();
    if (_streamHandle == null) return;
    Duration? lastTime;
    int stableCount = 0;
    _progressTimer = Timer.periodic(const Duration(milliseconds: 100), (t) {
      if (_streamHandle == null) {
        t.cancel();
        return;
      }
      try {
        final consumed = _soloud.getStreamTimeConsumed(_streamHandle!);
        if (lastTime != null && consumed <= lastTime!) {
          // 进度没增长 → 播完了
          stableCount++;
          if (stableCount >= 3) {
            t.cancel();
            _progressTimer = null;
            if (_playing) {
              _playing = false;
              onPlaybackComplete?.call();
            }
          }
        } else {
          stableCount = 0;
        }
        lastTime = consumed;
      } catch (e) {
        // stream 已经被 dispose，停止轮询
        t.cancel();
        _progressTimer = null;
      }
    });
  }

  /// 接收一个 base64 编码的音频分片（VL+TTS 模式走 PCM 格式后）
  void enqueue(String base64Audio) {
    // VL+TTS 模式已改为发送 PCM 24kHz mono S16LE，与 Omni 模式共用路径
    enqueuePcm(base64Audio);
  }

  /// 接收一个 base64 编码的 PCM 24kHz mono S16LE 分片
  void enqueuePcm(String base64Pcm) {
    if (_ended) return;
    if (_streamHandle == null) return;
    try {
      final pcm = base64Decode(base64Pcm);
      _appendPcm(pcm);
    } catch (_) {}
  }

  // 音量更新节流
  int _chunkCount = 0;

  void _appendPcm(Uint8List pcm) {
    if (pcm.isEmpty) return;
    if (_streamHandle == null) return;

    _chunkCount++;

    try {
      _soloud.addAudioDataStream(_streamHandle!, pcm);
      if (!_playing) {
        _activeHandle = _streamHandle!.handles.isNotEmpty
            ? _streamHandle!.handles.first
            : null;
        _currentVolume = _estimateVolume(pcm);
        onVolumeChanged?.call(_currentVolume);
        _playing = true;
        onPlaybackStart?.call();
      } else if (_chunkCount % 10 == 0) {
        _currentVolume = _estimateVolume(pcm);
        onVolumeChanged?.call(_currentVolume);
      }
    } catch (e) {
      debugPrint('[AudioPlayer] addAudioDataStream ERROR: $e');
    }
  }

  /// 估算音频分片音量（简单 RMS，采样最多 4000 个样本 ≈ 83ms @24kHz）
  double _estimateVolume(Uint8List pcm) {
    if (pcm.length < 4) return 0.5;
    int sum = 0;
    int count = 0;
    // 采样间隔：如果 chunk 很大，跳着采样以覆盖更多数据
    final step = pcm.length > 8000 ? 4 : 2;
    for (int i = 0; i < pcm.length - 1 && count < 4000; i += step) {
      final sample = pcm[i] | (pcm[i + 1] << 8);
      final signed = sample > 32767 ? sample - 65536 : sample;
      sum += signed.abs();
      count++;
    }
    // 平均绝对值 / 32768 → [0, 1]，再用 sqrt 压缩动态范围让小音量更明显
    final raw = count > 0 ? (sum / count / 32768.0) : 0.0;
    return raw.clamp(0.0, 1.0);
  }

  void clear() {
    _ended = false;
    _playing = false;
    _chunkCount = 0;
    _progressTimer?.cancel();
    _progressTimer = null;
    if (_activeHandle != null) {
      _soloud.stop(_activeHandle!);
    }
    _activeHandle = null;
    _streamHandle = null;
  }

  Future<void> pause() async {
    if (_activeHandle != null) {
      _soloud.setPause(_activeHandle!, true);
    }
  }

  Future<void> resume() async {
    if (_activeHandle != null) {
      _soloud.setPause(_activeHandle!, false);
    }
  }

  void dispose() {
    _progressTimer?.cancel();
    if (_activeHandle != null) {
      _soloud.stop(_activeHandle!);
    }
    if (_streamHandle != null) {
      _soloud.disposeSource(_streamHandle!);
    }
    _streamHandle = null;
    _activeHandle = null;
    // 不 deinit SoLoud（全局单例，可能别处还要用）
  }
}
