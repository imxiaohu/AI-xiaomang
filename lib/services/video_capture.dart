import 'dart:async';
import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../utils/image_compressor.dart';

/// 摄像头抽帧服务
/// 每800ms抽一帧，分辨率强制640x480，JPG质量65压缩，POST上传
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
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await _controller!.initialize();
      // 设置帧分辨率（CameraController不直接支持，但底层会按ResolutionPreset采集）
      onCameraReady?.call();
    } catch (e) {
      onError?.call('摄像头初始化失败: $e');
    }
  }

  /// 开始抽帧
  void startCapture() {
    if (_isCapturing || _controller == null || !_controller!.value.isInitialized) return;
    _isCapturing = true;
    _frameIndex = 0;

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
    _latestFrame = null;
  }

  /// 切换前后摄像头
  Future<void> switchCamera(List<CameraDescription> cameras) async {
    if (cameras.length < 2) return;
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
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    await _controller!.initialize();

    if (_isCapturing) {
      stopCapture();
      startCapture();
    }
  }

  /// 闪光灯开关
  Future<void> setFlash(bool on) async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    try {
      await _controller!.setFlashMode(on ? FlashMode.torch : FlashMode.off);
    } catch (_) {}
  }

  Future<void> _captureFrame() async {
    if (!_isCapturing || _controller == null || !_controller!.value.isInitialized) return;
    _frameIndex++;

    try {
      final xFile = await _controller!.takePicture();
      final originalBytes = await xFile.readAsBytes();

      // 压缩到640x480，JPG质量65
      final compressed = await ImageCompressor.compress(
        originalBytes,
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

  Future<void> _uploadFrame(Uint8List jpgBytes) async {
    final encoded = base64Encode(jpgBytes);
    try {
      final client = http.Client();
      await client.post(
        Uri.parse('$baseUrl/upload/frame'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'ctxId': sessionId,
          'frame': encoded,
          'index': _frameIndex,
        }),
      );
      client.close();
    } catch (_) {}
  }

  /// 最新一帧的JPG数据（供离线VL推理使用）
  Uint8List? getLatestFrame() => _latestFrame;

  CameraController? get controller => _controller;

  Future<void> dispose() async {
    stopCapture();
    await _controller?.dispose();
    _controller = null;
  }
}

