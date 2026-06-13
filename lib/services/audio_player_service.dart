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

  /// 接收一个base64编码的PCM 24kHz stereo分片，转WAV后加入播放队列
  /// Omni 模式专用
  void enqueuePcm(String base64Pcm) {
    try {
      final pcmBytes = base64Decode(base64Pcm);
      final wavBytes = _pcmToWav(pcmBytes);
      _queue.add(Uint8List.fromList(wavBytes));
      if (!_isPlaying) {
        _playNext();
      }
    } catch (e) {
      onError?.call('PCM音频解码失败: $e');
    }
  }

  /// PCM 24kHz stereo S16LE → WAV (RIFF header)
  Uint8List _pcmToWav(Uint8List pcm) {
    const sampleRate = 24000;
    const numChannels = 2;
    const bitsPerSample = 16;
    final byteRate = sampleRate * numChannels * bitsPerSample ~/ 8;
    final blockAlign = numChannels * bitsPerSample ~/ 8;
    final dataSize = pcm.length;
    final fileSize = 36 + dataSize;

    final wav = ByteData(44 + dataSize);
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

