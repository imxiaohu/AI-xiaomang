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
/// 1. 用 just_audio 的 [AudioPlayer] 共享同一播放器实例。
/// 2. 状态机驱动：监听 `playerStateStream`，`completed` 时自动 setFilePath 下一个。
///    setFilePath().then(play) 串行化避免"play() called before prepare"竞态。
/// 3. PCM 24kHz mono 分片累积到 ~200ms（9600 字节）再拼成 WAV 写入临时文件。
/// 4. turn 结束时清理所有临时文件。
class AudioPlayerService {
  static const int _wavHeaderSize = 44;
  // PCM flush 阈值：~200ms @ 24kHz mono S16LE = 9600 bytes
  static const int _flushThresholdBytes = 24000 * 2 * 1 * 200 ~/ 1000;

  final AudioPlayer _player = AudioPlayer();
  int _turnId = 0;
  bool _busy = false; // 串行锁：避免并发 setFilePath

  // 待播放队列（文件路径）
  final List<String> _pendingFiles = [];
  // 临时文件路径 → 音量估计
  final Map<String, double> _fileVolume = {};

  // PCM 累积缓冲
  Uint8List? _pendingPcm;
  int _pendingPcmBytes = 0;

  // 当前 turn 写入的临时文件
  final List<File> _tempFiles = [];

  // 音量回调
  double _currentVolume = 0.5;
  Function(double volume)? onVolumeChanged;

  // 播放状态回调
  VoidCallback? onPlaybackStart;
  VoidCallback? onPlaybackComplete;
  Function(String error)? onError;

  AudioPlayerService() {
    // 状态机：completed → 续播下一段
    _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        // 当前文件播完；续播下一段或通知完成
        _onPlayComplete();
      } else if (state.processingState == ProcessingState.ready) {
        if (_busy) {
          _currentVolume = _fileVolume[_currentPath] ?? _currentVolume;
          onVolumeChanged?.call(_currentVolume);
          onPlaybackStart?.call();
        }
      }
    });
  }

  double get currentVolume => _currentVolume;
  String? _currentPath; // 当前正在播放的文件

  /// 开始新 turn：清空队列并停止
  void startNewTurn() {
    _turnId++;
    _pendingFiles.clear();
    _fileVolume.clear();
    _pendingPcm = null;
    _pendingPcmBytes = 0;
    _busy = false;
    _currentPath = null;
    _player.stop();
  }

  /// 接收一个 base64 编码的 MP3 分片
  void enqueue(String base64Audio) {
    try {
      final bytes = base64Decode(base64Audio);
      _enqueueBytes(Uint8List.fromList(bytes));
    } catch (e) {
      onError?.call('音频分片解码失败: $e');
    }
  }

  /// 接收一个 base64 编码的 PCM 24kHz mono 分片
  void enqueuePcm(String base64Pcm) {
    try {
      final pcmBytes = base64Decode(base64Pcm);
      if (_pendingPcm == null) {
        _pendingPcm = Uint8List(0);
      }
      final merged = Uint8List(_pendingPcmBytes + pcmBytes.length)
        ..setRange(0, _pendingPcmBytes, _pendingPcm!)
        ..setRange(_pendingPcmBytes, _pendingPcmBytes + pcmBytes.length, pcmBytes);
      _pendingPcm = merged;
      _pendingPcmBytes = merged.length;

      if (_pendingPcmBytes >= _flushThresholdBytes) {
        final pcm = _pendingPcm!;
        _pendingPcm = null;
        _pendingPcmBytes = 0;
        _enqueueBytes(_pcmToWav(pcm));
      }
    } catch (e) {
      onError?.call('PCM音频解码失败: $e');
    }
  }

  /// 把一个已就绪的音频字节流写入临时文件并入队
  void _enqueueBytes(Uint8List bytes) {
    debugPrint('[AudioPlayer] _enqueueBytes bytes=${bytes.length} turn=$_turnId');
    final name = 'audio_${_turnId}_${DateTime.now().microsecondsSinceEpoch}.bin';
    _writeTempFile(bytes, name).then((file) {
      debugPrint('[AudioPlayer] _writeTempFile OK path=${file.path}');
      _tempFiles.add(file);
      final path = file.path;
      _fileVolume[path] = _estimateVolume(bytes);
      _pendingFiles.add(path);
      _drainQueue();
    }, onError: (e) {
      debugPrint('[AudioPlayer] _writeTempFile FAILED: $e');
      onError?.call('音频临时文件写入失败: $e');
    });
  }

  /// 从队列取下一个文件播放（串行）
  Future<void> _drainQueue() async {
    if (_busy) return; // 正在播；_onPlayComplete 会接着调
    if (_pendingFiles.isEmpty) return;
    final path = _pendingFiles.removeAt(0);
    _busy = true;
    _currentPath = path;
    debugPrint('[AudioPlayer] _drainQueue start path=$path pending=${_pendingFiles.length}');
    try {
      // 先 stop 旧 source，避免残留状态干扰
      await _player.stop();
      // 顺序：setFilePath → 等待完成 → play
      await _player.setFilePath(path);
      debugPrint('[AudioPlayer] setFilePath done, calling play');
      await _player.play();
      debugPrint('[AudioPlayer] play OK');
    } catch (e) {
      debugPrint('[AudioPlayer] _drainQueue ERROR: $e');
      onError?.call('音频播放失败: $e');
      _busy = false;
      _currentPath = null;
      _drainQueue();
    }
  }

  void _onPlayComplete() {
    debugPrint('[AudioPlayer] _onPlayComplete pending=${_pendingFiles.length}');
    _busy = false;
    _currentPath = null;
    if (_pendingFiles.isNotEmpty) {
      _drainQueue();
    } else {
      onPlaybackComplete?.call();
    }
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
    wav.setUint8(0, 0x52); wav.setUint8(1, 0x49);
    wav.setUint8(2, 0x46); wav.setUint8(3, 0x46);
    wav.setUint32(4, fileSize, Endian.little);
    wav.setUint8(8, 0x57); wav.setUint8(9, 0x41);
    wav.setUint8(10, 0x56); wav.setUint8(11, 0x45);
    // fmt subchunk
    wav.setUint8(12, 0x66); wav.setUint8(13, 0x6D);
    wav.setUint8(14, 0x74); wav.setUint8(15, 0x20);
    wav.setUint32(16, 16, Endian.little);
    wav.setUint16(20, 1, Endian.little);
    wav.setUint16(22, numChannels, Endian.little);
    wav.setUint32(24, sampleRate, Endian.little);
    wav.setUint32(28, byteRate, Endian.little);
    wav.setUint16(32, blockAlign, Endian.little);
    wav.setUint16(34, bitsPerSample, Endian.little);
    // data subchunk
    wav.setUint8(36, 0x64); wav.setUint8(37, 0x61);
    wav.setUint8(38, 0x74); wav.setUint8(39, 0x61);
    wav.setUint32(40, dataSize, Endian.little);
    for (int i = 0; i < dataSize; i++) {
      wav.setUint8(44 + i, pcm[i]);
    }
    return wav.buffer.asUint8List();
  }

  /// 估算音频分片音量（简单 RMS）
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

  /// 写入临时文件
  Future<File> _writeTempFile(Uint8List bytes, String name) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// 清理当前 turn 的所有临时文件
  void _cleanupTempFiles() {
    for (final f in _tempFiles) {
      f.delete().then((_) {}, onError: (_) {});
    }
    _tempFiles.clear();
  }

  /// 强制把当前 turn 剩余的 PCM 拼出来播放（end 事件到达时调用）
  Future<void> flushPending() async {
    if (_pendingPcm != null && _pendingPcmBytes > 0) {
      final pcm = _pendingPcm!;
      _pendingPcm = null;
      _pendingPcmBytes = 0;
      _enqueueBytes(_pcmToWav(pcm));
    }
  }

  /// 清空队列并停止
  void clear() {
    _pendingFiles.clear();
    _fileVolume.clear();
    _pendingPcm = null;
    _pendingPcmBytes = 0;
    _busy = false;
    _currentPath = null;
    _player.stop();
  }

  Future<void> pause() => _player.pause();
  Future<void> resume() => _player.play();

  void dispose() {
    _cleanupTempFiles();
    _player.dispose();
  }
}
