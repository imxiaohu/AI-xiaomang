import 'package:flutter_tts/flutter_tts.dart';

/// TTS服务封装
/// 用于离线模式本地语音播报
class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _isInitialized = false;
  bool _isSpeaking = false;

  Function(bool speaking)? onStateChanged;
  Function(double volume)? onVolumeChanged;

  /// 初始化
  Future<void> init() async {
    if (_isInitialized) return;

    await _tts.setLanguage('zh-CN');
    await _tts.setSpeechRate(0.5);
    await _tts.setPitch(1.0);
    await _tts.setVolume(1.0);

    // 监听播放状态
    _tts.setStartHandler(() {
      _isSpeaking = true;
      onStateChanged?.call(true);
    });
    _tts.setCompletionHandler(() {
      _isSpeaking = false;
      onStateChanged?.call(false);
    });
    _tts.setCancelHandler(() {
      _isSpeaking = false;
      onStateChanged?.call(false);
    });
    _tts.setErrorHandler((e) {
      _isSpeaking = false;
      onStateChanged?.call(false);
    });

    _isInitialized = true;
  }

  bool get isSpeaking => _isSpeaking;

  /// 播报文本
  Future<void> speak(String text) async {
    if (!_isInitialized) await init();
    if (_isSpeaking) await stop();
    await _tts.speak(text);
  }

  /// 停止播报
  Future<void> stop() async {
    await _tts.stop();
    _isSpeaking = false;
    onStateChanged?.call(false);
  }

  /// 暂停（iOS/Android支持情况不同）
  Future<void> pause() async {
    try {
      await _tts.pause();
    } catch (_) {}
  }

  /// 设置语速
  Future<void> setSpeechRate(double rate) async {
    await _tts.setSpeechRate(rate.clamp(0.0, 1.0));
  }

  void dispose() {
    _tts.stop();
  }
}
