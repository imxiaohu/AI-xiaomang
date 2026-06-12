import 'dart:async';
import 'dart:convert';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// 音频播放器服务
/// 接收base64 MP3分片，串行队列播放，暴露音量回调用于球体动画
class AudioPlayerService {
  final List<Uint8List> _queue = [];
  bool _isPlaying = false;
  final AudioPlayer _player = AudioPlayer();

  // 音量回调（0.0~1.0）
  double _currentVolume = 0.5;
  Function(double volume)? onVolumeChanged;

  // 播放状态回调
  VoidCallback? onPlaybackStart;
  VoidCallback? onPlaybackComplete;
  Function(String error)? onError;

  AudioPlayerService() {
    _player.onPlayerComplete.listen((_) {
      _playNext();
    });
    _player.onPlayerStateChanged.listen((state) {
      if (state == PlayerState.completed) {
        onPlaybackComplete?.call();
      }
    });
  }

  double get currentVolume => _currentVolume;

  /// 接收一个base64编码的MP3分片，加入播放队列
  void enqueue(String base64Audio) {
    try {
      final bytes = base64Decode(base64Audio);
      _queue.add(Uint8List.fromList(bytes));
      if (!_isPlaying) {
        _playNext();
      }
    } catch (e) {
      onError?.call('音频分片解码失败: $e');
    }
  }

  Future<void> _playNext() async {
    if (_queue.isEmpty) {
      _isPlaying = false;
      return;
    }
    _isPlaying = true;
    onPlaybackStart?.call();

    final chunk = _queue.removeAt(0);
    try {
      // 计算近似音量（基于字节数据的RMS估算）
      _currentVolume = _estimateVolume(chunk);
      onVolumeChanged?.call(_currentVolume);

      // 使用BytesSource实现流式播放
      await _player.play(BytesSource(chunk));
    } catch (e) {
      onError?.call('音频播放失败: $e');
      _playNext();
    }
  }

  /// 估算音频分片音量（简单RMS）
  double _estimateVolume(Uint8List bytes) {
    if (bytes.length < 100) return 0.5;
    int sum = 0;
    int count = 0;
    for (int i = 44; i < bytes.length - 44 && count < 1000; i += 2) {
      // 跳过MP3 header
      final sample = bytes[i] | (bytes[i + 1] << 8);
      final signed = sample > 32767 ? sample - 65536 : sample;
      sum += signed.abs();
      count++;
    }
    return count > 0 ? (sum / count / 32768.0).clamp(0.0, 1.0) : 0.5;
  }

  /// 清空队列并停止
  void clear() {
    _queue.clear();
    _player.stop();
    _isPlaying = false;
  }

  /// 暂停
  Future<void> pause() async {
    await _player.pause();
  }

  /// 恢复
  Future<void> resume() async {
    await _player.resume();
  }

  void dispose() {
    _player.dispose();
  }
}

