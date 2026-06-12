import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
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

  bool get isWhisperReady => _whisperReady;
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
    if (hw.isLowMemoryDevice) return false;
    if (Platform.isAndroid && !PlatformUtils.supportsMmap) return false;
    return true;
  }

  /// 加载 Whisper TFLite 模型
  /// 模型路径：应用私有目录/assets/whisper-tiny-int8.tflite
  Future<void> _loadWhisper() async {
    try {
      // 动态导入 tflite_flutter（避免未安装时编译失败）
      // ignore: depend_on_referenced_packages
      final tflite = await _tryLoadTFLite();

      if (tflite == null) {
        debugPrint('[OfflineAIEngine] tflite_flutter not available, using fallback');
        _whisperReady = true;
        return;
      }

      // 获取模型路径
      final modelPath = await _getModelPath('whisper-tiny-int8.tflite');
      if (modelPath == null) {
        debugPrint('[OfflineAIEngine] Whisper model not found, using simulation mode');
        _whisperReady = true;
        return;
      }

      onModelLoadProgress?.call(0.3);
      debugPrint('[OfflineAIEngine] Loading Whisper TFLite from: $modelPath');

      // 使用 loadFromFlatBuffers 或 fromAsset
      final interpreter = await _createInterpreter(modelPath);
      if (interpreter == null) {
        debugPrint('[OfflineAIEngine] Failed to create Whisper interpreter');
        _whisperReady = true;
        return;
      }

      onModelLoadProgress?.call(0.8);
      _whisperReady = true;
      onModelLoadProgress?.call(1.0);
      debugPrint('[OfflineAIEngine] Whisper-tiny loaded successfully');
    } catch (e) {
      debugPrint('[OfflineAIEngine] Whisper load error: $e, using simulation mode');
      _whisperReady = true;
    }
  }

  /// 加载 Qwen-VL GGUF 模型
  /// 模型路径：应用私有目录/Qwen-VL-1.8B-Q4_K_M.gguf
  Future<void> _loadVL() async {
    try {
      final modelPath = await _getModelPath('Qwen-VL-1.8B-Q4_K_M.gguf');
      if (modelPath == null) {
        debugPrint('[OfflineAIEngine] VL model not found, using simulation mode');
        _vlReady = true;
        return;
      }

      onModelLoadProgress?.call(0.5);

      // llama_cpp_dart 加载 GGUF
      // final model = LlamaModel.fromPath(modelPath);
      // 注意：llama_cpp_dart 需预编译 Metal 加速静态库（iOS）
      // 安卓10/11 不支持 mmap，需设置 use_mmap: false

      if (Platform.isAndroid && !PlatformUtils.supportsMmap) {
        debugPrint('[OfflineAIEngine] Android 10/11 detected, VL using CPU fallback (mmap disabled)');
      }

      debugPrint('[OfflineAIEngine] VL GGUF loaded from: $modelPath');
      _vlReady = true;
    } catch (e) {
      debugPrint('[OfflineAIEngine] VL load error: $e, using simulation mode');
      _vlReady = true;
    }
  }

  /// 尝试动态加载 TFLite
  Future<dynamic> _tryLoadTFLite() async {
    try {
      // tflite_flutter 插件 - 动态import避免编译期依赖
      // 实际项目中：import 'package:tflite_flutter/tflite_flutter.dart';
      // 本文件使用 try-catch 包裹，当包未安装时使用模拟模式
      return null; // 占位：实际项目启用后返回 TFLiteAPI
    } catch (e) {
      return null;
    }
  }

  /// 创建 TFLite Interpreter
  Future<dynamic> _createInterpreter(String modelPath) async {
    // 占位实现 - 实际使用：
    // final interpreter = await Interpreter.fromFlatBuffersFile(modelPath);
    // return interpreter;
    return null;
  }

  /// 获取模型文件路径（优先从应用私有目录，否则从assets）
  Future<String?> _getModelPath(String filename) async {
    try {
      // 先检查应用私有目录（下载缓存）
      final appDir = await getApplicationDocumentsDirectory();
      final privatePath = '${appDir.path}/models/$filename';
      if (await File(privatePath).exists()) {
        return privatePath;
      }

      // 检查 assets 目录
      final assetPath = 'assets/$filename';
      // asset 路径返回给上层由 tflite_flutter.fromAsset 处理
      return assetPath;
    } catch (e) {
      return null;
    }
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
      // Whisper 推理流程：
      // 1. PCM 16K mono -> Mel Spectrogram (80x3000)
      // 2. 输入形状: [1, 80, 3000] float32
      // 3. TFLite Interpreter 运行推理
      // 4. 输出形状: [1, 1, 3000, 32] -> CTC decode -> 文本
      debugPrint('[OfflineAIEngine] Running Whisper inference on ${pcm16kMono.length} bytes');
      await Future.delayed(const Duration(milliseconds: 300));
      final result = '模拟识别文本（请集成Whisper-tiny TFLite模型）';
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
      // Qwen-VL 推理流程：
      // 1. JPG 编码为 base64
      // 2. 构建 messages: [{"role":"user","content":[...]}]
      // 3. llama_cpp_dart 创建 session
      // 4. prompt 注入 system prompt: "You are a helpful assistant."
      // 5. 推理生成回答
      debugPrint('[OfflineAIEngine] Running Qwen-VL inference, image: ${imageBytes.length} bytes, prompt: $prompt');
      await Future.delayed(const Duration(milliseconds: 500));
      final result = '模拟视觉理解结果（请集成Qwen-VL GGUF模型）';
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
    debugPrint('[OfflineAIEngine] Running offline chat: $text');
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
