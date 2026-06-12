import 'dart:io';

/// 平台工具
/// 提供 Android/iOS 平台检测、异形屏适配
class PlatformUtils {
  /// 是否为Android平台
  static bool get isAndroid => Platform.isAndroid;

  /// 是否为iOS平台
  static bool get isIOS => Platform.isIOS;

  /// 是否为Mac平台
  static bool get isMacOS => Platform.isMacOS;

  /// 是否为Windows平台
  static bool get isWindows => Platform.isWindows;

  /// 是否为Linux平台
  static bool get isLinux => Platform.isLinux;

  /// Android SDK版本
  static int get androidSdkVersion {
    if (!isAndroid) return 0;
    final ver = Platform.operatingSystemVersion;
    final match = RegExp(r'Android ([\d]+)').firstMatch(ver);
    return int.tryParse(match?.group(1) ?? '0') ?? 0;
  }

  /// iOS版本
  static int get iosVersion {
    if (!isIOS) return 0;
    final ver = Platform.operatingSystemVersion;
    final match = RegExp(r'OS (\d+)').firstMatch(ver);
    return int.tryParse(match?.group(1) ?? '0') ?? 0;
  }

  /// 是否支持GGUF mmap（Android 10及以下不支持）
  static bool get supportsMmap {
    if (isAndroid) return androidSdkVersion >= 11;
    if (isIOS) return true;
    return false;
  }

  /// 是否支持Metal加速（iOS 15及以下不支持）
  static bool get supportsMetal {
    if (isIOS) return iosVersion >= 16;
    return false;
  }

  /// 获取系统安全区（刘海屏/异形屏底部避让）
  static double getSafeAreaBottom(double bottomPadding) => bottomPadding;

  /// 获取刘海屏顶部避让
  static double getSafeAreaTop(double topPadding) => topPadding;
}
