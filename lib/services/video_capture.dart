import 'dart:async';
import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import '../utils/image_compressor.dart';

/// 摄像头抽帧服务
/// 使用 startImageStream 从视频流抽帧（避免 takePicture 的快门声）
/// 每800ms抽一帧，分辨率640x480，JPG质量65压缩，POST上传
class VideoCaptureService {
  final String baseUrl;
  final String sessionId;

  CameraController? _controller;
  Timer? _captureTimer;
  bool _isCapturing = false;
  int _frameIndex = 0;
  Uint8List? _latestFrame;

  static const int _captureIntervalMs = 800;
  static const int _targetWidth = 640;
  static const int _targetHeight = 480;
  static const int _jpegQuality = 65;

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
      ResolutionPreset.low, // 低分辨率，实际抽帧时会重压缩
      enableAudio: false,
      // BGRA8888 让 startImageStream 拿到原始像素，避开 takePicture 的快门声。
      // Android 上用 YUV420 也行；这里统一用 BGRA，iOS/Android 都支持。
      imageFormatGroup: ImageFormatGroup.bgra8888,
    );

    try {
      await _controller!.initialize();
      _httpClient = http.Client();
      onCameraReady?.call();
    } catch (e) {
      onError?.call('摄像头初始化失败: $e');
    }
  }

  /// 开始抽帧（使用视频流模式，无快门声）
  void startCapture() {
    if (_isCapturing || _controller == null || !_controller!.value.isInitialized) return;
    _isCapturing = true;
    _frameIndex = 0;

    // 启动视频流：每帧回调 onImage，转 JPG 后再按 800ms 节流上传
    _controller!.startImageStream(_onImageStream);

    _captureTimer = Timer.periodic(
      const Duration(milliseconds: _captureIntervalMs),
      (_) => _captureFrame(),
    );
  }

  /// 停止抽帧（idle状态节能）
  void stopCapture() {
    _isCapturing = false;
    _captureTimer?.cancel();
    _captureTimer = null;
    try {
      _controller?.stopImageStream();
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

    await _controller?.dispose();
    _controller = CameraController(
      next,
      ResolutionPreset.low,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.bgra8888,
    );
    await _controller!.initialize();

    if (wasCapturing) startCapture();
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
      // 1) BGRA 原始像素 → JPG
      final jpgBytes = await _cameraImageToJpg(image);
      // 2) 压缩到目标尺寸
      final compressed = await ImageCompressor.compress(
        jpgBytes,
        width: _targetWidth,
        height: _targetHeight,
        quality: _jpegQuality,
      );

      onFrameCaptured?.call(compressed);
      _latestFrame = compressed;
      await _uploadFrame(compressed);
    } catch (e) {
      // 单帧失败不中断抽帧
    }
  }

  /// 把 CameraImage (BGRA) 转成原始 JPG 字节
  /// 关键修复：之前用 takePicture() 会触发 iOS 系统快门声
  /// （参 https://github.com/flutter/flutter/issues/26960），
  /// 改用 startImageStream 从视频流抽帧就完全没有声音。
  Future<Uint8List> _cameraImageToJpg(CameraImage image) async {
    // BGRA8888: 单 plane，width * height * 4 字节
    if (image.planes.length != 1) {
      throw UnsupportedError('Expected single-plane BGRA image, got ${image.planes.length}');
    }
    final plane = image.planes[0];
    final int width = image.width;
    final int height = image.height;

    // iOS 上 camera 插件返回的 BGRA plane 带 rowStride 对齐（可能 > width*4），
    // 必须显式传 rowStride 和 bytesOffset，否则图像右侧会多出一条黑边。
    // 参考：https://stackoverflow.com/questions/78440306
    int? rowStride;
    int bytesOffset = 0;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      rowStride = plane.bytesPerRow;
      bytesOffset = 28; // iOS 相机 BGRA 的固定 stride 偏移
    }

    final decoded = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: plane.bytes.buffer,
      order: img.ChannelOrder.bgra,
      numChannels: 4,
      rowStride: rowStride,
      bytesOffset: bytesOffset,
    );

    return Uint8List.fromList(img.encodeJpg(decoded, quality: 90));
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
