import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

class AudioPlayerService {
  static const int _sampleRate = 24000;

  // debug ingest (session deae74) — append NDJSON to local file
  static const String _dbgPath = '/Users/xiaohu/Downloads/AIVideo/.cursor/debug-deae74.log';
  static const String _dbgSession = 'deae74';
  void _dbg(String location, String message, Map<String, dynamic> data, {String hypothesisId = 'H?'}) {
    // #region agent log
    try {
      // ignore: avoid_print
      print('[AudioDbg] $location $message $data');
      final obj = {
        'sessionId': _dbgSession,
        'id': 'log_${DateTime.now().millisecondsSinceEpoch}_audio',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'location': location,
        'message': message,
        'data': data,
        'runId': 'pre-fix',
        'hypothesisId': hypothesisId,
      };
      final f = File(_dbgPath);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync('${jsonEncode(obj)}\n', mode: FileMode.append, flush: false);
    } catch (_) {}
    // #endregion
  }

  final SoLoud _soloud = SoLoud.instance;
  AudioSource? _streamHandle;
  SoundHandle? _activeHandle;
  bool _playing = false;
  bool _ended = false;

  double _currentVolume = 0.5;
  Function(double volume)? onVolumeChanged;
  VoidCallback? onPlaybackStart;
  VoidCallback? onPlaybackComplete;
  Function(String error)? onError;

  bool _initialized = false;
  Timer? _progressTimer;
  int _chunkCount = 0;

  // 缓冲：stream 未就绪时暂存 PCM 数据，startNewTurn 完成后 flush
  final List<Uint8List> _pendingPcm = [];

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

  /// 预初始化 SoLoud 引擎（SSE 连接时调用，避免首帧延迟）
  Future<void> preInit() async {
    await _ensureInit();
  }

  double get currentVolume => _currentVolume;

  Future<void> startNewTurn() async {
    // #region agent log
    _dbg('audio_player_service.dart:startNewTurn', 'startNewTurn_called', {
      'chunkCount_was': _chunkCount,
      'old_ended': _ended,
      'streamHandle_was_alive': _streamHandle != null,
    }, hypothesisId: 'H3');
    // #endregion
    _ended = false;
    _playing = false;
    _chunkCount = 0;
    _pendingPcm.clear();
    await _ensureInit();
    if (_streamHandle != null) {
      try {
        if (_activeHandle != null) {
          _soloud.stop(_activeHandle!);
        }
        _soloud.disposeSource(_streamHandle!);
      } catch (_) {}
      _streamHandle = null;
      _activeHandle = null;
    }
    _progressTimer?.cancel();
    try {
      _streamHandle = _soloud.setBufferStream(
        maxBufferSizeBytes: 4 * 1024 * 1024,
        bufferingType: BufferingType.released,
        bufferingTimeNeeds: 0.1,
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
    // flush 暂存的 PCM
    if (_streamHandle != null && _pendingPcm.isNotEmpty) {
      for (final pcm in _pendingPcm) {
        _appendPcm(pcm);
      }
      _pendingPcm.clear();
    }
  }

  Future<void> flushPending() async {
    // #region agent log
    _dbg('audio_player_service.dart:flushPending', 'flushPending_called', {
      'chunkCount': _chunkCount,
      'ended_before': _ended,
      'streamHandle_alive': _streamHandle != null,
    }, hypothesisId: 'H3');
    // #endregion
    _ended = true;
    if (_streamHandle != null) {
      try {
        _soloud.setDataIsEnded(_streamHandle!);
        // #region agent log
        _dbg('audio_player_service.dart:flushPending', 'data_ended_signaled', {
          'chunkCount': _chunkCount,
          'ended_now': _ended,
        }, hypothesisId: 'H3');
        // #endregion
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
        t.cancel();
        _progressTimer = null;
      }
    });
  }

  void enqueue(String base64Audio) {
    enqueuePcm(base64Audio);
  }

  /// 接收 base64 PCM 24kHz mono S16LE 分片
  /// 如果 stream 未就绪，数据会暂存并在 startNewTurn 完成后 flush
  void enqueuePcm(String base64Pcm) {
    if (_ended) return;
    try {
      final pcm = base64Decode(base64Pcm);
      if (_streamHandle == null) {
        // stream 未就绪，暂存
        _pendingPcm.add(pcm);
        return;
      }
      _appendPcm(pcm);
    } catch (_) {}
  }

  void _appendPcm(Uint8List pcm) {
    if (pcm.isEmpty) return;
    if (_streamHandle == null) return;

    _chunkCount++;

    // H8 修复：检测 Omni TTS 句间静默 padding 帧（全 0）。仍把数据喂给 SoLoud
    // （保时序对齐），但不上报 volume，避免球体动画"哑火"。
    final isSilentFrame = _isAllZero(pcm);

    try {
      _soloud.addAudioDataStream(_streamHandle!, pcm);
      if (!_playing) {
        // 关键修复（H4 变种）：stream.play() 后 handles 可能尚未填充
        // ——若立即取 first 会拿到 null，下一帧的 _playing=true 标志
        // 提前触发 onPlaybackStart，但音频其实没出来。延后一帧再确认。
        if (_streamHandle!.handles.isNotEmpty) {
          _activeHandle = _streamHandle!.handles.first;
          // 静默帧：不更新 _currentVolume（避免上报 0.0 致 UI 哑火），
          // 但仍触发 onPlaybackStart ——否则 UI 永远等不到"开始播放"事件
          if (!isSilentFrame) {
            _currentVolume = _estimateVolume(pcm);
            onVolumeChanged?.call(_currentVolume);
          }
          _playing = true;
          onPlaybackStart?.call();
        }
        // handles 还没就绪：保持 _playing=false，下一帧再判断
      } else {
        // H7 修复：_activeHandle 在首次 chunks 时可能仍为 null（handles 异步填充）。
        // 后续 chunks 也必须检查并补抓 handles.first，否则 pause/resume/dispose
        // 拿不到有效 handle → 暂停键失效 / 退出时 native 句柄泄露。
        if (_activeHandle == null && _streamHandle!.handles.isNotEmpty) {
          _activeHandle = _streamHandle!.handles.first;
        }
        // 静默 padding 帧：不打扰 UI；保持 _currentVolume 旧值
        if (!isSilentFrame && _chunkCount % 10 == 0) {
          _currentVolume = _estimateVolume(pcm);
          onVolumeChanged?.call(_currentVolume);
        }
      }
    } catch (e) {
      // #region agent log
      debugPrint('[AudioPlayer] addAudioDataStream ERROR: $e chunk=$_chunkCount');
      // #endregion
    }
  }

  /// 快速检测 PCM 帧是否全 0（采样前 64 字节，足够区分 TTS 句间 padding）
  bool _isAllZero(Uint8List pcm) {
    final n = pcm.length < 64 ? pcm.length : 64;
    for (int i = 0; i < n; i++) {
      if (pcm[i] != 0) return false;
    }
    return true;
  }

  double _estimateVolume(Uint8List pcm) {
    if (pcm.length < 4) return 0.5;
    int sum = 0;
    int count = 0;
    final step = pcm.length > 8000 ? 4 : 2;
    for (int i = 0; i < pcm.length - 1 && count < 4000; i += step) {
      final sample = pcm[i] | (pcm[i + 1] << 8);
      final signed = sample > 32767 ? sample - 65536 : sample;
      sum += signed.abs();
      count++;
    }
    final raw = count > 0 ? (sum / count / 32768.0) : 0.0;
    return raw.clamp(0.0, 1.0);
  }

  void clear() {
    _ended = false;
    _playing = false;
    _chunkCount = 0;
    _pendingPcm.clear();
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
    _progressTimer = null;
    // 关键修复：dispose 路径所有 SoLoud 调用加 try/catch 兜底。
    // Flutter 2.x 上 iOS 偶发 "Callback invoked after it has been deleted"
    // 即 _soloud.stop/disposeSource 抛 native exception 上来。
    // 兜底：吞掉异常，避免 dispose 链把异常冒泡到 AppState.dispose()。
    try {
      if (_activeHandle != null) {
        _soloud.stop(_activeHandle!);
      }
    } catch (e) {
      // #region agent log
      debugPrint('[AudioPlayer] dispose stop ERROR: $e');
      // #endregion
    }
    try {
      if (_streamHandle != null) {
        _soloud.disposeSource(_streamHandle!);
      }
    } catch (e) {
      // #region agent log
      debugPrint('[AudioPlayer] dispose disposeSource ERROR: $e');
      // #endregion
    }
    _streamHandle = null;
    _activeHandle = null;
  }
}
