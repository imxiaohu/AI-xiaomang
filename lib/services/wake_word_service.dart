import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vosk_flutter_service/vosk_flutter.dart';

/// Vosk Grammar Mode 唤醒词服务
///
/// 工作原理：用 Vosk 中文 ASR 模型的 Grammar Mode 把 ASR 当作轻量级唤醒词引擎。
/// Grammar Mode 只识别指定短语列表（"小芒同学" + "[unk]"），
/// 检测到唤醒词时触发 onWakeWordDetected 回调。
///
/// 注意：
/// - [unk] 必须加入 grammar，否则遇到非目标词时识别器会卡住。
/// - 本服务持续监听麦克风，只有 AppState 空闲时才触发回调。
class WakeWordService {
  VoskFlutterPlugin? _vosk;
  Recognizer? _recognizer;
  SpeechService? _speechService;
  bool _isRunning = false;
  bool _paused = false;

  VoidCallback? onWakeWordDetected;

  bool get isRunning => _isRunning;

  /// 初始化并启动唤醒词检测
  Future<void> start() async {
    if (_isRunning) return;

    _vosk = VoskFlutterPlugin.instance();

    // 将 asset 目录中的模型复制到 documents 目录（原生插件从文件系统读取）
    final modelPath = await _copyAssetModelToDocuments(
      'assets/vosk-model-small-cn-0.22',
      'vosk-model-small-cn-0.22',
    );

    final model = await _vosk!.createModel(modelPath);
    _recognizer = await _vosk!.createRecognizer(
      model: model,
      sampleRate: 16000,
      grammar: ['小芒同学', '[unk]'],
    );

    _speechService = await _vosk!.initSpeechService(_recognizer!);

    _speechService!.onPartial().listen(_onPartial);
    _speechService!.onResult().listen(_onResult);

    await _speechService!.start();
    _isRunning = true;
    debugPrint('[WakeWordService] started (model: $modelPath)');
  }

  /// 将 asset 目录复制到 documents/models/ 目录（一次性操作）
  Future<String> _copyAssetModelToDocuments(
    String assetDir,
    String modelName,
  ) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final modelDestDir = Directory('${docsDir.path}/models/$modelName');

    if (await modelDestDir.exists()) {
      debugPrint('[WakeWordService] Model already copied to $modelDestDir');
      return modelDestDir.path;
    }

    await modelDestDir.create(recursive: true);

    final assetManifest = await rootBundle.loadString('AssetManifest.json');
    // 找出所有以 assetDir 为前缀的文件
    final prefix = assetDir.replaceFirst('assets/', '');
    final pattern = RegExp('"($prefix/[^"]+)"');
    final matches = pattern.allMatches(assetManifest);

    final files = matches
        .map((m) => m.group(1)!)
        .where((p) => !p.endsWith('/'))
        .toList();

    if (files.isEmpty) {
      throw Exception(
        'No files found in asset directory: $assetDir. '
        'Make sure pubspec.yaml includes: - $assetDir/',
      );
    }

    for (final filePath in files) {
      final relativePath = filePath.substring(prefix.length + 1);
      final destFile = File('${modelDestDir.path}/$relativePath');
      await destFile.parent.create(recursive: true);
      final data = await rootBundle.load('assets/$filePath');
      await destFile.writeAsBytes(data.buffer.asUint8List());
    }

    debugPrint('[WakeWordService] Copied ${files.length} model files to $modelDestDir');
    return modelDestDir.path;
  }

  void _onPartial(String partial) {}

  void _onResult(String result) {
    if (_paused) return;
    if (result.contains('小芒同学')) {
      debugPrint('[WakeWordService] Wake word detected!');
      onWakeWordDetected?.call();
    }
  }

  /// 暂停检测（AI 正在思考/说话时，避免重复触发）
  void pause() {
    _paused = true;
    debugPrint('[WakeWordService] paused');
  }

  /// 恢复检测
  void resume() {
    _paused = false;
    debugPrint('[WakeWordService] resumed');
  }

  void stop() {
    _isRunning = false;
    _speechService?.stop();
    _recognizer?.dispose();
    debugPrint('[WakeWordService] stopped');
  }

  void dispose() {
    stop();
  }
}
