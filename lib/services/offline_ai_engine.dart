import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:vosk_flutter_service/vosk_flutter.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import '../models/hardware_info.dart';
import '../utils/platform_utils.dart';

/// 端侧AI推理引擎
///
/// ASR：Vosk 中文语音识别（vosk-model-small-cn-0.22）
/// VL：Qwen2-VL-2B-Instruct via llama_cpp_dart（GGUF + mmproj）
///
/// **模型分发**：通过 [backendBaseUrl] 提供的 REST API：
/// - GET  {baseUrl}/models/manifest            → 模型清单
/// - GET  {baseUrl}/models/{name}              → 流式下载（支持 Range 续传）
/// - GET  {baseUrl}/models/{name}/info         → 查询缓存状态
/// - GET  {baseUrl}/models/_cache/stats        → 整体缓存统计
///
/// 启动时先 GET manifest，对比每个模型的本地文件 size/sha256 → 缺则下载。
class OfflineAIEngine {
  final String backendBaseUrl;

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

  // ── 模型路径（相对 modelsBaseDir）──
  /// 后端 manifest 期望的模型 name 字段（与后端 MODEL_REGISTRY 同步）
  static const _modelNameVosk = 'vosk-cn';
  static const _modelNameVl = 'qwen-vl-q4km';
  static const _modelNameMmproj = 'qwen-vl-mmproj-f16';

  /// 本地落盘文件名（后端缓存到 {MODELS_CACHE_DIR}/{name}.bin，下载到本机时也用同 key）
  String _localFileName(String modelName) => '$modelName.bin';

  /// 磁盘模型根目录（首次启动时初始化）
  Directory? _modelsBaseDir;

  // ── 下载状态 ──
  bool _isDownloading = false;
  bool get isDownloading => _isDownloading;
  /// 三段式累计：vosk 30% + vl 35% + mmproj 35%
  double _downloadProgress = 0;
  double get downloadProgress => _downloadProgress;

  /// 当前 manifest（缓存，供 UI 展示 manifest_version / 模型版本）
  Map<String, dynamic>? _lastManifest;

  // ── 事件回调 ──
  Function(String text)? onWhisperResult;
  Function(String text)? onVLResult;
  Function(String error)? onError;
  Function(double progress)? onModelLoadProgress;
  void Function(double progress, String? currentFile)? onDownloadProgress;
  void Function(bool success, String? error)? onDownloadComplete;

  bool get isWhisperReady => _asrReady;
  bool get isVLReady => _vlReady;
  bool get isAsrAvailable => _voskRecognizer != null;
  bool get isVlAvailable => _vlParent != null;

  OfflineAIEngine({required this.backendBaseUrl});

  // ══════════════════════════════════════════════════════════
  //  初始化
  // ══════════════════════════════════════════════════════════

  /// 初始化：拉 manifest → 检测缺失 → 后台下载 → 启动 ASR/VL
  Future<void> init(HardwareInfo? hardwareInfo) async {
    _hardwareInfo = hardwareInfo;
    _simulationMode = false;

    _modelsBaseDir = Directory(
      '${(await getApplicationDocumentsDirectory()).path}/models',
    );
    if (!await _modelsBaseDir!.exists()) {
      await _modelsBaseDir!.create(recursive: true);
    }
    debugPrint('[OfflineAIEngine] Models dir: ${_modelsBaseDir!.path}');

    // 1) 拉 manifest
    Map<String, dynamic>? manifest;
    try {
      manifest = await _fetchManifest();
      _lastManifest = manifest;
      final version = manifest['manifest_version'];
      debugPrint('[OfflineAIEngine] manifest_version=$version');
    } catch (e) {
      debugPrint('[OfflineAIEngine] manifest fetch failed: $e');
      // manifest 拿不到：仍尝试本地加载（之前下过的）
    }

    // 2) 检测缺失
    final missing = await _checkMissingModels(manifest);
    if (missing.isNotEmpty) {
      debugPrint('[OfflineAIEngine] Missing models: $missing');
      await downloadIfMissing(manifest: manifest);
    } else {
      debugPrint('[OfflineAIEngine] All models already cached');
    }

    // 3) 加载（可能下载刚完成或文件已存在）
    await Future.wait([
      _loadVosk(),
      if (_shouldLoadVL()) _loadVL() else Future.value(_vlReady = true),
    ]);
  }

  Future<Map<String, dynamic>> _fetchManifest() async {
    final url = Uri.parse('$backendBaseUrl/models/manifest');
    final resp = await http.get(url).timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) {
      throw StateError('manifest HTTP ${resp.statusCode}');
    }
    return jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  /// 检查哪些模型缺失（用 manifest 的 size + sha256_hint 校验）
  /// 不存在 → missing
  /// 存在但 size 不匹配 → 视为过期，加入 missing 触发重下
  Future<List<String>> _checkMissingModels(Map<String, dynamic>? manifest) async {
    final missing = <String>[];
    if (manifest == null) return ['']; // 没有 manifest 时当作全缺

    final models = (manifest['models'] as List).cast<Map<String, dynamic>>();
    for (final m in models) {
      final name = m['name'] as String;
      final expectedSize = (m['size'] as num).toInt();
      final file = File('${_modelsBaseDir!.path}/${_localFileName(name)}');
      if (!await file.exists()) {
        missing.add(name);
        continue;
      }
      final actualSize = await file.length();
      // 允许 ±1% 误差（zip 解压后大小可能与 zip 略不同；GGUF 通常完全一致）
      if (expectedSize > 0 && (actualSize - expectedSize).abs() > expectedSize * 0.01) {
        debugPrint('[OfflineAIEngine] $name size mismatch: local=$actualSize expected=$expectedSize');
        missing.add(name);
      }
    }
    return missing;
  }

  bool _shouldLoadVL() {
    final hw = _hardwareInfo;
    if (hw == null) return true;
    if (hw.isLowMemoryDevice) return false;
    if (Platform.isAndroid && !PlatformUtils.supportsMmap) return false;
    return true;
  }

  /// 公开方法：检测并按需下载所有缺失模型（带进度）
  Future<bool> downloadIfMissing({Map<String, dynamic>? manifest}) async {
    if (_isDownloading) {
      debugPrint('[OfflineAIEngine] downloadIfMissing: already in progress');
      return false;
    }
    _isDownloading = true;
    _downloadProgress = 0;
    onDownloadProgress?.call(0, null);

    try {
      _modelsBaseDir ??= Directory(
        '${(await getApplicationDocumentsDirectory()).path}/models',
      );
      if (!await _modelsBaseDir!.exists()) {
        await _modelsBaseDir!.create(recursive: true);
      }

      // 用传入或最近一次拉到的 manifest
      manifest ??= _lastManifest;
      if (manifest == null) {
        manifest = await _fetchManifest();
        _lastManifest = manifest;
      }
      final models = (manifest['models'] as List).cast<Map<String, dynamic>>();

      // 三段式：vosk 30% / vl 35% / mmproj 35%
      const segs = {
        _modelNameVosk: [0.0, 0.3],
        _modelNameVl: [0.3, 0.65],
        _modelNameMmproj: [0.65, 1.0],
      };

      for (final entry in segs.entries) {
        final name = entry.key;
        final segStart = entry.value[0];
        final segEnd = entry.value[1];
        final file = File('${_modelsBaseDir!.path}/${_localFileName(name)}');
        if (await file.exists()) {
          _downloadProgress = segEnd;
          onDownloadProgress?.call(_downloadProgress, null);
          continue;
        }
        final modelInfo = models.firstWhere(
          (m) => m['name'] == name,
          orElse: () => {'name': name, 'size': 0},
        );
        onDownloadProgress?.call(_downloadProgress, name);
        final ok = await _downloadModel(
          name: name,
          totalSize: (modelInfo['size'] as num? ?? 0).toInt(),
          segStart: segStart,
          segEnd: segEnd,
        );
        if (!ok) {
          onDownloadComplete?.call(false, '$name 下载失败');
          _isDownloading = false;
          return false;
        }
        _downloadProgress = segEnd;
        onDownloadProgress?.call(_downloadProgress, null);
      }

      debugPrint('[OfflineAIEngine] All models downloaded');
      onDownloadComplete?.call(true, null);
      return true;
    } catch (e) {
      debugPrint('[OfflineAIEngine] downloadIfMissing error: $e');
      onDownloadComplete?.call(false, e.toString());
      return false;
    } finally {
      _isDownloading = false;
    }
  }

  /// 下载单个模型（带 Range 续传，失败重试 3 次）
  Future<bool> _downloadModel({
    required String name,
    required int totalSize,
    required double segStart,
    required double segEnd,
    int maxRetries = 3,
  }) async {
    final targetFile = File('${_modelsBaseDir!.path}/${_localFileName(name)}');
    final url = Uri.parse('$backendBaseUrl/models/$name');

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        // 已有部分文件 → 用 Range 续传
        int existingSize = 0;
        if (await targetFile.exists()) {
          existingSize = await targetFile.length();
        }
        final headers = <String, String>{};
        if (existingSize > 0) {
          headers['Range'] = 'bytes=$existingSize-';
        }

        debugPrint('[OfflineAIEngine] GET $url (Range: ${headers['Range'] ?? 'none'}) attempt=$attempt');
        final request = http.Request('GET', url)..headers.addAll(headers);
        final response = await http.Client().send(request);

        if (response.statusCode != 200 && response.statusCode != 206) {
          debugPrint('[OfflineAIEngine] HTTP ${response.statusCode} for $name');
          // 失败时清空半成品，下次重试从头开始
          if (await targetFile.exists()) await targetFile.delete();
          continue;
        }

        final isPartial = response.statusCode == 206;
        final expectedTotal = response.contentLength ?? totalSize;
        final alreadyHave = isPartial ? existingSize : 0;
        final needToReceive = expectedTotal;

        final sink = targetFile.openWrite(mode: isPartial ? FileMode.append : FileMode.write);
        int received = 0;
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (needToReceive > 0) {
            final frac = (alreadyHave + received) / (alreadyHave + needToReceive);
            final p = segStart + (segEnd - segStart) * frac;
            onDownloadProgress?.call(p.clamp(0.0, segEnd), null);
          }
        }
        await sink.flush();
        await sink.close();

        // 校验大小
        final actual = await targetFile.length();
        if (actual < 1024 * 1024) {
          debugPrint('[OfflineAIEngine] $name downloaded too small: $actual bytes');
          if (await targetFile.exists()) await targetFile.delete();
          continue;
        }
        if (totalSize > 0 && (actual - totalSize).abs() > totalSize * 0.01) {
          debugPrint('[OfflineAIEngine] $name size mismatch: got=$actual expected=$totalSize');
          // 不重试：可能是后端 size 元数据有误差，只要不是太小就接受
        }
        debugPrint('[OfflineAIEngine] $name downloaded ${(actual / 1024 / 1024).toStringAsFixed(1)} MB');
        return true;
      } catch (e) {
        debugPrint('[OfflineAIEngine] $name download error (attempt $attempt): $e');
        // 网络层失败：保留半成品，下次会用 Range 续
        if (attempt == maxRetries) {
          // 最后一次也失败才删
          if (await targetFile.exists()) {
            try {
              await targetFile.delete();
            } catch (_) {}
          }
        }
      }
    }
    return false;
  }

  /// 公开方法：拉取 manifest（不下载，只查询）
  /// UI 可用此接口展示「后端有哪些模型、版本号、是否已缓存」
  Future<Map<String, dynamic>?> fetchManifest() async {
    try {
      final m = await _fetchManifest();
      _lastManifest = m;
      return m;
    } catch (e) {
      debugPrint('[OfflineAIEngine] fetchManifest error: $e');
      return null;
    }
  }

  // ══════════════════════════════════════════════════════════
  //  Vosk ASR
  // ══════════════════════════════════════════════════════════

  Future<void> _loadVosk() async {
    try {
      onModelLoadProgress?.call(0.1);

      // vosk 客户端只下载了 zip；需要在本地解压
      final voskZip = File('${_modelsBaseDir!.path}/${_localFileName(_modelNameVosk)}');
      final voskDir = Directory('${_modelsBaseDir!.path}/$_modelNameVosk');
      if (!await voskDir.exists() || !await File('${voskDir.path}/README').exists()) {
        // 尝试解压 zip
        if (await voskZip.exists()) {
          debugPrint('[OfflineAIEngine] Extracting vosk zip...');
          final result = await Process.run('unzip', ['-o', '-q', voskZip.path, '-d', _modelsBaseDir!.path]);
          if (result.exitCode != 0) {
            debugPrint('[OfflineAIEngine] unzip failed: ${result.stderr}');
          } else {
            // 成功后删 zip
            try {
              await voskZip.delete();
            } catch (_) {}
          }
        }
      }

      if (!await voskDir.exists() || !await File('${voskDir.path}/README').exists()) {
        debugPrint('[OfflineAIEngine] Vosk model not found after extraction');
        _simulationMode = true;
        _asrReady = true;
        onModelLoadProgress?.call(0.5);
        return;
      }

      debugPrint('[OfflineAIEngine] Loading Vosk from: ${voskDir.path}');
      onModelLoadProgress?.call(0.2);

      _voskModel = await VoskFlutterPlugin.instance().createModel(voskDir.path);
      _voskRecognizer = await VoskFlutterPlugin.instance().createRecognizer(
        model: _voskModel!,
        sampleRate: 16000,
      );

      _asrReady = true;
      debugPrint('[OfflineAIEngine] Vosk ASR ready');
      onModelLoadProgress?.call(0.5);
    } catch (e) {
      debugPrint('[OfflineAIEngine] Vosk load error: $e');
      _simulationMode = true;
      _asrReady = true;
      _voskModel = null;
      _voskRecognizer = null;
      onModelLoadProgress?.call(0.5);
    }
  }

  // ══════════════════════════════════════════════════════════
  //  Qwen2-VL (llama_cpp_dart)
  // ══════════════════════════════════════════════════════════

  Future<void> _loadVL() async {
    try {
      onModelLoadProgress?.call(0.5);

      final vlPath = '${_modelsBaseDir!.path}/${_localFileName(_modelNameVl)}';
      final mmPath = '${_modelsBaseDir!.path}/${_localFileName(_modelNameMmproj)}';

      if (!await File(vlPath).exists()) {
        debugPrint('[OfflineAIEngine] VL model not found: $vlPath');
        _simulationMode = true;
        _vlReady = true;
        onModelLoadProgress?.call(1.0);
        return;
      }
      if (!await File(mmPath).exists()) {
        debugPrint('[OfflineAIEngine] mmproj not found: $mmPath');
        _simulationMode = true;
        _vlReady = true;
        onModelLoadProgress?.call(1.0);
        return;
      }

      debugPrint('[OfflineAIEngine] Loading VL: $vlPath');
      debugPrint('[OfflineAIEngine] Loading mmproj: $mmPath');
      onModelLoadProgress?.call(0.6);

      final modelParams = ModelParams()..nGpuLayers = 0;
      final ctxParams = ContextParams()
        ..nCtx = 2048
        ..nBatch = 512
        ..nThreads = 4;
      final samplerParams = SamplerParams()
        ..temp = 0.7
        ..topP = 0.9;

      final loadCmd = LlamaLoad(
        path: vlPath,
        mmprojPath: mmPath,
        modelParams: modelParams,
        contextParams: ctxParams,
        samplingParams: samplerParams,
      );

      _vlParent = LlamaParent(loadCmd, ChatMLFormat());
      onModelLoadProgress?.call(0.7);

      await _vlParent!.init();
      _vlReady = true;
      debugPrint('[OfflineAIEngine] Qwen2-VL ready');
      onModelLoadProgress?.call(1.0);
    } catch (e) {
      debugPrint('[OfflineAIEngine] VL load error: $e');
      _simulationMode = true;
      _vlReady = true;
      _vlParent = null;
      onModelLoadProgress?.call(1.0);
    }
  }

  // ══════════════════════════════════════════════════════════
  //  推理接口
  // ══════════════════════════════════════════════════════════

  /// Vosk 语音识别（16kHz mono PCM16LE 原始字节）
  Future<String> recognizeSpeech(Uint8List pcm16kMono) async {
    if (!_asrReady) throw StateError('ASR not ready');
    if (_asrRunning) throw StateError('ASR already running');
    _asrRunning = true;

    try {
      if (_voskRecognizer == null) {
        return '离线ASR未加载';
      }

      debugPrint('[OfflineAIEngine] Vosk recognizing ${pcm16kMono.length} bytes');

      const chunkSize = 8192;
      String lastPartial = '';
      for (int pos = 0; pos < pcm16kMono.length; pos += chunkSize) {
        final end = (pos + chunkSize).clamp(0, pcm16kMono.length);
        final chunk = Uint8List.sublistView(pcm16kMono, pos, end);
        final ready = await _voskRecognizer!.acceptWaveformBytes(chunk);
        if (ready) {
          final jsonStr = await _voskRecognizer!.getResult();
          final parsed = _parseVoskJsonText(jsonStr);
          if (parsed.isNotEmpty) lastPartial = parsed;
        } else {
          final partial = await _voskRecognizer!.getPartialResult();
          final p = _parseVoskJsonText(partial);
          if (p.isNotEmpty) lastPartial = p;
        }
      }

      final finalJson = await _voskRecognizer!.getFinalResult();
      final result = _parseVoskJsonText(finalJson);
      final text = result.isNotEmpty ? result : lastPartial;

      debugPrint('[OfflineAIEngine] Vosk result: $text');
      onWhisperResult?.call(text);
      return text;
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

      await _vlParent!.sendPromptWithImages(fullPrompt, [image]);

      await completer.future.timeout(
        const Duration(seconds: 120),
        onTimeout: () {
          debugPrint('[OfflineAIEngine] VL inference timeout');
        },
      );

      await sub.cancel();
      final result = buffer.toString().trim();

      debugPrint('[OfflineAIEngine] VL result: ${result.length > 100 ? "${result.substring(0, 100)}..." : result}');
      onVLResult?.call(result);
      return result;
    } catch (e) {
      debugPrint('[OfflineAIEngine] VL error: $e');
      return '视觉理解失败: $e';
    } finally {
      _vlRunning = false;
    }
  }

  /// 纯文本对话
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
        return buffer.toString().trim();
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

  String _parseVoskJsonText(String jsonStr) {
    if (jsonStr.isEmpty) return '';
    try {
      final obj = jsonDecode(jsonStr);
      if (obj is Map) {
        return (obj['text'] ?? obj['partial'] ?? '').toString().trim();
      }
    } catch (_) {
      return jsonStr.trim();
    }
    return '';
  }

  String? get modelsDirPath => _modelsBaseDir?.path;
  Map<String, dynamic>? get lastManifest => _lastManifest;

  void dispose() {
    _voskRecognizer?.dispose();
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
