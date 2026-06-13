import 'dart:io';
import '../models/enums.dart';

/// 设备硬件能力信息
class HardwareInfo {
  /// 设备总内存（字节）
  final int totalMemoryBytes;

  /// 设备可用内存（字节）
  final int availableMemoryBytes;

  /// 是否支持视觉模型（内存 > 4GB）
  bool get supportsVisualModel => totalMemoryBytes > 4 * 1024 * 1024 * 1024;

  /// 是否支持3D球体渲染
  final bool supports3D;

  /// Android SDK 版本（0表示非Android）
  final int androidSdkVersion;

  /// iOS 版本（0表示非iOS）
  final int iosVersion;

  /// 是否为低内存设备（≤4GB）
  bool get isLowMemoryDevice => totalMemoryBytes <= 4 * 1024 * 1024 * 1024;

  /// 是否为极低内存设备（≤2GB）
  bool get isVeryLowMemoryDevice => totalMemoryBytes <= 2 * 1024 * 1024 * 1024;

  /// 推荐降级等级
  AiDegradationLevel get recommendedDegradation {
    if (isVeryLowMemoryDevice) return AiDegradationLevel.minimal;
    if (isLowMemoryDevice) return AiDegradationLevel.reduced;
    if (!supports3D) return AiDegradationLevel.reduced;
    return AiDegradationLevel.full;
  }

  const HardwareInfo({
    required this.totalMemoryBytes,
    required this.availableMemoryBytes,
    required this.supports3D,
    required this.androidSdkVersion,
    required this.iosVersion,
  });

  /// 检测当前设备硬件能力
  static Future<HardwareInfo> detect() async {
    int totalMemory = 4 * 1024 * 1024 * 1024;
    int availableMemory = 2 * 1024 * 1024 * 1024;
    int sdkVersion = 0;
    int iosVer = 0;
    bool supports3D = true;

    if (Platform.isAndroid) {
      try {
        final memInfo = await File('/proc/meminfo').readAsString();
        final totalMatch = RegExp(r'MemTotal:\s+(\d+)').firstMatch(memInfo);
        if (totalMatch != null) {
          totalMemory = int.parse(totalMatch.group(1)!) * 1024;
        }
        final availMatch = RegExp(r'MemAvailable:\s+(\d+)').firstMatch(memInfo);
        if (availMatch != null) {
          availableMemory = int.parse(availMatch.group(1)!) * 1024;
        }
      } catch (_) {}

      final ver = Platform.operatingSystemVersion;
      final match = RegExp(r'Android ([\d]+)').firstMatch(ver);
      sdkVersion = int.tryParse(match?.group(1) ?? '0') ?? 0;
    } else if (Platform.isIOS) {
      try {
        final info = await Process.run('sysctl', ['-n', 'hw.memsize']);
        if (info.exitCode == 0) {
          totalMemory = int.tryParse(info.stdout.toString().trim()) ?? totalMemory;
          availableMemory = totalMemory ~/ 2;
        }
      } catch (_) {}
      final verStr = Platform.operatingSystemVersion;
      final verMatch = RegExp(r'OS (\d+)').firstMatch(verStr);
      iosVer = int.tryParse(verMatch?.group(1) ?? '0') ?? 0;
    }

    if (Platform.isAndroid) {
      supports3D = totalMemory > 3 * 1024 * 1024 * 1024 && sdkVersion >= 24;
    } else if (Platform.isIOS) {
      supports3D = iosVer >= 13;
    }

    return HardwareInfo(
      totalMemoryBytes: totalMemory,
      availableMemoryBytes: availableMemory,
      supports3D: supports3D,
      androidSdkVersion: sdkVersion,
      iosVersion: iosVer,
    );
  }
}
