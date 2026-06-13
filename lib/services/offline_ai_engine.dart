import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vosk_flutter/vosk_flutter.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import '../models/hardware_info.dart';
import '../utils/platform_utils.dart';

/// 端侧AI推理引擎
/// ASR：Vosk 中文语音识别（vosk-model-small-cn-0.22）
/// VL：Qwen2-VL-2B via llama_cpp_dart（GGUF + mmproj）
class OfflineAIEngine {
  bool _asrReady = false;
  bool _vlReady = false;
  bool _asrRunning = false;
  bool _vlRunning = false;
  bool _simulationMode = false;
  bool get isSimulationMode => _simulationMode;

  HardwareInfo? _hardwareInfo;

  // ── Vosk ASR ──
  Model? _voskModel;
  Recognizer? _voskRecognizer;

  // ── llama_cpp_dart VL ──
  LlamaParent? _vlParent;

  // ── 模型路径常量 ──
  static const _voskAssetDir = 'models/vosk-model-small-cn-0.22';
  static const _vlModelAsset = 'models/Qwen2-VL-2B-Instruct-Q4_K_M.gguf';
  static const _mmprojAsset = 'models/mmproj-Qwen2-VL-2B-Instruct-f16.gguf';

  Function(String text)? onWhisperResult;
  Function(String text)? onVLResult;
  Function(String error)? onError;
  Function(double progress)? onModelLoadProgress;

  bool get isWhisperReady => _asrReady;
  bool get isVLReady => _vlReady;

  Future<void> init(HardwareInfo? hardwareInfo) async {
    _hardwareInfo = hardwareInfo;
    _simulationMode = false;

    await _loadVosk();
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

  // ══════════════════════════════════════════════════════════
  //  Vosk ASR
  // ══════════════════════════════════════════════════════════

  Future<void> _loadVosk() async {
    try {
      onModelLoadProgress?.call(0.1);

      // 将 Vosk 模型从 assets 解压到临时目录（native 库需要文件系统路径）
      final modelPath = await _extractAssetDirToTemp(_voskAssetDir);
      if (modelPath == null) {
        debugPrint('[OfflineAIEngine] Vosk model dir not found in assets');
        _simulationMode = true;
        _asrReady = true;
        onModelLoadProgress?.call(1.0);
        return;
      }

      debugPrint('[OfflineAIEngine] Loading Vosk model from: $modelPath');
      onModelLoadProgress?.call(0.5);

      _voskModel = await Model.create(modelPath);
      _voskRecognizer = await Recognizer.create(_voskModel!, 16000);

      _asrReady = true;
      debugPrint('[OfflineAIEngine] Vosk ASR ready');
      onModelLoadProgress?.call(1.0);
    } catch (e) {
      debugPrint('[OfflineAIEngine] Vosk load error: $e, simulation mode');
      _simulationMode = true;
      _asrReady = true;
      onModelLoadProgress?.call(1.0);
    }
  }

  // ══════════════════════════════════════════════════════════
  //  Qwen2-VL (llama_cpp_dart)
  // ══════════════════════════════════════════════════════════

  Future<void> _loadVL() async {
    try {
      onModelLoadProgress?.call(0.1);

      // 解压 VL GGUF + mmproj 到临时目录
      final vlPath = await _extractAssetToTemp(_vlModelAsset);
      final mmPath = await _extractAssetToTemp(_mmprojAsset);

      if (vlPath == null) {
        debugPrint('[OfflineAIEngine] VL model not found: $_vlModelAsset');
        _vlReady = true;
        onModelLoadProgress?.call(1.0);
        return;
      }
      if (mmPath == null) {
        debugPrint('[OfflineAIEngine] mmproj not found: $_mmprojAsset');
        _vlReady = true;
        onModelLoadProgress?.call(1.0);
        return;
      }

      debugPrint('[OfflineAIEngine] Loading VL: $vlPath');
      debugPrint('[OfflineAIEngine] Loading mmproj: $mmPath');
      onModelLoadProgress?.call(0.3);

      final loadCmd = LlamaLoad(
        path: vlPath,
        mmprojPath: mmPath,
        modelParams: ModelParams(nGpuLayers: 0), // CPU only
        contextParams: ContextParams(nCtx: 2048, nBatch: 512, nThreads: 4),
        samplingParams: SamplerParams(temp: 0.7, topP: 0.9),
      );

      _vlParent = LlamaParent(loadCmd, ChatmlFormat());
      onModelLoadProgress?.call(0.5);

      await _vlParent!.init();
      _vlReady = true;
      debugPrint('[OfflineAIEngine] Qwen2-VL ready');
      onModelLoadProgress?.call(1.0);
    } catch (e) {
      debugPrint('[OfflineAIEngine] VL load error: $e');
      _vlReady = true; // 标记 ready 但保持 simulation mode
      onModelLoadProgress?.call(1.0);
    }
  }

  // ══════════════════════════════════════════════════════════
  //  推理接口
  // ══════════════════════════════════════════════════════════

  /// Vosk 语音识别（16kHz mono PCM16）
  Future<String> recognizeSpeech(Uint8List pcm16kMono) async {
    if (!_asrReady) throw StateError('ASR not ready');
    if (_asrRunning) throw StateError('ASR already running');
    _asrRunning = true;

    try {
      if (_voskRecognizer == null) {
        return '离线ASR未加载';
      }

      debugPrint('[OfflineAIEngine] Vosk recognizing ${pcm16kMono.length} bytes');

      // 送入音频并获取最终结果
      _voskRecognizer!.acceptWaveformBytes(pcm16kMono);
      final result = await _voskRecognizer!.getFinalResult();

      debugPrint('[OfflineAIEngine] Vosk result: $result');
      onWhisperResult?.call(result);
      return result;
    } catch (e) {
      debugPrint('[OfflineAIEngine] ASR error: $e');
      return '语音识别失败: $e';
    } finally {
      _asrRunning = false;
    }
  }

  /// Qwen2-VL 视觉理解（图文推理）
  Future<String> understandImage(Uint8List imageBytes, String prompt) async {
    if (!_vlReady) throw StateError('VL not ready');
    if (_vlRunning) throw StateError('VL already running');
    _vlRunning = true;

    try {
      if (_vlParent == null) {
        return '视觉模型未加载';
      }

      debugPrint('[OfflineAIEngine] Qwen-VL inference, image: ${imageBytes.length} bytes');

      final image = LlamaImage.fromBytes(imageBytes);
      final fullPrompt = '<image>\n$prompt';

      // 收集流式输出
      final buffer = StringBuffer();
      final completer = Completer<void>();

      final sub = _vlParent!.stream.listen(
        (token) => buffer.write(token),
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
        onError: (e) {
          if (!completer.isCompleted) completer.completeError(e);
        },
      );

      final promptId = await _vlParent!.sendPromptWithImages(fullPrompt, [image]);

      // 等待推理完成（超时 120 秒）
      await completer.future.timeout(
        const Duration(seconds: 120),
        onTimeout: () {
          debugPrint('[OfflineAIEngine] VL inference timeout');
        },
      );

      await sub.cancel();
      final result = buffer.toString();

      debugPrint('[OfflineAIEngine] VL result: $result');
      onVLResult?.call(result);
      return result;
    } catch (e) {
      debugPrint('[OfflineAIEngine] VL error: $e');
      return '视觉理解失败: $e';
    } finally {
      _vlRunning = false;
    }
  }

  /// 纯文本对话（离线 VL 推理）
  Future<String> chat(String text, {String? imageContext}) async {
    if (!_asrReady) throw StateError('Engine not ready');
    debugPrint('[OfflineAIEngine] Offline chat: $text');

    if (_vlParent != null) {
      try {
        final buffer = StringBuffer();
        final completer = Completer<void>();

        final sub = _vlParent!.stream.listen(
          (token) => buffer.write(token),
          onDone: () {
            if (!completer.isCompleted) completer.complete();
          },
          onError: (e) {
            if (!completer.isCompleted) completer.completeError(e);
          },
        );

        await _vlParent!.sendPrompt(text);
        await completer.future.timeout(const Duration(seconds: 60));
        await sub.cancel();
        return buffer.toString();
      } catch (e) {
        debugPrint('[OfflineAIEngine] Chat error: $e');
        return '离线对话失败: $e';
      }
    }

    return '离线模型未加载';
  }

  // ══════════════════════════════════════════════════════════
  //  工具方法
  // ══════════════════════════════════════════════════════════

  /// 从 assets 复制单个文件到临时目录，返回文件系统路径
  Future<String?> _extractAssetToTemp(String assetKey) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final targetPath = '${tempDir.path}/$assetKey';
      final targetFile = File(targetPath);

      if (await targetFile.exists()) {
        return targetPath;
      }

      // 尝试从 assets 加载
      final byteData = await rootBundle.load('assets/$assetKey');
      await targetFile.parent.create(recursive: true);
      await targetFile.writeAsBytes(byteData.buffer.asUint8List());
      debugPrint('[OfflineAIEngine] Extracted asset: $assetKey (${byteData.lengthInBytes} bytes)');
      return targetPath;
    } catch (e) {
      debugPrint('[OfflineAIEngine] Failed to extract $assetKey: $e');
      return null;
    }
  }

  /// 从 assets 解压整个目录到临时目录（Vosk 模型等多文件模型）
  Future<String?> _extractAssetDirToTemp(String dirAssetKey) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final targetDir = Directory('${tempDir.path}/$dirAssetKey');

      // 如果已解压，直接返回
      if (await targetDir.exists()) {
        final files = targetDir.listSync();
        if (files.isNotEmpty) return targetDir.path;
      }

      // 读取 AssetManifest 找到该目录下的所有文件
      final manifestContent = await rootBundle.loadString('AssetManifest.json');
      final manifest = jsonDecode(manifestContent) as Map<String, dynamic>;
      final prefix = 'assets/$dirAssetKey/';

      final assetFiles = manifest.keys.where((k) => k.startsWith(prefix)).toList();
      if (assetFiles.isEmpty) {
        debugPrint('[OfflineAIEngine] No assets found for $dirAssetKey');
        return null;
      }

      await targetDir.create(recursive: true);

      for (final assetKey in assetFiles) {
        final relativePath = assetKey.substring(prefix.length);
        final targetFile = File('${targetDir.path}/$relativePath');
        await targetFile.parent.create(recursive: true);
        final byteData = await rootBundle.load(assetKey);
        await targetFile.writeAsBytes(byteData.buffer.asUint8List());
      }

      debugPrint('[OfflineAIEngine] Extracted ${assetFiles.length} files for $dirAssetKey');
      return targetDir.path;
    } catch (e) {
      debugPrint('[OfflineAIEngine] Failed to extract dir $dirAssetKey: $e');
      return null;
    }
  }

  void dispose() {
    _voskRecognizer?.close();
    _voskModel?.dispose();
    _voskRecognizer = null;
    _voskModel = null;

    _vlParent?.dispose();
    _vlParent = null;

    _asrReady = false;
    _vlReady = false;
    _asrRunning = false;
    _vlRunning = false;
    debugPrint('[OfflineAIEngine] disposed');
  }
}
