import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Offset, Size, Rect;
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

/// 摄像头抽帧服务
/// 使用 startImageStream 从视频流抽帧（避免 takePicture 的快门声）
/// 采集 ResolutionPreset.high（iOS 上 ~1920×1080 / Android 上 1280×720），
/// 按长边 1280 等比缩放后 JPG85 上传，兼顾清晰度与流量。
class VideoCaptureService {
  final String baseUrl;
  final String sessionId;

  CameraController? _controller;
  Timer? _captureTimer;
  bool _isCapturing = false;
  int _frameIndex = 0;
  Uint8List? _latestFrame;

  // 清晰度旋钮（清晰度优化版本）
  static const int _captureIntervalMs = 300; // 抽帧周期 ~3.3fps
  static const int _targetLongEdge = 1280; // 长边目标，长边等比缩放到 ≤1280
  static const int _jpegQuality = 85; // JPG 质量（原 65，提到 85 清晰度显著提升）

  // 回调
  Function(Uint8List compressedJpg)? onFrameCaptured;
  VoidCallback? onCameraReady;
  Function(String error)? onError;

  http.Client? _httpClient;

  VideoCaptureService({required this.baseUrl, required this.sessionId});

  bool get isActive => _isCapturing && _controller != null;

  /// 初始化摄像头
  Future<void> init(List<CameraDescription> cameras) async {
    if (cameras.isEmpty) {
      onError?.call('未检测到摄像头设备');
      return;
    }

    // 默认使用后置摄像头
    final back = cameras.where((c) => c.lensDirection == CameraLensDirection.back).toList();
    final camera = back.isNotEmpty ? back.first : cameras.first;

    _controller = CameraController(
      camera,
      ResolutionPreset.high, // 高清采集：iOS ~1920×1080 / Android ~1280×720
      enableAudio: false,
      // BGRA8888 让 startImageStream 拿到原始像素，避开 takePicture 的快门声。
      // Android 上用 YUV420 也行；这里统一用 BGRA，iOS/Android 都支持。
      imageFormatGroup: ImageFormatGroup.bgra8888,
    );

    try {
      await _controller!.initialize();
      _httpClient = http.Client();
      onCameraReady?.call();
      // 关键修复：camera 插件在 initialize() 之后不会自动设 focus mode，
      // iOS 上 sensor 默认可能是 locked / off（取决于 device + iOS 版本），
      // 导致画面一直失焦。这里初始化后立即下发 FocusMode.auto，
      // 让对焦子系统跑起来（auto = continuous auto focus）。
      // 注意：低对比度静物（白墙、文档）下 iOS continuous AF 也可能「懒得对」，
      // 此时需要用户点击屏幕手动指定对焦区域（setFocusPoint）。
      await _ensureAutoFocus();
    } catch (e) {
      onError?.call('摄像头初始化失败: $e');
    }
  }

  /// 确保自动对焦开启：只在当前不是 auto 时才下发，避免重复 setFocusMode 引发 sensor 抖动。
  Future<void> _ensureAutoFocus() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (!_autoFocus) return;
    try {
      // 强制重新触发一次 auto mode：先切到 locked 再切回 auto，
      // 这样 iOS sensor 一定会重新启动一次 AF cycle（避免某些设备 AF 被「卡住」）
      await _controller!.setFocusMode(FocusMode.locked);
      await _controller!.setFocusMode(FocusMode.auto);
    } catch (_) {
      // 部分设备/前置摄像头不支持，忽略
    }
  }

  /// 开始抽帧（使用视频流模式，无快门声）
  void startCapture() {
    if (_isCapturing || _controller == null || !_controller!.value.isInitialized) return;
    _isCapturing = true;
    _frameIndex = 0;

    // 启动视频流：每帧回调 onImage，转 JPG 后再按 _captureIntervalMs 节流上传
    _controller!.startImageStream(_onImageStream);

    _captureTimer = Timer.periodic(
      const Duration(milliseconds: _captureIntervalMs),
      (_) => _captureFrame(),
    );

    // 启动周期性自动对焦心跳：解决 iOS continuous AF 在静止画面下「懒得对」
    _startAfHeartbeat();
  }

  /// 停止抽帧（idle状态节能）
  void stopCapture() {
    _isCapturing = false;
    _captureTimer?.cancel();
    _captureTimer = null;
    _stopAfHeartbeat();
    try {
      if (_controller != null &&
          _controller!.value.isInitialized &&
          _controller!.value.isStreamingImages) {
        _controller?.stopImageStream();
      }
    } catch (_) {}
    _latestFrame = null;
  }

  /// 切换前后摄像头
  Future<void> switchCamera(List<CameraDescription> cameras) async {
    if (cameras.length < 2) return;
    final wasCapturing = _isCapturing;
    if (wasCapturing) stopCapture();
    final currentDir = _controller?.description.lensDirection;
    final nextDir = currentDir == CameraLensDirection.back
        ? CameraLensDirection.front
        : CameraLensDirection.back;
    final next = cameras.firstWhere(
      (c) => c.lensDirection == nextDir,
      orElse: () => cameras.first,
    );

    try {
      await _controller?.dispose();
    } catch (_) {}
    _controller = CameraController(
      next,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.bgra8888,
    );
    try {
      await _controller!.initialize();
      if (wasCapturing) startCapture();
    } catch (e) {
      onError?.call('摄像头切换失败: $e');
    }
  }

  // 对焦状态
  bool _autoFocus = true;
  bool get autoFocus => _autoFocus;

  /// 切换自动/手动对焦模式
  /// - true:  连续自动对焦（默认启动时）
  /// - false: 锁定自动对焦，等待手动点击指定对焦点
  Future<void> setAutoFocus(bool enabled) async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    _autoFocus = enabled;
    try {
      if (enabled) {
        // 恢复连续自动对焦：先 locked 再 auto，强制 sensor 重新跑一次 AF cycle
        await _controller!.setFocusMode(FocusMode.locked);
        await _controller!.setFocusMode(FocusMode.auto);
      } else {
        // 锁定自动对焦：用户点击屏幕后会再调用 setFocusPoint
        await _controller!.setFocusMode(FocusMode.locked);
      }
    } catch (_) {
      // 部分设备/前置摄像头不支持，忽略
    }
  }

  /// 强制触发一次自动对焦（不切换模式）
  /// 用于「画面静止时 iOS continuous AF 懒得对」的兜底：
  /// 先 locked 再 auto，强制 sensor 重新跑一次 AF cycle。
  Future<void> triggerAutoFocus() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (!_autoFocus) return; // 手动模式下不抢
    try {
      await _controller!.setFocusMode(FocusMode.locked);
      await _controller!.setFocusMode(FocusMode.auto);
    } catch (_) {}
  }

  /// 手动点击对焦：屏幕坐标 → 摄像头归一化坐标 [0, 1]
  /// [screenPoint] 屏幕点击位置（逻辑像素）
  /// [previewSize] 摄像头预览原始尺寸
  /// [renderRect] 摄像头画面在屏幕上的实际显示矩形（含 BoxFit.cover 裁剪）
  Future<void> setFocusPoint(
    Offset screenPoint, {
    required Size previewSize,
    required Rect renderRect,
  }) async {
    if (_controller == null || !_controller!.value.isInitialized) {
      debugPrint('[Focus] SKIP: controller null or not initialized');
      return;
    }
    if (renderRect.isEmpty) {
      debugPrint('[Focus] SKIP: renderRect is empty');
      return;
    }

    // 1) 屏幕坐标 → 预览显示区域内的相对坐标 [0, 1]
    final double dx = (screenPoint.dx - renderRect.left) / renderRect.width;
    final double dy = (screenPoint.dy - renderRect.top) / renderRect.height;
    debugPrint(
      '[Focus] tap screen=(${"${screenPoint.dx.toStringAsFixed(1)}"},'
      '"${screenPoint.dy.toStringAsFixed(1)}") '
      'renderRect=$renderRect '
      'previewSize=$previewSize '
      '→ normalized=(${"${dx.toStringAsFixed(3)}"},'
      '"${dy.toStringAsFixed(3)}")',
    );
    if (dx < 0 || dx > 1 || dy < 0 || dy > 1) {
      debugPrint('[Focus] SKIP: tap outside preview rect (likely on cover-crop area)');
      return;
    }

    // 2) camera 插件内部已对 sensor 方向做过补偿：setFocusPoint 接受的
    //    (dx, dy) 是相对预览视图的归一化坐标 [0, 1]，原点在左上角，
    //    方向与屏幕一致。直接传点击位置归一化后的值即可。
    final Offset point = Offset(dx, dy);
    try {
      await _controller!.setFocusPoint(point);
      debugPrint('[Focus] setFocusPoint($point) ok');
      // 同步设置测光点（曝光跟对焦联动）
      await _controller!.setExposurePoint(point);
      debugPrint('[Focus] setExposurePoint($point) ok');
      // 触发一次自动对焦完成合焦（点按即对焦）
      // 关键修复：先 locked 再 auto，强制 sensor 跑 AF cycle，
      // 否则 iOS 某些设备上 setFocusPoint 后 AF 不会真正合焦
      await _controller!.setFocusMode(FocusMode.locked);
      await _controller!.setFocusMode(FocusMode.auto);
      debugPrint('[Focus] setFocusMode locked→auto ok');
    } catch (e, st) {
      // 记录原始错误而非静默吞掉，便于排查"对焦像没生效"的情况
      debugPrint('[Focus] FAILED: $e\n$st');
    }
  }

  // ==============================
  // 周期性自动对焦心跳
  // ==============================
  // iOS continuous AF 在画面静止（无运动）时会「懒得对」，
  // 表现：用户静止看屏幕时画面失焦。周期性在中心点 (0.5, 0.5) 调用
  // setFocusPoint + setFocusMode(auto) 强制 sensor 跑 AF。
  // 频率 4s 一次：避免太频繁导致 sensor 抖动 / 暗光场景下「拉风箱」。
  Timer? _afHeartbeatTimer;
  static const Duration _afHeartbeatInterval = Duration(seconds: 4);
  static const Offset _afHeartbeatPoint = Offset(0.5, 0.5);

  void _startAfHeartbeat() {
    _afHeartbeatTimer?.cancel();
    _afHeartbeatTimer = Timer.periodic(_afHeartbeatInterval, (_) => _afHeartbeatTick());
  }

  void _stopAfHeartbeat() {
    _afHeartbeatTimer?.cancel();
    _afHeartbeatTimer = null;
  }

  Future<void> _afHeartbeatTick() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (!_autoFocus) return; // 手动模式下不抢
    if (!_isCapturing) return; // idle 状态节能
    try {
      // 用中心点（0.5, 0.5）调用 setFocusPoint + setFocusMode 强制 AF cycle
      await _controller!.setFocusPoint(_afHeartbeatPoint);
      await _controller!.setFocusMode(FocusMode.auto);
    } catch (_) {}
  }

  /// 闪光灯开关
  Future<void> setFlash(bool on) async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    try {
      await _controller!.setFlashMode(on ? FlashMode.torch : FlashMode.off);
    } catch (_) {}
  }

  // 最近一次收到的视频帧（BGRA 原始像素）
  CameraImage? _pendingImage;
  // 标记：当前帧是否已"消费"（用于节流：每 800ms 取一次最新帧）
  bool _frameConsumed = true;

  /// 视频流回调：仅缓存最新帧，不在此处做耗时的 JPG 编码（避免丢帧）
  void _onImageStream(CameraImage image) {
    _pendingImage = image;
    _frameConsumed = false;
  }

  Future<void> _captureFrame() async {
    if (!_isCapturing || _controller == null || !_controller!.value.isInitialized) return;
    if (_frameConsumed || _pendingImage == null) return;

    final image = _pendingImage!;
    _frameConsumed = true;
    _frameIndex++;

    try {
      // 从原始 BGRA 像素直接缩放到目标长边 + 编码 JPG
      // （绕过 ImageCompressor 的「先编 JPG 再解码再编 JPG」两次有损路径，最清晰）
      final jpgBytes = _bgraToJpgLongEdgeScaled(
        image,
        targetLongEdge: _targetLongEdge,
        quality: _jpegQuality,
      );

      onFrameCaptured?.call(jpgBytes);
      _latestFrame = jpgBytes;
      await _uploadFrame(jpgBytes);
    } catch (e) {
      // 单帧失败不中断抽帧
    }
  }

  /// BGRA 原始像素 → 长边 ≤ targetLongEdge 的等比缩放 → JPG 字节
  /// 比 ImageCompressor 少一次「编码→解码」往返，画质明显更好。
  Uint8List _bgraToJpgLongEdgeScaled(
    CameraImage image, {
    required int targetLongEdge,
    required int quality,
  }) {
    if (image.planes.length != 1) {
      throw UnsupportedError('Expected single-plane BGRA image, got ${image.planes.length}');
    }
    final plane = image.planes[0];
    final int srcW = image.width;
    final int srcH = image.height;

    int? rowStride;
    int bytesOffset = 0;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      rowStride = plane.bytesPerRow;
      bytesOffset = 28; // iOS 相机 BGRA 的固定 stride 偏移
    }

    final decoded = img.Image.fromBytes(
      width: srcW,
      height: srcH,
      bytes: plane.bytes.buffer,
      order: img.ChannelOrder.bgra,
      numChannels: 4,
      rowStride: rowStride,
      bytesOffset: bytesOffset,
    );

    // 等比目标尺寸：长边 = targetLongEdge
    int dstW, dstH;
    if (srcW >= srcH) {
      dstW = targetLongEdge;
      dstH = (srcH * targetLongEdge / srcW).round();
    } else {
      dstH = targetLongEdge;
      dstW = (srcW * targetLongEdge / srcH).round();
    }
    // 目标 ≥ 源时直接编 JPG（避免放大插值）
    if (dstW >= srcW && dstH >= srcH) {
      return Uint8List.fromList(img.encodeJpg(decoded, quality: quality.clamp(55, 100)));
    }

    final scaled = img.copyResize(
      decoded,
      width: dstW,
      height: dstH,
      interpolation: img.Interpolation.cubic, // 双三次，画质比 linear 好
    );
    return Uint8List.fromList(img.encodeJpg(scaled, quality: quality.clamp(55, 100)));
  }

  Future<void> _uploadFrame(Uint8List jpgBytes) async {
    final encoded = base64Encode(jpgBytes);
    try {
      await _httpClient?.post(
        Uri.parse('$baseUrl/upload/frame'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'ctxId': sessionId,
          'frame': encoded,
          'index': _frameIndex,
        }),
      );
    } catch (_) {}
  }

  /// 最新一帧的JPG数据（供离线VL推理使用）
  Uint8List? getLatestFrame() => _latestFrame;

  CameraController? get controller => _controller;

  Future<void> dispose() async {
    stopCapture();
    await _controller?.dispose();
    _controller = null;
    _httpClient?.close();
    _httpClient = null;
  }
}
