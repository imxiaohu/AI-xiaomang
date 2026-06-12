import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show VoidCallback;

/// 网络连接状态
enum NetworkStatus {
  wifi,
  mobile,
  none,
}

/// 网络连接监控服务
/// 监听网络状态变化，弱网时触发SSE重连
class ConnectivityService {
  final Connectivity _connectivity = Connectivity();

  StreamSubscription? _subscription;
  NetworkStatus _currentStatus = NetworkStatus.none;

  // 回调
  Function(NetworkStatus status)? onStatusChanged;
  VoidCallback? onConnected;
  VoidCallback? onDisconnected;

  NetworkStatus get currentStatus => _currentStatus;

  /// 启动监控
  Future<void> init() async {
    // 获取初始状态
    final results = await _connectivity.checkConnectivity();
    _updateStatus(results);

    // 监听变化
    _subscription = _connectivity.onConnectivityChanged.listen(_updateStatus);
  }

  void _updateStatus(List<ConnectivityResult> results) {
    final result = results.isNotEmpty ? results.first : ConnectivityResult.none;
    NetworkStatus newStatus;
    switch (result) {
      case ConnectivityResult.wifi:
        newStatus = NetworkStatus.wifi;
        break;
      case ConnectivityResult.mobile:
        newStatus = NetworkStatus.mobile;
        break;
      case ConnectivityResult.none:
      default:
        newStatus = NetworkStatus.none;
    }

    if (newStatus != _currentStatus) {
      _currentStatus = newStatus;
      onStatusChanged?.call(newStatus);
      if (newStatus != NetworkStatus.none) {
        onConnected?.call();
      } else {
        onDisconnected?.call();
      }
    }
  }

  /// 是否为弱网（移动网络）
  bool get isWeakNetwork => _currentStatus == NetworkStatus.mobile;

  /// 是否有网络
  bool get hasNetwork => _currentStatus != NetworkStatus.none;

  void dispose() {
    _subscription?.cancel();
  }
}
