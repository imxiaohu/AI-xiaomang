import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import '../models/hardware_info.dart';
import '../utils/platform_utils.dart';

/// 端侧AI推理引擎
/// 负责 Whisper-tiny（TFLite）和 Qwen-VL（GGUF via llama_cpp_dart）的加载与调度
class OfflineAIEngine {
  bool _whisperReady = false;
  bool _vlReady = false;
  bool _whisperRunning = false;
  bool _vlRunning = false;
  bool _simulationMode = false; // 模型未加载，进入模拟对话模式
  bool get isSimulationMode => _simulationMode;

  HardwareInfo? _hardwareInfo;
  Interpreter? _whisperInterpreter;

  /// llama_cpp_dart 0.2.x LlamaParent（Isolate，非阻塞）
  dynamic _vlLlamaParent;

  Function(String text)? onWhisperResult;
  Function(String text)? onVLResult;
  Function(String error)? onError;
  Function(double progress)? onModelLoadProgress;

  /// Whisper tokenizer: token_id → decoded string
  Map<int, String>? _vocab;

  bool get isWhisperReady => _whisperReady;
  bool get isVLReady => _vlReady;

  Future<void> init(HardwareInfo? hardwareInfo) async {
    _hardwareInfo = hardwareInfo;
    await _loadWhisper();
    await _loadTokenizer();
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

  // ─── Whisper TFLite ────────────────────────────────────────────────

  Future<void> _loadWhisper() async {
    try {
      // 优先私有目录，再 fallback assets
      String? modelPath;
      for (final name in [
        'whisper-tiny-transcribe-translate.tflite',
        'whisper-tiny-int8.tflite',
      ]) {
        modelPath = await _getModelPath(name);
        if (modelPath != null) break;
      }

      if (modelPath == null) {
        debugPrint('[OfflineAIEngine] Whisper model not found, simulation mode');
        _simulationMode = true;
        _whisperReady = true;
        onModelLoadProgress?.call(1.0);
        return;
      }

      onModelLoadProgress?.call(0.2);
      debugPrint('[OfflineAIEngine] Loading Whisper TFLite from: $modelPath');

      try {
        if (modelPath.startsWith('assets/')) {
          _whisperInterpreter = await Interpreter.fromAsset(
            modelPath,
            options: InterpreterOptions()..threads = 4,
          );
        } else {
          _whisperInterpreter = Interpreter.fromFile(
            File(modelPath),
            options: InterpreterOptions()..threads = 4,
          );
        }

        _logInterpreterSignature();
        onModelLoadProgress?.call(0.8);
        _whisperReady = true;
        onModelLoadProgress?.call(1.0);
        debugPrint('[OfflineAIEngine] Whisper-tiny loaded successfully');
      } catch (e, st) {
        debugPrint('[OfflineAIEngine] TFLite load error: $e\n$st');
        _simulationMode = true;
        _whisperReady = true;
        onModelLoadProgress?.call(1.0);
      }
    } catch (e) {
      debugPrint('[OfflineAIEngine] Whisper load error: $e');
      _simulationMode = true;
      _whisperReady = true;
      onModelLoadProgress?.call(1.0);
    }
  }

  void _logInterpreterSignature() {
    if (_whisperInterpreter == null) return;
    try {
      final inputs = _whisperInterpreter!.getInputTensors();
      final outputs = _whisperInterpreter!.getOutputTensors();
      for (final t in inputs) {
        debugPrint('[Whisper] Input: name=${t.name} shape=${t.shape} type=${t.type}');
      }
      for (final t in outputs) {
        debugPrint('[Whisper] Output: name=${t.name} shape=${t.shape} type=${t.type}');
      }
    } catch (_) {}
  }

  Future<void> _loadTokenizer() async {
    try {
      final data = await rootBundle.loadString('assets/whisper_tiny_vocab.json');
      final Map<String, dynamic> raw = jsonDecode(data);
      _vocab = {for (final e in raw.entries) int.parse(e.key): e.value as String};
      debugPrint('[Whisper] Tokenizer loaded: ${_vocab!.length} tokens');
    } catch (e) {
      debugPrint('[Whisper] Tokenizer load failed: $e, using fallback');
    }
  }

  // ─── Qwen-VL GGUF ────────────────────────────────────────────────

  Future<void> _loadVL() async {
    try {
      final modelPath = await _getModelPath('models/Qwen-VL-2B-Q4_K_M.gguf');
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
        // llama_cpp_dart 0.2.x:
        // import 'package:llama_cpp_dart/llama_cpp_dart.dart';
        // Llama.libraryPath = <platform_specific>;
        // _vlLlamaParent = LlamaParent(LlamaLoad(path: modelPath));
        // await _vlLlamaParent.init();
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

  Future<String?> _getModelPath(String assetPath) async {
    // assetPath 格式: "models/Qwen-VL-2B-Q4_K_M.gguf" 或 "whisper-tiny.tflite"
    // 优先从用户私有目录加载（支持运行时下载更新），fallback 到 assets 打包
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final privateFile = File('${appDir.path}/$assetPath');
      if (await privateFile.exists()) {
        debugPrint('[OfflineAIEngine] Model from private dir: $assetPath');
        return privateFile.path;
      }

      // assets 路径格式: "assets/models/xxx.gguf"
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

  // ─── Whisper ASR 推理管线 ─────────────────────────────────────────

  Future<String> recognizeSpeech(Uint8List pcm16kMono) async {
    if (!_whisperReady) throw StateError('Whisper not ready');
    if (_whisperRunning) throw StateError('Whisper already running');
    _whisperRunning = true;
    try {
      if (_whisperInterpreter != null) {
        debugPrint('[OfflineAIEngine] Running Whisper on ${pcm16kMono.length} bytes');
        final mel = _pcmToMel(pcm16kMono);
        final text = await _runWhisper(mel);
        onWhisperResult?.call(text);
        return text;
      }
      await Future.delayed(const Duration(milliseconds: 300));
      final result = '模拟识别文本（tflite_flutter 未加载）';
      onWhisperResult?.call(result);
      return result;
    } finally {
      _whisperRunning = false;
    }
  }

  /// PCM 16K mono → Mel Spectrogram [80, 3000]
  /// Whisper 固定参数：n_mels=80, n_fft=400, hop_length=160, fmin=0, fmax=3000
  Float32List _pcmToMel(Uint8List pcmBytes) {
    const nMels = 80;
    const nFft = 400;
    const hopLength = 160;
    const nFrames = 3000;

    final samples = Int16List.view(
      pcmBytes.buffer, pcmBytes.offsetInBytes, pcmBytes.length ~/ 2);
    final nSamples = samples.length;

    // 归一化 [-32768,32768] → [-1, 1]
    final normalized = Float32List(nSamples);
    for (int i = 0; i < nSamples; i++) {
      normalized[i] = samples[i] / 32768.0;
    }

    // Mel 滤波器组预计算
    final melFilter = _melFilterbank(16000, nFft, nMels);
    final result = Float32List(nMels * nFrames);

    for (int frame = 0; frame < nFrames; frame++) {
      final start = frame * hopLength;

      // 加窗 + 提取
      final window = Float32List(nFft);
      for (int i = 0; i < nFft; i++) {
        final sIdx = start + i;
        if (sIdx < nSamples) {
          final win = 0.5 * (1 - math.cos(2 * math.pi * i / (nFft - 1)));
          window[i] = normalized[sIdx] * win;
        }
      }

      // FFT → 功率谱
      final fft = _rfft(window);
      const nFreq = 200; // nFft/2
      final powSpec = Float32List(nFreq);
      for (int k = 0; k < nFreq; k++) {
        final re = fft[k * 2];
        final im = k * 2 + 1 < fft.length ? fft[k * 2 + 1] : 0.0;
        powSpec[k] = math.max(re * re + im * im, 1e-10);
      }

      // Mel 乘积 + log
      for (int m = 0; m < nMels; m++) {
        double sum = 0.0;
        for (int k = 0; k < nFreq; k++) {
          sum += powSpec[k] * melFilter[m * nFreq + k];
        }
        result[m * nFrames + frame] = math.log(math.max(sum, 1e-10));
      }
    }

    return result;
  }

  /// 离散傅里叶变换（O(n²)，窗口小，够用）
  Float32List _rfft(Float32List window) {
    final n = window.length;
    final real = Float32List(n * 2);
    for (int k = 0; k < n; k++) {
      double re = 0, im = 0;
      for (int t = 0; t < n; t++) {
        final angle = -2 * math.pi * k * t / n;
        re += window[t] * math.cos(angle);
        im += window[t] * math.sin(angle);
      }
      real[k * 2] = re;
      real[k * 2 + 1] = im;
    }
    return real;
  }

  /// Mel 滤波器组（fMax=3000Hz，whisper-tiny 固定参数）
  Float32List _melFilterbank(int sampleRate, int nFft, int nMels) {
    const fMax = 3000.0;
    final nFreq = nFft ~/ 2;
    final hzMax = math.min(fMax, sampleRate / 2.0);
    final melMin = 2595 * math.log(1 + 0 / 700);
    final melMax = 2595 * math.log(1 + hzMax / 700);
    final melStep = (melMax - melMin) / (nMels + 1);

    final result = Float32List(nMels * nFreq);

    for (int m = 0; m < nMels; m++) {
      for (int k = 0; k < nFreq; k++) {
        final freq = k * sampleRate / nFft;
        final melFreq = 2595 * math.log(1 + freq / 700);
        final lower = (melFreq - (melMin + m * melStep)) / (melStep / 2);
        final upper = ((melMin + (m + 1) * melStep) - melFreq) / (melStep / 2);
        double weight;
        if (lower <= 0) {
          weight = (1.0 + lower).clamp(0.0, 1.0);
        } else if (upper <= 0) {
          weight = (1.0 + upper).clamp(0.0, 1.0);
        } else {
          weight = 1.0;
        }
        result[m * nFreq + k] = weight;
      }
    }
    return result;
  }

  /// Whisper TFLite 推理 + 贪婪解码
  Future<String> _runWhisper(Float32List mel) async {
    final interpreter = _whisperInterpreter!;

    final inputs = interpreter.getInputTensors();
    final outputs = interpreter.getOutputTensors();

    if (inputs.isEmpty || outputs.isEmpty) {
      throw StateError('TFLite model has no input/output tensors');
    }

    final inputShape = inputs[0].shape;
    final outputShape = outputs[0].shape;
    debugPrint('[Whisper] input: $inputShape, output: $outputShape');

    // DocWolle whisper-tiny-transcribe-translate.tflite: [1, 80, 3000] → [1, seq, vocab]
    if (inputShape.length == 3 && inputShape[1] == 80 && inputShape[2] == 3000) {
      return _runTranscribe(interpreter, mel, inputShape, outputShape);
    }

    debugPrint('[Whisper] Unknown signature: $inputShape, simulation mode');
    return '模型签名不匹配，请使用 whisper-tiny-transcribe-translate.tflite';
  }

  Future<String> _runTranscribe(
    Interpreter interpreter,
    Float32List mel,
    List<int> inputShape,
    List<int> outputShape,
  ) async {
    final batch = inputShape[0];
    final nMels = inputShape[1];
    final nFrames = inputShape[2];

    // 填充 mel [batch, 80, 3000]
    final inputBuffer = Float32List(batch * nMels * nFrames);
    final copyLen = math.min(mel.length, nMels * nFrames);
    inputBuffer.setRange(0, copyLen, mel);

    // 输出 [batch, seq, vocab]
    final vocabSize = outputShape.length >= 3 ? outputShape[2] : 51866;
    final maxSeq = outputShape.length >= 2 ? outputShape[1] : 150;
    final outputBuffer = Float32List(batch * maxSeq * vocabSize);

    interpreter.run(inputBuffer, outputBuffer);

    // 贪婪解码
    const eosToken = 50257;
    final tokens = <int>[];
    for (int t = 0; t < maxSeq; t++) {
      double maxProb = double.negativeInfinity;
      int bestToken = 0;
      for (int v = 0; v < vocabSize; v++) {
        final p = outputBuffer[t * vocabSize + v];
        if (p > maxProb) {
          maxProb = p;
          bestToken = v;
        }
      }
      if (bestToken == eosToken) break;
      if (bestToken > 3 && bestToken < 50364) {
        tokens.add(bestToken);
      }
    }

    debugPrint('[Whisper] Decoded ${tokens.length} tokens');
    return _decodeTokens(tokens);
  }

  /// BPE token → 文本
  String _decodeTokens(List<int> tokens) {
    if (tokens.isEmpty) return '';
    if (_vocab != null) {
      final sb = StringBuffer();
      for (final tid in tokens) {
        final text = _vocab![tid];
        if (text != null) sb.write(text);
      }
      return _cleanupWhisperText(sb.toString());
    }
    return '[ASR: vocab未加载, tokens=${tokens.take(20).toList()}]';
  }

  String _cleanupWhisperText(String text) {
    if (text.isEmpty) return '';
    text = text.replaceAll(RegExp(r' +'), ' ');
    text = text.replaceAll(RegExp(r' +\n'), '\n');
    text = text.replaceAll(RegExp(r'\n +'), '\n');
    return text.trim();
  }

  // ─── Qwen-VL 视觉理解 ─────────────────────────────────────────────

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

  // ─── 纯文本对话 ──────────────────────────────────────────────────

  Future<String> chat(String text, {String? imageContext}) async {
    if (!_whisperReady) throw StateError('Engine not ready');
    debugPrint('[OfflineAIEngine] Running offline chat: $text');
    await Future.delayed(const Duration(milliseconds: 500));
    return '模拟回复（请集成完整端侧模型）';
  }

  // ─── 资源释放 ────────────────────────────────────────────────────

  void dispose() {
    _whisperInterpreter?.close();
    _whisperInterpreter = null;
    _vlLlamaParent = null;
    _whisperReady = false;
    _vlReady = false;
    _whisperRunning = false;
    _vlRunning = false;
    _vocab = null;
    debugPrint('[OfflineAIEngine] disposed');
  }
}
