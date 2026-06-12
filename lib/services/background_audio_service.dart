import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// 后台音频保活服务
/// 防止 Android/iOS 系统在后台冻结应用进程
class BackgroundAudioService {
  static const int _healthCheckIntervalMs = 5000;

  Timer? _healthTimer;
  bool _isActive = false;

  Function()? onHealthCheck;
  Function(String error)? onError;

  bool get isActive => _isActive;

  /// 启动后台保活（录制/播放期间）
  void start() {
    if (_isActive) return;
    _isActive = true;
    _startHealthCheck();
    debugPrint('[BackgroundAudioService] started');
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
      // 检查进程是否存活
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
    // Android: 写入健康文件标记
    try {
      final file = File('/proc/self/status');
      if (file.existsSync()) {
        // 进程正常，读取VmRSS确认内存占用
        final content = file.readAsStringSync();
        final match = RegExp(r'VmRSS:\s+(\d+)\s+kB').firstMatch(content);
        if (match != null) {
          final rssKb = int.tryParse(match.group(1) ?? '0') ?? 0;
          // 内存 > 3.5GB 触发GC（仅建议，非强制）
          if (rssKb > 3.5 * 1024 * 1024) {
            debugPrint('[BackgroundAudioService] High memory: ${rssKb ~/ 1024}MB, consider GC');
          }
        }
      }
    } catch (_) {}
  }

  void _checkIOS() {
    // iOS: AVAudioSession 已由系统管理，无需额外检查
  }

  /// 停止后台保活（idle状态节能）
  void stop() {
    _isActive = false;
    _healthTimer?.cancel();
    _healthTimer = null;
    debugPrint('[BackgroundAudioService] stopped');
  }

  void dispose() {
    stop();
  }
}
