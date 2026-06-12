import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 后台音频保活服务
/// 在Android上启动前台Service防止进程被杀死
/// 在iOS上通过AVAudioSession保持后台音频
class BackgroundAudioService {
  static const int _healthCheckIntervalMs = 5000;

  Timer? _healthTimer;
  bool _isActive = false;
  static const _channel = MethodChannel('com.example.ai_video/foreground_service');

  Function()? onHealthCheck;
  Function(String error)? onError;

  bool get isActive => _isActive;

  /// 启动后台保活（录制/播放期间）
  void start() {
    if (_isActive) return;
    _isActive = true;

    // 触发原生前台服务
    _startNativeForeground();

    _startHealthCheck();
    debugPrint('[BackgroundAudioService] started');
  }

  void _startNativeForeground() {
    if (Platform.isAndroid) {
      _channel.invokeMethod('startForeground').catchError((e) {
        debugPrint('[BackgroundAudioService] Failed to start foreground: $e');
      });
    }
  }

  void _startHealthCheck() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(
      const Duration(milliseconds: _healthCheckIntervalMs),
      (_) => _check(),
    );
  }

  void _check() {
    try {
      if (Platform.isAndroid) {
        _checkAndroid();
      } else if (Platform.isIOS) {
        _checkIOS();
      }
      onHealthCheck?.call();
    } catch (e) {
      onError?.call('Background health check failed: $e');
    }
  }

  void _checkAndroid() {
    try {
      final file = File('/proc/self/status');
      if (file.existsSync()) {
        final content = file.readAsStringSync();
        final match = RegExp(r'VmRSS:\s+(\d+)\s+kB').firstMatch(content);
        if (match != null) {
          final rssKb = int.tryParse(match.group(1) ?? '0') ?? 0;
          if (rssKb > 3.5 * 1024 * 1024) {
            debugPrint('[BackgroundAudioService] High memory: ${rssKb ~/ 1024}MB, consider GC');
          }
        }
      }
    } catch (_) {}
  }

  void _checkIOS() {
    // iOS: AVAudioSession 由系统管理，无需额外检查
  }

  /// 停止后台保活（idle状态节能）
  void stop() {
    _isActive = false;
    _healthTimer?.cancel();
    _healthTimer = null;
    _stopNativeForeground();
    debugPrint('[BackgroundAudioService] stopped');
  }

  void _stopNativeForeground() {
    if (Platform.isAndroid) {
      _channel.invokeMethod('stopForeground').catchError((e) {
        debugPrint('[BackgroundAudioService] Failed to stop foreground: $e');
      });
    }
  }

  void dispose() {
    stop();
  }
}
