import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../models/hardware_info.dart';
import '../utils/platform_utils.dart';

/// 端侧AI推理引擎
/// 负责 Whisper（ASR）和 Qwen-VL（GGUF via llama_cpp_dart）的加载与调度
/// 当前为模拟模式：tflite_flutter 因网络问题暂时移除，完整推理待集成 llama_cpp_dart
class OfflineAIEngine {
  bool _whisperReady = false;
  bool _vlReady = false;
  bool _whisperRunning = false;
  bool _vlRunning = false;
  bool _simulationMode = true; // 默认模拟模式，llama_cpp_dart 集成后改为 false
  bool get isSimulationMode => _simulationMode;

  HardwareInfo? _hardwareInfo;

  /// llama_cpp_dart 0.2.x LlamaParent（Isolate，非阻塞）
  dynamic _vlLlamaParent;

  Function(String text)? onWhisperResult;
  Function(String text)? onVLResult;
  Function(String error)? onError;
  Function(double progress)? onModelLoadProgress;

  bool get isWhisperReady => _whisperReady;
  bool get isVLReady => _vlReady;

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

  Future<void> _loadWhisper() async {
    try {
      final modelPath = await _getModelPath('models/whisper-tiny.gguf');
      if (modelPath != null) {
        debugPrint('[OfflineAIEngine] Whisper GGUF found at: $modelPath');
        debugPrint('[OfflineAIEngine]   llama_cpp_dart 集成中，请确保 libllama 已正确放置');
      } else {
        debugPrint('[OfflineAIEngine] Whisper model not found, simulation mode');
      }
      _whisperReady = true;
      onModelLoadProgress?.call(1.0);
    } catch (e) {
      debugPrint('[OfflineAIEngine] Whisper load error: $e');
      _simulationMode = true;
      _whisperReady = true;
      onModelLoadProgress?.call(1.0);
    }
  }

  Future<String?> _getModelPath(String assetPath) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final privateFile = File('${appDir.path}/$assetPath');
      if (await privateFile.exists()) {
        debugPrint('[OfflineAIEngine] Model from private dir: $assetPath');
        return privateFile.path;
      }

      final assetKey = 'assets/$assetPath';
      final manifestContent = await rootBundle.loadString('AssetManifest.json');
      final manifest = jsonDecode(manifestContent) as Map<String, dynamic>;
      if (manifest.containsKey(assetKey)) {
        debugPrint('[OfflineAIEngine] Model from assets: $assetKey');
        return assetKey;
      }
      return null;
    } catch (e) {
      debugPrint('[OfflineAIEngine] _getModelPath error for $assetPath: $e');
      return null;
    }
  }

  Future<void> _loadVL() async {
    try {
      final modelPath = await _getModelPath('models/Qwen2-VL-2B-Q4_K_M.gguf');
      if (modelPath == null) {
        debugPrint('[OfflineAIEngine] VL model not found, simulation mode');
        _simulationMode = true;
        _vlReady = true;
        onModelLoadProgress?.call(1.0);
        return;
      }

      onModelLoadProgress?.call(0.5);
      debugPrint('[OfflineAIEngine] VL GGUF from: $modelPath');

      try {
        debugPrint('[OfflineAIEngine] VL GGUF skipped — native binary not placed');
        debugPrint('[OfflineAIEngine]   Android: libllama.so in jniLibs/arm64-v8a/');
        debugPrint('[OfflineAIEngine]   iOS/macOS: libllama.xcframework in Xcode');
        _vlReady = true;
      } catch (e) {
        debugPrint('[OfflineAIEngine] VL load error: $e, simulation mode');
        _simulationMode = true;
        _vlReady = true;
      }

      onModelLoadProgress?.call(1.0);
    } catch (e) {
      debugPrint('[OfflineAIEngine] VL load error: $e, simulation mode');
      _simulationMode = true;
      _vlReady = true;
      onModelLoadProgress?.call(1.0);
    }
  }

  Future<String> recognizeSpeech(Uint8List pcm16kMono) async {
    if (!_whisperReady) throw StateError('Whisper not ready');
    if (_whisperRunning) throw StateError('Whisper already running');
    _whisperRunning = true;
    try {
      if (_vlLlamaParent != null) {
        debugPrint('[OfflineAIEngine] Running Whisper on ${pcm16kMono.length} bytes (GGUF)');
        await Future.delayed(const Duration(milliseconds: 300));
        final result = '模拟识别文本（llama_cpp_dart 未集成）';
        onWhisperResult?.call(result);
        return result;
      }
      await Future.delayed(const Duration(milliseconds: 300));
      final result = '模拟识别文本（Whisper 未加载）';
      onWhisperResult?.call(result);
      return result;
    } finally {
      _whisperRunning = false;
    }
  }

  Future<String> understandImage(Uint8List imageBytes, String prompt) async {
    if (!_vlReady) throw StateError('Qwen-VL not ready');
    if (_vlRunning) throw StateError('VL already running');
    _vlRunning = true;
    try {
      if (_vlLlamaParent != null) {
        debugPrint('[OfflineAIEngine] Qwen-VL inference, image: ${imageBytes.length} bytes');
        await Future.delayed(const Duration(milliseconds: 500));
        final result = '模拟视觉理解结果（请集成Qwen-VL GGUF模型）';
        onVLResult?.call(result);
        return result;
      }
      await Future.delayed(const Duration(milliseconds: 500));
      final result = '模拟视觉理解结果（Qwen-VL 未加载）';
      onVLResult?.call(result);
      return result;
    } finally {
      _vlRunning = false;
    }
  }

  Future<String> chat(String text, {String? imageContext}) async {
    if (!_whisperReady) throw StateError('Engine not ready');
    debugPrint('[OfflineAIEngine] Running offline chat: $text');
    await Future.delayed(const Duration(milliseconds: 500));
    return '模拟回复（请集成完整端侧模型）';
  }

  void dispose() {
    _vlLlamaParent = null;
    _whisperReady = false;
    _vlReady = false;
    _whisperRunning = false;
    _vlRunning = false;
    debugPrint('[OfflineAIEngine] disposed');
  }
}
