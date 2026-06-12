import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../models/hardware_info.dart';
import '../utils/platform_utils.dart';

/// 端侧AI推理引擎
/// 负责 Whisper-tiny（TFLite）和 Qwen-VL（GGUF）的加载与调度
class OfflineAIEngine {
  // 推理状态
  bool _whisperReady = false;
  bool _vlReady = false;
  bool _whisperRunning = false;
  bool _vlRunning = false;

  HardwareInfo? _hardwareInfo;

  // 回调
  Function(String text)? onWhisperResult;
  Function(String text)? onVLResult;
  Function(String error)? onError;
  Function(double progress)? onModelLoadProgress;

  bool get isReady => _whisperReady;
  bool get isVLReady => _vlReady;

  /// 初始化引擎（异步加载模型）
  Future<void> init(HardwareInfo? hardwareInfo) async {
    _hardwareInfo = hardwareInfo;
    await _loadWhisper();
    if (_shouldLoadVL()) {
      await _loadVL();
    }
  }

  bool _shouldLoadVL() {
    final hw = _hardwareInfo;
    if (hw == null) return true;
    // 内存≤4GB 或 Android10/11 禁用VL
    if (hw.isLowMemoryDevice) return false;
    if (Platform.isAndroid && !PlatformUtils.supportsMmap) return false;
    return true;
  }

  Future<void> _loadWhisper() async {
    // TODO(PR-13): 实际加载 whisper-tiny-int8.tflite
    // TFLite 模型禁止混淆（android.enableR8.full=false）
    onModelLoadProgress?.call(0.3);
    await Future.delayed(const Duration(milliseconds: 500));
    onModelLoadProgress?.call(0.6);
    await Future.delayed(const Duration(milliseconds: 500));
    onModelLoadProgress?.call(1.0);
    _whisperReady = true;
    debugPrint('[OfflineAIEngine] Whisper-tiny loaded');
  }

  Future<void> _loadVL() async {
    // TODO(PR-14): 实际加载 Qwen-VL-1.8B-Q4_K_M.gguf
    // GGUF 需要 llama_cpp_dart
    // 安卓10/11 不支持 mmap，需要 CPU fallback
    if (Platform.isAndroid && !PlatformUtils.supportsMmap) {
      debugPrint('[OfflineAIEngine] Android 10/11 detected, VL using CPU fallback');
    }
    await Future.delayed(const Duration(milliseconds: 500));
    _vlReady = true;
    debugPrint('[OfflineAIEngine] Qwen-VL loaded');
  }

  /// 语音识别（Whisper）
  /// [pcm16kMono] 16KHz 单声道 PCM 原始数据
  Future<String> recognizeSpeech(Uint8List pcm16kMono) async {
    if (!_whisperReady) {
      throw StateError('Whisper not ready');
    }
    if (_whisperRunning) {
      throw StateError('Whisper already running');
    }
    _whisperRunning = true;
    try {
      // TODO(PR-13): 实际调用 tflite_flutter 推理
      // 模拟推理
      await Future.delayed(const Duration(milliseconds: 500));
      final result = '模拟识别文本（请集成Whisper-tiny模型）';
      onWhisperResult?.call(result);
      return result;
    } finally {
      _whisperRunning = false;
    }
  }

  /// 视觉理解（Qwen-VL）
  /// [imageBytes] JPG 图片数据
  /// [prompt] 文本问题
  Future<String> understandImage(Uint8List imageBytes, String prompt) async {
    if (!_vlReady) {
      throw StateError('Qwen-VL not ready, memory may be insufficient');
    }
    if (_vlRunning) {
      throw StateError('VL already running');
    }
    _vlRunning = true;
    try {
      // TODO(PR-14): 实际调用 llama_cpp_dart 推理 GGUF
      await Future.delayed(const Duration(milliseconds: 1000));
      final result = '模拟视觉理解结果（请集成Qwen-VL模型）';
      onVLResult?.call(result);
      return result;
    } finally {
      _vlRunning = false;
    }
  }

  /// 对话（离线LLM）
  /// [text] 用户文本
  /// [imageContext] 可选的视觉上下文
  Future<String> chat(String text, {String? imageContext}) async {
    if (!_whisperReady) {
      throw StateError('Engine not ready');
    }
    // TODO(PR-13/14): 实际端侧LLM对话推理
    await Future.delayed(const Duration(milliseconds: 500));
    return '模拟回复（请集成完整端侧模型）';
  }

  /// 释放资源
  void dispose() {
    _whisperReady = false;
    _vlReady = false;
    _whisperRunning = false;
    _vlRunning = false;
    debugPrint('[OfflineAIEngine] disposed');
  }
}
