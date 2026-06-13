import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import '../models/enums.dart';
import '../models/chat_message.dart';
import '../models/hardware_info.dart';
import '../services/sse_stream_service.dart';
import '../services/audio_recorder_service.dart';
import '../services/video_capture.dart';
import '../services/audio_player_service.dart';
import '../services/connectivity_service.dart';
import '../services/offline_ai_engine.dart';
import '../services/background_audio_service.dart';
import '../services/tripo_3d_service.dart';
import '../services/marketplace_service.dart';
import '../services/settings_service.dart';
import '../utils/tts_service.dart';
import '../config/env_config.dart';

/// 全局业务状态编排
/// 管理：SSE连接生命周期、录音/抽帧/推理/播报时序、自动降级触发
class AppState extends ChangeNotifier {

  // ==============================
  // 运行模式
  // 默认云端：connectCloud() 内置 max_reconnect 自动回退 offline
  // 这样启动时如果后端可达 → 走云端；不可达 → 自动 fallback offline
  // ==============================
  AppRunMode _runMode = AppRunMode.cloudAliyun;
  AppRunMode get runMode => _runMode;

  // ==============================
  // Omni 交互模式
  // ==============================
  OmniInteractionMode _omniMode = OmniInteractionMode.manual;
  OmniInteractionMode get omniMode => _omniMode;

  Future<void> setOmniMode(OmniInteractionMode mode) async {
    if (_omniMode == mode) return;
    final prevMode = _omniMode;
    _omniMode = mode;
    notifyListeners();
    // 通知后端切换模式
    await _sseService?.setMode(mode == OmniInteractionMode.vad ? 'vad' : 'manual');
    // 退出 VAD 模式时，停止持续录音 + 视频抽帧 + 后台保活，否则 mic 一直开着
    // 既耗电又把环境噪音也上传到后端
    if (prevMode == OmniInteractionMode.vad && mode != OmniInteractionMode.vad) {
      try {
        await _audioRecorder?.stopRecording();
      } catch (e) {
        debugPrint('[AppState] setOmniMode: stopRecorder on VAD exit threw: $e');
      }
      _videoCapture?.stopCapture();
      _backgroundService?.stop();
    }
  }

  // ==============================
  // AI状态
  // ==============================
  AiStatus _aiStatus = AiStatus.idle;
  AiStatus get aiStatus => _aiStatus;

  // ==============================
  // 连接状态
  // ==============================
  ConnectionStatus _connectionStatus = ConnectionStatus.disconnected;
  ConnectionStatus get connectionStatus => _connectionStatus;

  // ==============================
  // 降级等级
  // ==============================
  AiDegradationLevel _degradationLevel = AiDegradationLevel.full;
  AiDegradationLevel get degradationLevel => _degradationLevel;

  // ==============================
  // 硬件信息
  // ==============================
  HardwareInfo? _hardwareInfo;
  HardwareInfo? get hardwareInfo => _hardwareInfo;

  // ==============================
  // 摄像头
  // ==============================
  bool _cameraPermissionGranted = false;
  bool get cameraPermissionGranted => _cameraPermissionGranted;

  bool _micPermissionGranted = false;
  bool get micPermissionGranted => _micPermissionGranted;

  bool _flashOn = false;
  bool get flashOn => _flashOn;

  List<CameraDescription> _cameras = [];
  CameraController? _cameraController;
  CameraController? get cameraController => _cameraController;

  // ==============================
  // 对话
  // ==============================
  final List<ChatMessage> _messages = [];
  List<ChatMessage> get messages => List.unmodifiable(_messages);

  String _currentStreamingText = '';
  String get currentStreamingText => _currentStreamingText;
  bool _userMessageSaved = false; // 当前轮次用户转录是否已保存
  bool _vlTtsAudioStarted = false; // VL+TTS 模式：当前轮次是否已初始化音频流
  bool _omniAudioStarted = false; // Omni 模式：当前轮次是否已初始化音频流

  // 推理兜底计时器：thinking 超过 30s 自动 goIdle + 兜底消息
  Timer? _inferenceTimeoutTimer;
  static const int _inferenceTimeoutSeconds = 30;

  // ==============================
  // 录音
  // ==============================
  double _recordingSeconds = 0;
  double get recordingSeconds => _recordingSeconds;
  Timer? _recordingTimer;

  // ==============================
  // TTS音量（驱动球体动画）
  // ==============================
  double _ttsVolume = 0.5;
  double get ttsVolume => _ttsVolume;

  // ==============================
  // 对话面板
  // ==============================
  bool _chatPanelExpanded = false;
  bool get chatPanelExpanded => _chatPanelExpanded;

  // ==============================
  // 模型加载
  // ==============================
  double _modelLoadProgress = 0;
  bool _modelLoaded = false;
  // 兼容字段：保留旧名，但语义改为"无任何本地模型可用"
  bool _simulationMode = false;
  // 更细粒度的可用性：true 表示对应本地推理已就绪
  bool _asrAvailable = false;
  bool _vlAvailable = false;
  // 模型下载状态（首次启动需要从 ModelScope/HF 下载到磁盘）
  bool _isDownloading = false;
  double _downloadProgress = 0;
  String? _downloadCurrentFile; // 当前正在下载的模型名（给 UI 展示用）
  String? _downloadError;
  double get modelLoadProgress => _modelLoadProgress;
  bool get modelLoaded => _modelLoaded;
  bool get simulationMode => _simulationMode;
  bool get asrAvailable => _asrAvailable;
  bool get vlAvailable => _vlAvailable;
  bool get isDownloading => _isDownloading;
  double get downloadProgress => _downloadProgress;
  String? get downloadCurrentFile => _downloadCurrentFile;
  String? get downloadError => _downloadError;

  /// 离线模型根目录（供设置页展示）
  String? get offlineModelsDir => _offlineEngine?.modelsDirPath;

  /// 重新触发离线模型下载（设置页"重新下载"按钮）。
  /// 内部复用 OfflineAIEngine 现有的 [downloadIfMissing] 流程。
  Future<bool> retryOfflineDownload() async {
    if (_offlineEngine == null) return false;
    return _offlineEngine!.downloadIfMissing();
  }

  // ==============================
  // 网络
  // ==============================
  NetworkStatus _networkStatus = NetworkStatus.none;
  NetworkStatus get networkStatus => _networkStatus;

  // ==============================
  // 服务实例
  // ==============================
  SseStreamService? _sseService;
  AudioRecorderService? _audioRecorder;
  VideoCaptureService? _videoCapture;
  AudioPlayerService? _audioPlayer;
  ConnectivityService? _connectivity;
  TtsService? _ttsService;
  OfflineAIEngine? _offlineEngine;
  BackgroundAudioService? _backgroundService;
  MarketplaceService? _marketplaceService;

  // ==============================
  // 用户设置（持久化到 SharedPreferences）
  // ==============================
  AppSettings _settings = const AppSettings();
  AppSettings get settings => _settings;
  final SettingsService _settingsService = SettingsService();

  /// 解析后的后端基础 URL：优先用设置中的值，空则用编译期默认值。
  /// 所有需要后端 URL 的服务都应从这里取，而不是直接读 [BackendConfig.baseUrl]，
  /// 这样设置页改了「后端地址」后能立刻生效。
  String get backendBaseUrl =>
      _settings.backendUrl.isNotEmpty ? _settings.backendUrl : BackendConfig.baseUrl;

  /// 解析后的用户令牌（每次请求以 `X-User-Token` 头发送）
  String get authToken => _settings.authToken.isNotEmpty
      ? _settings.authToken
      : BackendConfig.defaultToken;

  // ==============================
  // 互斥锁
  // ==============================
  bool _modeSwitchLocked = false;
  Timer? _modeSwitchUnlockTimer;

  // ==============================
  // 静默超时
  // ==============================
  Timer? _idleTimer;
  static const int _idleTimeoutSeconds = 30;

  // ==============================
  // Session ID
  // ==============================
  String _sessionId = '';

  // ==============================
  // Tripo 3D生成
  // ==============================
  TripoService? _tripoService;
  String? _tripoTaskId;
  String? _tripoModelUrl;
  String? _tripoPreviewUrl;
  bool _tripoGenerating = false;
  double _tripoProgress = 0.0;
  String _tripoStatusText = '';
  String? _tripoError;
  bool _tripoCanCancel = false;
  DateTime? _tripoRunStart;

  String? get tripoTaskId => _tripoTaskId;
  String? get tripoModelUrl => _tripoModelUrl;
  String? get tripoPreviewUrl => _tripoPreviewUrl;
  bool get tripoGenerating => _tripoGenerating;
  double get tripoProgress => _tripoProgress;
  String get tripoStatusText => _tripoStatusText;
  String? get tripoError => _tripoError;
  bool get tripoCanCancel => _tripoCanCancel;

  // ==============================
  // 3D 形象市场
  // ==============================
  MarketplaceService get marketplace => _marketplaceService ??= MarketplaceService(
        baseUrl: backendBaseUrl,
        token: authToken,
      );

  // 当前正在用的市场模型（由设置页或市场页"选用"动作写入）。
  // 与"刚生成完"的临时任务不同：这是用户主动选定的、跨重启保留的造型。
  String? _activeMarketplaceModelId;
  String? get activeMarketplaceModelId => _activeMarketplaceModelId;
  // 当前选中的市场条目（懒加载）
  MarketplaceItem? _activeMarketplaceItem;
  MarketplaceItem? get activeMarketplaceItem => _activeMarketplaceItem;

  // "我的模型" 列表（设置页中显示）
  List<MarketplaceItem> _myModels = const [];
  List<MarketplaceItem> get myModels => List.unmodifiable(_myModels);
  bool _myModelsLoading = false;
  bool get myModelsLoading => _myModelsLoading;
  String? _myModelsError;
  String? get myModelsError => _myModelsError;

  // 市场分页缓存（MarketplaceScreen 使用）
  List<MarketplaceItem> _marketplaceCache = const [];
  List<MarketplaceItem> get marketplaceCache => List.unmodifiable(_marketplaceCache);
  String _marketplaceQuery = '';
  String get marketplaceQuery => _marketplaceQuery;
  String _marketplaceType = 'all';
  String get marketplaceType => _marketplaceType;
  String _marketplaceSort = 'recent';
  String get marketplaceSort => _marketplaceSort;
  int _marketplacePage = 1;
  int get marketplacePage => _marketplacePage;
  int _marketplacePageSize = 24;
  int get marketplacePageSize => _marketplacePageSize;
  int _marketplaceTotal = 0;
  int get marketplaceTotal => _marketplaceTotal;
  bool _marketplaceLoading = false;
  bool get marketplaceLoading => _marketplaceLoading;
  String? _marketplaceError;
  String? get marketplaceError => _marketplaceError;

  // 一次性事件流：UI 监听以弹 SnackBar（例如 "已保存到形象市场"）
  final StreamController<String> _infoMessages = StreamController<String>.broadcast();
  Stream<String> get infoMessages => _infoMessages.stream;
  void emitInfo(String msg) => _infoMessages.add(msg);

  // ==============================
  // 初始化
  // ==============================
  bool _disposed = false;
  Future<void> init() async {
    // 加载持久化的用户设置（在所有服务启动前，避免后端地址被覆盖）
    _settings = await _settingsService.load();
    _marketplacePageSize = _settings.marketplacePageSize;
    _activeMarketplaceModelId = _settings.activeMarketplaceModelId;
    notifyListeners();

    // 启动后台任务：恢复上次选用的 3D 形象（不阻塞 init()）
    // marketplace getter 内部懒加载 MarketplaceService，自身异步，
    // 因此可以在 _initTripo() 之前就发起，不会卡 init 流程。
    // ignore: discarded_futures
    _restoreActiveMarketplaceInBackground();

    // 检测硬件
    _hardwareInfo = await HardwareInfo.detect();
    _degradationLevel = _hardwareInfo?.recommendedDegradation ?? AiDegradationLevel.reduced;
    notifyListeners();

    // 初始化网络监控
    _connectivity = ConnectivityService();
    _connectivity!.onStatusChanged = _onNetworkStatusChanged;
    _connectivity!.onConnected = _onNetworkConnected;
    _connectivity!.onDisconnected = _onNetworkDisconnected;
    await _connectivity!.init();

    // 初始化TTS
    _ttsService = TtsService();
    await _ttsService!.init();

    // 初始化音频播放器
    _audioPlayer = AudioPlayerService();
    _audioPlayer!.onVolumeChanged = (v) {
      _ttsVolume = v;
      notifyListeners();
    };
    // 关键修复（VAD 回声死循环）：
    // VAD 模式下，_audioRecorder 一旦 startRecording 就持续不停，mic 始终在采。
    // AI 的 TTS 经由 SoLoud 播报出来会被 mic 二次捕获，并被原封不动上传到 Omni 的
    // input_audio_buffer，服务端 semantic_vad 会把这段 TTS 当成"用户发言"再触发
    // speech_started → speech_stopped → response，循环往复 AI 自言自语。
    // 解法：AI 第一次开始播报就 pause 录音；播报完成 resume 录音。
    // 仅在 VAD 模式下生效（manual 模式下 _audioRecorder 在用户松手时已 stop，无需处理）。
    _audioPlayer!.onPlaybackStart = () {
      if (_omniMode == OmniInteractionMode.vad &&
          _audioRecorder?.isRecording == true &&
          _audioRecorder?.isPaused == false) {
        debugPrint('[AppState] VAD: pause recorder (AI TTS playback started)');
        _audioRecorder!.pauseRecording();
      }
    };
    _audioPlayer!.onPlaybackComplete = () {
      // 解除 pause 必须在 goIdle 之前：后者可能触发清理路径，确保唤醒 mic 监听
      if (_omniMode == OmniInteractionMode.vad &&
          _audioRecorder?.isRecording == true &&
          _audioRecorder?.isPaused == true) {
        debugPrint('[AppState] VAD: resume recorder (AI TTS playback complete)');
        _audioRecorder!.resumeRecording();
      }
      goIdle();
    };

    // 初始化摄像头
    await _initCamera();

    // 初始化后台保活服务
    _backgroundService = BackgroundAudioService();
    _backgroundService!.onError = (e) {
      debugPrint('[AppState] Background service error: $e');
    };

    // 初始化离线AI引擎（不阻塞 init 流程，模型加载放后台）
    // 模型下载源由后端 {baseUrl}/models/manifest 提供，而不是硬编码 ModelScope/HF URL
    _offlineEngine = OfflineAIEngine(backendBaseUrl: backendBaseUrl);
    _offlineEngine!.onWhisperResult = (text) {
      debugPrint('[AppState] ASR result: $text');
    };
    _offlineEngine!.onVLResult = (text) {
      debugPrint('[AppState] VL result: $text');
    };
    _offlineEngine!.onError = (e) {
      debugPrint('[AppState] Offline engine error: $e');
    };
    _offlineEngine!.onModelLoadProgress = (p) {
      _modelLoadProgress = p;
      notifyListeners();
    };
    // 运行时模型下载进度（首次启动时）
    _offlineEngine!.onDownloadProgress = (frac, currentFile) {
      _isDownloading = true;
      _downloadProgress = frac;
      _downloadCurrentFile = currentFile;
      notifyListeners();
    };
    _offlineEngine!.onDownloadComplete = (success, err) {
      _isDownloading = false;
      _downloadError = success ? null : err;
      _downloadCurrentFile = null;
      if (success) {
        debugPrint('[AppState] Offline model download complete');
      } else {
        debugPrint('[AppState] Offline model download FAILED: $err');
      }
      notifyListeners();
    };
    // 关键：Vosk 加载约 1-2s、VL 加载 30-60s 都不应阻塞 init()
    // 模型下载（首次启动约 30s-5min）更不阻塞。改用 unawaited 串行执行：
    // 1) 检测缺失 → 2) 后台下载（带进度）→ 3) 下载完后初始化 native
    _initOfflineEngineInBackground();

    // 初始化 Tripo 3D服务
    _initTripo();

    // 默认云端模式：启动 SSE 连接
    // max_reconnect 时 onError 自动 fallback 到 offlineLocal
    if (_runMode == AppRunMode.cloudAliyun) {
      _connectCloud();
    }

    notifyListeners();
  }

  /// 后台加载离线引擎（不阻塞 init()）
  Future<void> _initOfflineEngineInBackground() async {
    try {
      await _offlineEngine!.init(_hardwareInfo);
      _asrAvailable = _offlineEngine!.isAsrAvailable;
      _vlAvailable = _offlineEngine!.isVlAvailable;
      _modelLoaded = _offlineEngine!.isWhisperReady;
      _simulationMode = _offlineEngine!.isSimulationMode;
      _modelLoadProgress = 1.0;
      debugPrint('[AppState] Offline engine ready: asr=$_asrAvailable vl=$_vlAvailable simMode=$_simulationMode');
      notifyListeners();
    } catch (e) {
      debugPrint('[AppState] Offline engine init error: $e');
      _simulationMode = true;
      _modelLoadProgress = 1.0;
      notifyListeners();
    }
  }

  /// 后台恢复上次选用的市场 3D 形象（修 bug：重启后没有自动应用显示 3D 形象）
  ///
  /// - 调 GET 而非 download：避免每次冷启动都自增下载计数
  /// - 后端不可达 / 模型已被删：清掉持久化的 ID，避免 activeGlbUrl 永久 null
  Future<void> _restoreActiveMarketplaceInBackground() async {
    final modelId = _activeMarketplaceModelId;
    if (modelId == null || modelId.isEmpty) return;
    try {
      // marketplace getter 懒加载 MarketplaceService，使用 _settings 里已加载的
      // backendBaseUrl / authToken。失败时降级：清掉持久化 ID。
      final item = await marketplace.get(modelId);
      _activeMarketplaceItem = item;
      notifyListeners();
      debugPrint('[AppState] Restored active marketplace model: $modelId');
    } catch (e) {
      debugPrint('[AppState] Failed to restore active marketplace model $modelId: $e');
      // 模型已不存在 / 服务异常 → 清掉持久化 ID，避免每次启动都失败
      _activeMarketplaceModelId = null;
      _activeMarketplaceItem = null;
      _settings = _settings.copyWith(activeMarketplaceModelId: null);
      // ignore: discarded_futures
      _settingsService.save(_settings);
      notifyListeners();
    }
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isNotEmpty) {
        // 如果 _videoCapture 已经先建好（mic 权限先于 camera 权限到位），
        // 预览复用 _videoCapture 内部的 controller，避免多开一份。
        // 否则才自建一份临时 preview controller（_videoCapture 后续会接管）。
        if (_videoCapture?.controller != null && _videoCapture!.controller!.value.isInitialized) {
          try {
            await _cameraController?.dispose();
          } catch (_) {}
          _cameraController = _videoCapture!.controller;
        } else {
          _cameraController = CameraController(
            _cameras.first,
            ResolutionPreset.low,
            enableAudio: false,
          );
          await _cameraController!.initialize();
        }
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Camera init failed: $e');
    }
  }

  // ==============================
  // 模式切换
  // ==============================
  void toggleRunMode() {
    if (_modeSwitchLocked || _aiStatus != AiStatus.idle) return;
    _modeSwitchLocked = true;
    _modeSwitchUnlockTimer?.cancel();
    _modeSwitchUnlockTimer = Timer(const Duration(milliseconds: 200), () {
      _modeSwitchLocked = false;
    });

    // 断开旧连接
    _disconnectCloud();

    _runMode = _runMode == AppRunMode.offlineLocal
        ? AppRunMode.cloudAliyun
        : AppRunMode.offlineLocal;
    notifyListeners();

    // 连接新服务
    if (_runMode == AppRunMode.cloudAliyun) {
      _connectCloud();
    }
  }

  void _connectCloud() {
    if (_sessionId.isEmpty) {
      _sessionId = DateTime.now().millisecondsSinceEpoch.toString();
    }
    // 预初始化音频引擎，避免首帧音频到达时才 init 导致竞态丢帧
    _audioPlayer?.preInit();
    // 关键修复（terminals/2.txt line 70-71, 250-340 多次 connect_enter / omni_audio 重复 3 次）：
    // 每次 _connectCloud() 都 new SseStreamService，但**没有先释放旧实例**。
    // 旧实例的 SSE 连接留在 background 持续消费 EventBus 事件，
    // 导致同一 eid 被多个订阅者各处理一次 → onAudio / onEnd 被回调多次 →
    // 同一段 PCM 被 enqueue 多次 → SoLoud buffer 翻倍 / 顺序错乱 / 听感卡顿。
    // 修复：new 之前先 dispose 旧实例（包括 SSE 连接 + 后台 reconnect timer）。
    final oldSse = _sseService;
    _sseService = SseStreamService(
      baseUrl: backendBaseUrl,
      sessionId: _sessionId,
      token: authToken,
    );
    if (oldSse != null) {
      // dispose 是同步设置 _disposed=true 并 cancel 内部 timers / stream subscription；
      // 即使旧连接还在 background 消费，disconnect() 后 _handleData 会立即早返回。
      // 这里调一次，确保旧 SseStreamService 不再向 onText/onAudio 派发。
      try {
        oldSse.disconnect();
      } catch (e) {
        // #region agent log
        debugPrint('[AppState] _connectCloud: old SSE dispose threw: $e');
        // #endregion
      }
    }
    _sseService!.onConnected = () {
      _connectionStatus = ConnectionStatus.connected;
      notifyListeners();
    };
    _sseService!.onDisconnected = () {
      _connectionStatus = ConnectionStatus.reconnecting;
      notifyListeners();
    };
    _sseService!.onError = (e) {
      // 取消兜底计时器
      _cancelInferenceTimeout();
      // 任何 SSE 错误：立即脱离 thinking/speaking，避免永久死锁
      if (_aiStatus == AiStatus.thinking || _aiStatus == AiStatus.speaking) {
        addAiMessage('抱歉，连接出错了：${e.message}');
        _aiStatus = AiStatus.idle;
        _currentStreamingText = '';
        _userMessageSaved = false;
        // 关键（VAD 闭环守卫）：如果错误发生前 mic 已被 AI 播报触发的
        // onPlaybackStart 暂停，需要在脱离 speaking 状态时显式 resume，
        // 否则 mic 永远停在 paused，下次用户说话服务端收不到任何 audio。
        // 注意不能放在 goIdle() 内统一处理：manual 模式下录音是被用户手动
        // 触发的，错误时 goIdle 路径上 _audioRecorder 可能根本没启动，调用
        // resumeRecording() 是 no-op，但显式判断 VAD 模式更稳妥。
        if (_omniMode == OmniInteractionMode.vad &&
            _audioRecorder?.isRecording == true &&
            _audioRecorder?.isPaused == true) {
          debugPrint('[AppState] SSE error: resume recorder to recover mic');
          _audioRecorder!.resumeRecording();
        }
        notifyListeners();
      }
      if (e.code == 'max_reconnect') {
        // 切换离线
        _runMode = AppRunMode.offlineLocal;
        _connectionStatus = ConnectionStatus.disconnected;
        notifyListeners();
      }
    };
    _sseService!.onText = (chunk) {
      if (chunk.source == 'user') {
        // Omni 用户转录：覆盖式更新（后端发的是累积文本，非增量）
        _currentStreamingText = chunk.text;
      } else {
        // 模型回复开始前，先保存用户转录文本
        if (!_userMessageSaved && _currentStreamingText.isNotEmpty) {
          addUserMessage(_currentStreamingText);
          _currentStreamingText = '';
          _userMessageSaved = true;
        }
        // 模型回复：追加式流式显示
        _currentStreamingText += chunk.text;
        // 收到首条模型 token：把状态从 thinking 切到 speaking，
        // 让球体动画 + 折叠态提示立刻有反应（不再死锁在 thinking）
        if (_aiStatus == AiStatus.thinking) {
          _aiStatus = AiStatus.speaking;
          _resetIdleTimer();
        }
        // 重置兜底计时器（收到 token 说明推理活跃）
        _resetInferenceTimeout();
      }
      notifyListeners();
      if (chunk.isFinal) {
        addAiMessage(_currentStreamingText);
        _currentStreamingText = '';
        _userMessageSaved = false;
        _cancelInferenceTimeout();
        notifyListeners();
      }
    };
    _sseService!.onAudio = (chunk) {
      // VL+TTS 模式：首个音频分片到达时初始化播放流
      if (!_vlTtsAudioStarted) {
        _vlTtsAudioStarted = true;
        _audioPlayer?.startNewTurn();
      }
      _audioPlayer?.enqueuePcm(chunk.base64Audio);
    };
    _sseService!.onOmniAudio = (chunk) {
      // Omni 模式：首个音频分片到达时初始化播放流
      if (!_omniAudioStarted) {
        _omniAudioStarted = true;
        _audioPlayer?.startNewTurn();
      }
      _audioPlayer?.enqueuePcm(chunk.base64Audio);
    };
    _sseService!.onOmniSpeechStarted = () {
      // VAD 检测到语音开始
      if (_omniMode == OmniInteractionMode.vad && _aiStatus == AiStatus.idle) {
        _aiStatus = AiStatus.listening;
        notifyListeners();
      }
    };
    _sseService!.onOmniSpeechStopped = () {
      // VAD 检测到语音结束，进入思考
      if (_omniMode == OmniInteractionMode.vad) {
        _aiStatus = AiStatus.thinking;
        notifyListeners();
      }
    };
    _sseService!.onOmniCommitted = () {
      // 服务端已提交音频缓冲，等待响应
    };
    _sseService!.onEnd = (end) {
      // 取消兜底计时器：end 到了说明推理正常完成
      _cancelInferenceTimeout();
      // 关键：end 事件到达时，把累积的 PCM 立刻刷完播放
      _audioPlayer?.flushPending();
      // 重置音频流标记
      _vlTtsAudioStarted = false;
      _omniAudioStarted = false;
      // 修复5：如果只有用户转录没有模型回复，保存为用户消息
      if (!_userMessageSaved && _currentStreamingText.isNotEmpty) {
        addUserMessage(_currentStreamingText);
        _currentStreamingText = '';
      }
      // 如果有累积的模型流式文本但尚未保存（is_final 从未为 true），保存为AI消息
      if (_currentStreamingText.isNotEmpty) {
        addAiMessage(_currentStreamingText);
        _currentStreamingText = '';
      } else if (end.fullText != null && end.fullText!.isNotEmpty) {
        // 兜底：用 end 事件的 full_text
        addAiMessage(end.fullText!);
      }
      _userMessageSaved = false;
      // 修复4：无音频时直接回 idle，避免卡在 speaking
      // Omni 模式用 audioSeconds，VL+TTS 模式用 totalAudioChunks
      if (end.audioSeconds > 0 || end.totalAudioChunks > 0) {
        _aiStatus = AiStatus.speaking;
        _resetIdleTimer();
      } else {
        _aiStatus = AiStatus.idle;
      }
      notifyListeners();
    };
    _sseService!.onQuotaExceeded = (_) {
      _runMode = AppRunMode.offlineLocal;
      _connectionStatus = ConnectionStatus.disconnected;
      notifyListeners();
    };
    _sseService!.connect();
  }

  void _disconnectCloud() {
    _sseService?.disconnect();
    _sseService = null;
    _connectionStatus = ConnectionStatus.disconnected;
  }

  // ==============================
  // 网络状态回调
  // ==============================
  void _onNetworkStatusChanged(NetworkStatus status) {
    _networkStatus = status;
    notifyListeners();
  }

  void _onNetworkConnected() {
    if (_runMode == AppRunMode.cloudAliyun && _connectionStatus != ConnectionStatus.connected) {
      _connectCloud();
    }
  }

  void _onNetworkDisconnected() {
    // 不自动切换，等SSE重连逻辑处理
  }

  // ==============================
  // 麦克风长按开始
  // ==============================
  Future<void> startListening() async {
    // VAD 模式下长按不触发
    if (_omniMode == OmniInteractionMode.vad) return;
    print('[AppState] startListening entered, _aiStatus=$_aiStatus, _audioRecorder=${_audioRecorder != null}');
    if (_aiStatus != AiStatus.idle) return;
    _aiStatus = AiStatus.listening;
    _recordingSeconds = 0;
    _resetIdleTimer();
    notifyListeners();

    // ⚠️ 修复：不再依赖 setMicPermission(true) 提前构造 recorder。
    // 旧逻辑下：用户没点过权限授权按钮时 _audioRecorder 仍是 null，
    // 整条录音链就被 ?. 短路，audio chunk 一个也上传不到后端。
    // 现在改为懒初始化 —— 每次录音前确保实例存在。
    if (_audioRecorder == null) {
      _audioRecorder = AudioRecorderService(
        baseUrl: backendBaseUrl,
        sessionId: _sessionId,
      );
      print('[AppState] _audioRecorder lazily constructed');
    }

    // 启动录音（云端上传分片，离线本地识别）
    await _audioRecorder?.startRecording();
    print('[AppState] startRecording awaited, _isRecording=${_audioRecorder?.isRecording}');

    // 启动抽帧（云端模式）
    if (_runMode == AppRunMode.cloudAliyun) {
      _videoCapture?.startCapture();
    }

    // 启动后台保活
    _backgroundService?.start();

    // 启动录音计时
    _recordingTimer?.cancel();
    _recordingTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      _recordingSeconds += 0.1;
      notifyListeners();
      if (_recordingSeconds >= 8.0) {
        stopListeningAndThink();
      }
    });
  }

  // ==============================
  // 松手停止
  // ==============================
  Future<void> stopListeningAndThink() async {
    if (_aiStatus != AiStatus.listening) return;
    _recordingTimer?.cancel();
    _recordingSeconds = 0;
    _aiStatus = AiStatus.thinking;
    _vlTtsAudioStarted = false;
    _omniAudioStarted = false;
    notifyListeners();

    // 关键：必须先 await 录音器完成"最后一块 chunk + end=true"信号的上传，
    // 再触发 endTurn，否则 session.audio_buffer 在后端可能仍为空，
    // 导致 Omni 报 "buffer too small, or have no audio"。
    await _audioRecorder?.stopRecording();
    _videoCapture?.stopCapture();

    // 启动 30s 兜底：end 事件不来时强制 goIdle
    _resetInferenceTimeout();
    _processInference();
  }

  // ==============================
  // VAD 模式：点击切换录音
  // ==============================
  Future<void> toggleVadListening() async {
    if (_omniMode != OmniInteractionMode.vad) return;

    if (_aiStatus == AiStatus.idle) {
      // 开始持续录音
      _aiStatus = AiStatus.listening;
      _recordingSeconds = 0;
      _resetIdleTimer();
      notifyListeners();

      if (_audioRecorder == null) {
        _audioRecorder = AudioRecorderService(
          baseUrl: backendBaseUrl,
          sessionId: _sessionId,
        );
      }
      await _audioRecorder?.startRecording();

      if (_runMode == AppRunMode.cloudAliyun) {
        _videoCapture?.startCapture();
      }
      _backgroundService?.start();

      // VAD 模式不设自动停止计时器，由服务端 VAD 控制
    } else if (_aiStatus == AiStatus.listening) {
      // 手动停止录音
      _aiStatus = AiStatus.thinking;
      _vlTtsAudioStarted = false;
      _omniAudioStarted = false;
      notifyListeners();
      await _audioRecorder?.stopRecording();
      _videoCapture?.stopCapture();
      // 隔离上一 turn 残留的音频缓冲
      _audioPlayer?.startNewTurn();
      _sseService?.endTurn();
      // 启动 30s 兜底
      _resetInferenceTimeout();
    }
  }

  void _processInference() async {
    if (_runMode == AppRunMode.cloudAliyun) {
      // 云端推理：通过SSE接收流式结果
      // 隔离上一 turn 残留的音频缓冲
      _audioPlayer?.startNewTurn();
      _sseService?.endTurn();
      // 等待SSE推送（thinking状态保持）
      // 用户提问文本在SSE onText -> currentStreamingText -> addAiMessage 中处理
    } else {
      // 离线推理：Vosk ASR + Qwen-VL 视觉理解 + 本地回答
      try {
        // 等待模型就绪（首次启动可能还在下载中）
        if (_isDownloading) {
          addAiMessage('模型下载中（${(_downloadProgress * 100).toStringAsFixed(0)}%），请稍候...');
          return;
        }
        if (!_asrAvailable && !_vlAvailable) {
          addAiMessage(_downloadError != null
              ? '离线模型下载失败：$_downloadError'
              : '离线模型不可用，请检查网络后重启');
          goIdle();
          return;
        }

        // 第一步：从录音服务获取最新PCM数据，Vosk ASR识别
        // AudioRecorderService.getLatestPcmData() 已返回 Uint8List
        final pcmData = await _audioRecorder?.getLatestPcmData();
        String userText;
        if (pcmData != null && pcmData.isNotEmpty && _asrAvailable) {
          userText = await _offlineEngine!.recognizeSpeech(pcmData);
        } else {
          // ASR 不可用：使用占位文本（实际场景中可考虑降级到云端 ASR）
          userText = pcmData != null && pcmData.isNotEmpty
              ? '（离线ASR未加载，未识别语音）'
              : '你好';
        }

        // 第二步：将用户提问存入消息列表（显示在ChatPanel）
        addUserMessage(userText);

        // 第三步：从视频捕获获取最新帧，Qwen-VL视觉推理
        String answer;
        if (_vlAvailable) {
          final frameBytes = _videoCapture?.getLatestFrame();
          if (frameBytes != null && frameBytes.isNotEmpty) {
            answer = await _offlineEngine!.understandImage(frameBytes, userText);
          } else {
            answer = await _offlineEngine!.chat(userText);
          }
        } else {
          answer = await _offlineEngine!.chat(userText);
        }

        if (_disposed) return;
        addAiMessage(answer);
        startSpeaking();
      } catch (e) {
        debugPrint('[AppState] Offline inference error: $e');
        if (_disposed) return;
        addAiMessage('离线推理失败，请检查模型文件是否正确放置在 app 文档目录的 models/ 子目录');
        goIdle(); // 直接回idle，避免TTS不可用时卡在speaking状态
      }
    }
  }

  // ==============================
  // 开始播报
  // ==============================
  void startSpeaking() {
    _aiStatus = AiStatus.speaking;
    _resetIdleTimer();
    notifyListeners();

    if (_runMode == AppRunMode.offlineLocal) {
      // 离线模式使用本地TTS
      _backgroundService?.start();
      final lastAiMsg = _messages.lastOrNull;
      if (lastAiMsg != null) {
        _ttsService?.onSpeakComplete = () => goIdle();
        _ttsService?.speak(lastAiMsg.text);
      }
    }
    // 云端模式音频已在SSE onAudio中通过audioPlayer处理
  }

  // ==============================
  // 回到空闲
  // ==============================
  void goIdle() {
    _aiStatus = AiStatus.idle;
    _recordingSeconds = 0;
    _cancelInferenceTimeout();
    _resetIdleTimer();
    // 停止后台保活（idle状态节能）
    _backgroundService?.stop();
    notifyListeners();
  }

  /// 启动/重置 30s 推理兜底计时器：超时强制 goIdle + 落库兜底消息
  void _resetInferenceTimeout() {
    _inferenceTimeoutTimer?.cancel();
    _inferenceTimeoutTimer = Timer(
      const Duration(seconds: _inferenceTimeoutSeconds),
      () {
        debugPrint('[AppState] Inference timeout (${_inferenceTimeoutSeconds}s), force goIdle');
        if (_aiStatus == AiStatus.thinking || _aiStatus == AiStatus.speaking) {
          // 兜底：当前没有文本就给个空文本提示，有就保存当前流式
          if (_currentStreamingText.isEmpty) {
            addAiMessage('抱歉，没听清，请再说一次');
          } else {
            addAiMessage(_currentStreamingText);
          }
          _currentStreamingText = '';
          _userMessageSaved = false;
          _aiStatus = AiStatus.idle;
          // 关键修复（terminals/2.txt line 41, 66 两次 timeout 后无 flush）：
          // 30s 兜底 goIdle 之前先 flush audio player，
          // 否则 SoLoud native 端的 stream 一直占着，下一轮 startNewTurn 才被抢断，
          // 听感上是"两段音频叠在一起" / 静音后才发声。
          // 兜底：调一次 flushPending；播放器内部 _ended 已生效，重复调是 no-op。
          _audioPlayer?.flushPending();
          notifyListeners();
        }
      },
    );
  }

  void _cancelInferenceTimeout() {
    _inferenceTimeoutTimer?.cancel();
    _inferenceTimeoutTimer = null;
  }

  void _resetIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(seconds: _idleTimeoutSeconds), () {
      // 30s静默冻结SSE连接
      if (_runMode == AppRunMode.cloudAliyun) {
        _sseService?.disconnect();
        _connectionStatus = ConnectionStatus.disconnected;
        notifyListeners();
      }
    });
  }

  // ==============================
  // 权限
  // ==============================
  void setCameraPermission(bool granted) {
    _cameraPermissionGranted = granted;
    notifyListeners();
    if (granted) _initCamera();
  }

  void setMicPermission(bool granted) {
    _micPermissionGranted = granted;
    notifyListeners();
    if (granted) {
      _audioRecorder = AudioRecorderService(
        baseUrl: backendBaseUrl,
        sessionId: _sessionId,
      );
    }
    if (granted && _cameraPermissionGranted) {
      _videoCapture = VideoCaptureService(
        baseUrl: backendBaseUrl,
        sessionId: _sessionId,
      );
      _videoCapture!.init(_cameras).then((_) {
        // _videoCapture 内部 controller 初始化完成后，把 preview 切过去共享同一份。
        // 避免在 iOS 上同时持有两个 camera controller（会冲突导致 setFlashMode 异常等）。
        final cap = _videoCapture?.controller;
        if (cap != null && cap.value.isInitialized) {
          try {
            _cameraController?.dispose();
          } catch (_) {}
          _cameraController = cap;
          notifyListeners();
        }
      });
    }
  }

  // ==============================
  // 摄像头控制
  // ==============================
  // 对焦模式：true=连续自动对焦, false=手动（等待用户点击屏幕）
  bool _autoFocus = true;
  bool get autoFocus => _autoFocus;
  // 最近一次对焦的屏幕坐标（驱动 UI 显示对焦框），null=无
  Offset? _focusPoint;
  Offset? get focusPoint => _focusPoint;

  Future<void> toggleAutoFocus() async {
    _autoFocus = !_autoFocus;
    notifyListeners();
    await _videoCapture?.setAutoFocus(_autoFocus);
  }

  /// 用户点击屏幕触发对焦
  /// [screenPoint] 屏幕逻辑像素坐标
  /// [previewSize] 摄像头 sensor 原始尺寸
  /// [renderRect] 摄像头画面在屏幕上的实际显示矩形
  Future<void> focusAt(
    Offset screenPoint, {
    required Size previewSize,
    required Rect renderRect,
  }) async {
    // 摄像头对焦与 AI 交互状态无关 —— 用户在 listening/speaking 状态时
    // 也常常需要点屏幕换对焦点（尤其近物/失焦场景），所以这里不再做状态拦截。
    debugPrint(
      '[Focus] focusAt entered: screen=$screenPoint previewSize=$previewSize '
      'renderRect=$renderRect aiStatus=$_aiStatus videoCapture=${_videoCapture != null}',
    );
    _focusPoint = screenPoint;
    notifyListeners();
    await _videoCapture?.setFocusPoint(
      screenPoint,
      previewSize: previewSize,
      renderRect: renderRect,
    );
    // 800ms 后清除对焦点（让 UI 上的对焦框淡出）
    Future.delayed(const Duration(milliseconds: 800), () {
      if (_focusPoint == screenPoint) {
        _focusPoint = null;
        notifyListeners();
      }
    });
  }

  void toggleFlash() {
    if (_aiStatus == AiStatus.listening) return;
    _flashOn = !_flashOn;
    // 走 _videoCapture：它内部已经包了 switchCamera 会同步切换的 controller，
    // 且 setFlash() 自带 try/catch + 设备不支持 torch 时静默忽略。
    // 旧的 _cameraController 路径在切到前置后会抛 setFlashModeFailed（前置无 torch），
    // 那个异常没被捕获会直接 unhandled，导致 UI 卡死。
    _videoCapture?.setFlash(_flashOn);
    notifyListeners();
  }

  Future<void> switchCamera() async {
    if (_aiStatus == AiStatus.listening) return;
    await _videoCapture?.switchCamera(_cameras);
    // 切换摄像头后同步对焦模式
    await _videoCapture?.setAutoFocus(_autoFocus);
    // 修复「预览不跟拍反转」：预览用的 _cameraController 必须跟着重建，
    // 否则用户看到的画面不会翻面，反馈不直观。
    // 复用 _videoCapture 内部的 controller（同一份 high 分辨率实例），
    // 避免再多开一个摄像头（iOS 不允许同时打开两个同 sensor）。
    try {
      await _cameraController?.dispose();
    } catch (_) {}
    _cameraController = _videoCapture?.controller;
    notifyListeners();
  }

  // ==============================
  // 生命周期：抽帧控制
  // ==============================
  void pauseFrameCapture() {
    _videoCapture?.stopCapture();
  }

  void resumeFrameCapture() {
    if (_runMode == AppRunMode.cloudAliyun) {
      _videoCapture?.startCapture();
    }
  }

  // ==============================
  // 对话面板
  // ==============================
  void toggleChatPanel() {
    _chatPanelExpanded = !_chatPanelExpanded;
    notifyListeners();
  }

  // ==============================
  // 消息
  // ==============================
  void addUserMessage(String text, {List<int>? thumbnail}) {
    _messages.add(ChatMessage(
      text: text,
      isUser: true,
      timestamp: DateTime.now(),
    ));
    notifyListeners();
  }

  void addAiMessage(String text) {
    _messages.add(ChatMessage(
      text: text,
      isUser: false,
      timestamp: DateTime.now(),
    ));
    notifyListeners();
  }

  // ==============================
  // 降级触发
  // ==============================
  void triggerDegradation(AiDegradationLevel level) {
    _degradationLevel = level;
    notifyListeners();
  }

  // ==============================
  // Tripo 3D生成
  // ==============================
  String? _tripoModelId; // 关联后端 market row id（生成成功后用于显示提示）
  String? get tripoModelId => _tripoModelId;

  void _initTripo() {
    _tripoService = TripoService(baseUrl: backendBaseUrl);
    _tripoService!.onProgress = (status, errorMessage) {
      switch (status) {
        case TripoTaskStatus.pending:
          _tripoGenerating = true;
          _tripoStatusText = '排队中…';
          _tripoProgress = 0.1;
          _tripoRunStart = DateTime.now();
          break;
        case TripoTaskStatus.running:
          _tripoGenerating = true;
          _tripoStatusText = _runningPhaseText();
          _tripoProgress = 0.4;
          break;
        case TripoTaskStatus.succeeded:
          _tripoGenerating = false;
          _tripoStatusText = '3D 模型生成成功！';
          _tripoProgress = 1.0;
          _tripoModelUrl = _tripoService!.lastResult?.pbrModelUrl;
          _tripoPreviewUrl = _tripoService!.lastResult?.renderedImageUrl;
          _tripoError = null;
          // ignore: discarded_futures
          loadMyModels(refresh: false);
          final warning = _tripoService!.lastResult?.errorMessage;
          if (warning != null && warning.isNotEmpty) {
            emitInfo('生成成功，但有警告：$warning');
          } else {
            emitInfo('已保存到形象市场（${_visibilityZh(_settings.defaultModelVisibility)}）');
          }
          _tripoRunStart = null;
          break;
        case TripoTaskStatus.failed:
          _tripoGenerating = false;
          _tripoError = errorMessage ?? _tripoService!.lastResult?.errorMessage;
          _tripoStatusText = _tripoError != null && _tripoError!.isNotEmpty
              ? '生成失败：$_tripoError'
              : '生成失败，请重试';
          _tripoProgress = 0.0;
          _tripoRunStart = null;
          break;
        case TripoTaskStatus.canceled:
          _tripoGenerating = false;
          _tripoStatusText = '已取消';
          _tripoError = null;
          _tripoProgress = 0.0;
          _tripoRunStart = null;
          break;
        case TripoTaskStatus.unknown:
          _tripoGenerating = true;
          _tripoStatusText = '等待服务器响应…';
          _tripoProgress = 0.05;
          break;
      }
      _tripoCanCancel = _tripoService!.canCancel;
      notifyListeners();
    };
    _tripoService!.onError = (error) {
      _tripoGenerating = false;
      _tripoError = error;
      _tripoStatusText = '网络错误：$error';
      _tripoProgress = 0.0;
      _tripoRunStart = null;
      notifyListeners();
    };
  }

  /// 阶段化文案：RUNNING 状态根据已等待时间切换 3 段文案
  String _runningPhaseText() {
    final start = _tripoRunStart;
    if (start == null) return 'AI 正在雕琢几何…';
    final elapsed = DateTime.now().difference(start).inSeconds;
    if (elapsed < 30) return 'AI 正在雕琢几何…';
    if (elapsed < 90) return '正在烘焙贴图…';
    return '正在精修细节…';
  }

  /// 取消正在生成的任务
  Future<void> cancelTripoGeneration() async {
    final tid = _tripoTaskId;
    if (tid == null || _tripoService == null) return;
    try {
      await _tripoService!.cancelTask(tid);
    } catch (e) {
      emitInfo('取消请求失败：$e');
      return;
    }
    _tripoGenerating = false;
    _tripoStatusText = '已取消';
    _tripoError = null;
    _tripoProgress = 0.0;
    _tripoCanCancel = false;
    _tripoRunStart = null;
    notifyListeners();
    emitInfo('已取消 3D 生成');
  }

  String _visibilityZh(String v) {
    switch (v) {
      case 'public':
        return '公开';
      case 'unlisted':
        return '不公开';
      case 'private':
        return '私密';
      default:
        return v;
    }
  }

  /// 从提交响应里提取 model_id（兼容老后端：没有 model_id 字段时返回 null）
  String? _extractModelId(Map<String, dynamic> data) => data['model_id'] as String?;

  Future<void> startTextTo3D(String prompt) async {
    if (_tripoService == null) return;
    try {
      _tripoGenerating = true;
      _tripoStatusText = '正在提交生成任务…';
      _tripoProgress = 0.05;
      _tripoError = null;
      _tripoModelId = null;
      _tripoCanCancel = false;
      _tripoRunStart = null;
      notifyListeners();

      final data = await _tripoService!.textTo3DRaw(
        prompt: prompt,
        model: _settings.tripoModel,
        textureQuality: _settings.tripoTextureQuality,
      );
      _tripoTaskId = data['task_id'] as String?;
      _tripoModelId = _extractModelId(data);
      if (_tripoTaskId != null) {
        _tripoService!.startPolling(_tripoTaskId!);
      }
    } catch (e) {
      _tripoGenerating = false;
      _tripoError = e.toString();
      _tripoStatusText = '提交失败：$e';
      notifyListeners();
    }
  }

  Future<void> startImageTo3D(String imageUrl) async {
    if (_tripoService == null) return;
    try {
      _tripoGenerating = true;
      _tripoStatusText = '正在提交生成任务…';
      _tripoProgress = 0.05;
      _tripoError = null;
      _tripoModelId = null;
      _tripoCanCancel = false;
      _tripoRunStart = null;
      notifyListeners();

      final data = await _tripoService!.imageTo3DRaw(
        imageUrl: imageUrl,
        model: _settings.tripoModel,
        textureQuality: _settings.tripoTextureQuality,
      );
      _tripoTaskId = data['task_id'] as String?;
      _tripoModelId = _extractModelId(data);
      if (_tripoTaskId != null) {
        _tripoService!.startPolling(_tripoTaskId!);
      }
    } catch (e) {
      _tripoGenerating = false;
      _tripoError = e.toString();
      _tripoStatusText = '提交失败：$e';
      notifyListeners();
    }
  }

  Future<void> startMultiImageTo3D(String encodedInput) async {
    if (_tripoService == null) return;
    try {
      _tripoGenerating = true;
      _tripoStatusText = '正在提交生成任务…';
      _tripoProgress = 0.05;
      _tripoError = null;
      _tripoModelId = null;
      _tripoCanCancel = false;
      _tripoRunStart = null;
      notifyListeners();

      // encodedInput 格式: "url1|null|url3|null" (用|分隔，null=禁用/空)
      final parts = encodedInput.split('|');
      final images = <Map<String, String>?>[];
      for (final part in parts) {
        if (part.isEmpty) {
          images.add(null); // 用户禁用的视角
        } else {
          images.add({'type': _inferImageType(part), 'file_token': part});
        }
      }
      // 不足4个，补null
      while (images.length < 4) {
        images.add(null);
      }

      final data = await _tripoService!.multiImageTo3DRaw(
        images: images,
        model: _settings.tripoModel,
        textureQuality: _settings.tripoTextureQuality,
      );
      _tripoTaskId = data['task_id'] as String?;
      _tripoModelId = _extractModelId(data);
      if (_tripoTaskId != null) {
        _tripoService!.startPolling(_tripoTaskId!);
      }
    } catch (e) {
      _tripoGenerating = false;
      _tripoError = e.toString();
      _tripoStatusText = '提交失败：$e';
      notifyListeners();
    }
  }

  String _inferImageType(String url) {
    final u = url.toLowerCase();
    if (u.contains('.png')) return 'png';
    return 'jpeg';
  }

  void clearTripoModel() {
    _tripoTaskId = null;
    _tripoModelUrl = null;
    _tripoPreviewUrl = null;
    _tripoGenerating = false;
    _tripoProgress = 0.0;
    _tripoStatusText = '';
    _tripoError = null;
    _tripoCanCancel = false;
    _tripoRunStart = null;
    _tripoService?.cancelPolling();
    notifyListeners();
  }

  // ==============================
  // 设置更新（应用后端地址 / 令牌 / 偏好变更）
  // ==============================

  /// 持久化新设置并在必要时重建后端服务。
  ///
  /// 当 [AppSettings.backendUrl] 或 [AppSettings.authToken] 变化时
  /// 会断流旧连接并按新地址重新连接 SSE / 重建 Tripo / Recorder。
  Future<void> updateSettings(AppSettings next) async {
    final old = _settings;
    _settings = next;
    _marketplacePageSize = next.marketplacePageSize;
    _activeMarketplaceModelId = next.activeMarketplaceModelId;
    await _settingsService.save(next);
    notifyListeners();

    final backendChanged =
        old.backendUrl != next.backendUrl || old.authToken != next.authToken;
    if (backendChanged) {
      _restartServicesWithNewBackend();
    }
  }

  /// 重置为默认设置（保留设置页 UI 操作）
  Future<void> resetSettings() async {
    await _settingsService.reset();
    final old = _settings;
    _settings = const AppSettings();
    _marketplacePageSize = _settings.marketplacePageSize;
    _activeMarketplaceModelId = null;
    notifyListeners();
    if (old.backendUrl != _settings.backendUrl ||
        old.authToken != _settings.authToken) {
      _restartServicesWithNewBackend();
    }
  }

  /// 断开 SSE / Tripo / Recorder，然后按当前设置重连。
  /// 当前正在录音或正在 3D 生成时拒绝执行（保护进行中任务）。
  void _restartServicesWithNewBackend() {
    if (_aiStatus == AiStatus.listening) {
      emitInfo('正在录音中，暂不切换后端，请稍后重试');
      return;
    }
    if (_tripoGenerating) {
      emitInfo('正在生成 3D 模型，暂不切换后端');
      return;
    }
    _disconnectCloud();
    _tripoService?.dispose();
    _tripoService = null;
    _audioRecorder?.dispose();
    _audioRecorder = null;
    _videoCapture?.dispose();
    _videoCapture = null;
    _marketplaceService?.dispose();
    _marketplaceService = null;

    // 重建
    _initTripo();
    if (_runMode == AppRunMode.cloudAliyun) {
      _connectCloud();
    }
    notifyListeners();
    emitInfo('已切换到新后端：${backendBaseUrl}');
  }

  /// 测试与当前后端地址的连接（用于设置页"测试连接"按钮）。
  Future<bool> testBackendConnection({String? overrideUrl, String? overrideToken}) async {
    final url = overrideUrl ?? backendBaseUrl;
    final token = overrideToken ?? authToken;
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
      try {
        final req = await client.getUrl(Uri.parse('$url/health'));
        if (token.isNotEmpty) {
          req.headers.set('X-User-Token', token);
        }
        final resp = await req.close();
        await resp.drain<void>();
        return resp.statusCode == 200;
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      debugPrint('[AppState] test connection error: $e');
      return false;
    }
  }

  // ==============================
  // 3D 形象市场（MarketplaceScreen / SettingsScreen 使用）
  // ==============================

  /// 设置市场筛选条件并触发重新加载（替换整个缓存）
  Future<void> setMarketplaceFilters({
    String? query,
    String? type,
    String? sort,
  }) async {
    if (query != null) _marketplaceQuery = query;
    if (type != null) _marketplaceType = type;
    if (sort != null) _marketplaceSort = sort;
    _marketplacePage = 1;
    notifyListeners();
    await loadMarketplace();
  }

  /// 加载市场列表（追加或替换模式）
  Future<void> loadMarketplace({bool refresh = true}) async {
    if (refresh) {
      _marketplacePage = 1;
      _marketplaceCache = const [];
    }
    _marketplaceLoading = true;
    _marketplaceError = null;
    notifyListeners();
    try {
      final result = await marketplace.list(
        q: _marketplaceQuery.isEmpty ? null : _marketplaceQuery,
        type: _marketplaceType == 'all' ? null : _marketplaceType,
        sort: _marketplaceSort,
        page: _marketplacePage,
        pageSize: _marketplacePageSize,
      );
      if (refresh || _marketplacePage == 1) {
        _marketplaceCache = result.items;
      } else {
        _marketplaceCache = [..._marketplaceCache, ...result.items];
      }
      _marketplaceTotal = result.total;
      _marketplacePage = result.page;
    } catch (e) {
      _marketplaceError = e.toString();
    } finally {
      _marketplaceLoading = false;
      notifyListeners();
    }
  }

  /// 加载下一页
  Future<void> loadMarketplaceNextPage() async {
    if (_marketplaceLoading) return;
    final loaded = _marketplaceCache.length;
    if (loaded >= _marketplaceTotal) return;
    _marketplacePage += 1;
    await loadMarketplace(refresh: false);
  }

  /// 重新加载当前用户拥有的模型列表（设置页"我的模型"用）
  Future<void> loadMyModels({bool refresh = true}) async {
    _myModelsLoading = true;
    _myModelsError = null;
    if (refresh) notifyListeners();
    try {
      final list = await marketplace.myModels();
      _myModels = list;
    } catch (e) {
      _myModelsError = e.toString();
    } finally {
      _myModelsLoading = false;
      notifyListeners();
    }
  }

  /// 选用某个市场模型作为活动 3D 形象。
  /// 会把对应 GLB / preview URL 同步给 TripoService，让旧的 [activeGlbUrl] /
  /// [activePreviewUrl] getter 直接返回市场内容。
  Future<void> setActiveMarketplaceModel(String modelId) async {
    final item = await marketplace.download(modelId);
    _activeMarketplaceModelId = modelId;
    _activeMarketplaceItem = item;
    _tripoTaskId = null; // 清掉临时生成任务指针，避免 activeGlbUrl 回退到旧任务
    _tripoModelUrl = item.glbUrl;
    _tripoPreviewUrl = item.previewUrl;
    // 持久化
    _settings = _settings.copyWith(activeMarketplaceModelId: modelId);
    await _settingsService.save(_settings);
    notifyListeners();
  }

  /// 清除活动市场模型（回到默认"未选用"状态）
  Future<void> clearActiveMarketplaceModel() async {
    _activeMarketplaceModelId = null;
    _activeMarketplaceItem = null;
    _settings = _settings.copyWith(activeMarketplaceModelId: null);
    await _settingsService.save(_settings);
    notifyListeners();
  }

  /// 调整某个模型的可见性（仅 owner；后端会做权限校验）
  Future<MarketplaceItem> setModelVisibility(String modelId, String visibility) async {
    final item = await marketplace.setVisibility(modelId, visibility);
    if (_myModels.any((m) => m.id == modelId)) {
      _myModels = _myModels.map((m) => m.id == modelId ? item : m).toList();
    }
    notifyListeners();
    return item;
  }

  /// 修改模型元信息（title / tags）
  Future<MarketplaceItem> updateModelMeta(
    String modelId, {
    String? title,
    String? tags,
  }) async {
    final item = await marketplace.update(modelId, title: title, tags: tags);
    if (_myModels.any((m) => m.id == modelId)) {
      _myModels = _myModels.map((m) => m.id == modelId ? item : m).toList();
    }
    notifyListeners();
    return item;
  }

  /// 删除一个市场模型（级联清本地文件）
  Future<void> deleteModel(String modelId) async {
    await marketplace.delete(modelId);
    _myModels = _myModels.where((m) => m.id != modelId).toList();
    if (_activeMarketplaceModelId == modelId) {
      _activeMarketplaceModelId = null;
      _activeMarketplaceItem = null;
      _settings = _settings.copyWith(activeMarketplaceModelId: null);
      await _settingsService.save(_settings);
    }
    notifyListeners();
  }

  /// 暴露 TripoService 给 UI（用于下载 GLB 到本地等场景）
  TripoService? get tripoService => _tripoService;

  /// 把模型 URL 转成带 scheme 的绝对地址。
  /// - 已带 http/https 原样返回
  /// - 相对路径补上 backendBaseUrl
  /// - 拼接后给 model_viewer_plus iOS 端使用（修 bug #1）
  static String? resolveModelUrl(String? url, String backendBaseUrl) {
    if (url == null || url.isEmpty) return null;
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    return '$backendBaseUrl$url';
  }

  /// 获取当前活跃 GLB 的完整 URL。
  ///
  /// 三段优先级（修 bug #2：市场选用后仍是球）：
  /// 1) 形象市场选用（_activeMarketplaceItem.glbUrl）— 跨重启保留的"当前形象"
  /// 2) 刚生成的任务（_tripoService.lastResult.pbrModelUrl 或本地路径兜底）
  /// 3) null
  ///
  /// 后端 /status 已返回带 scheme 的绝对地址；如果拿到的是相对路径则补上 base。
  String? get activeGlbUrl {
    final mpUrl = _activeMarketplaceItem?.glbUrl;
    if (mpUrl != null && mpUrl.isNotEmpty) {
      return resolveModelUrl(mpUrl, backendBaseUrl);
    }
    final tid = _tripoTaskId;
    if (tid == null || _tripoService == null) return null;
    final last = _tripoService!.lastResult;
    if (last?.pbrModelUrl != null && last!.pbrModelUrl!.isNotEmpty) {
      return resolveModelUrl(last.pbrModelUrl, backendBaseUrl);
    }
    return resolveModelUrl('/tripo/model/$tid/glb', backendBaseUrl);
  }

  /// 获取当前活跃预览图的完整 URL。
  /// 优先级同 activeGlbUrl。
  String? get activePreviewUrl {
    final mpUrl = _activeMarketplaceItem?.previewUrl;
    if (mpUrl != null && mpUrl.isNotEmpty) {
      return resolveModelUrl(mpUrl, backendBaseUrl);
    }
    final tid = _tripoTaskId;
    if (tid == null || _tripoService == null) return null;
    final last = _tripoService!.lastResult;
    if (last?.renderedImageUrl != null && last!.renderedImageUrl!.isNotEmpty) {
      return resolveModelUrl(last.renderedImageUrl, backendBaseUrl);
    }
    return resolveModelUrl('/tripo/model/$tid/preview', backendBaseUrl);
  }

  /// 当前模型是否"应该展示 3D 模型"（任一来源就绪）
  /// 修 bug #2：市场选用后也应为 true
  bool get tripoSucceeded {
    if (_activeMarketplaceItem?.glbUrl != null &&
        _activeMarketplaceItem!.glbUrl!.isNotEmpty) {
      return true;
    }
    return _tripoTaskId != null &&
        _tripoService?.lastResult?.status == TripoTaskStatus.succeeded;
  }

  /// 当前模型 GLB URL（远程或本地）— 仅"刚生成"分支
  String? get tripoPbrUrl => _tripoService?.lastResult?.pbrModelUrl;

  /// 当前渲染预览图 URL — 仅"刚生成"分支
  String? get tripoRenderedUrl => _tripoService?.lastResult?.renderedImageUrl;

  @override
  void dispose() {
    _disposed = true;
    _recordingTimer?.cancel();
    _modeSwitchUnlockTimer?.cancel();
    _idleTimer?.cancel();
    _inferenceTimeoutTimer?.cancel();
    _sseService?.dispose();
    _audioRecorder?.dispose();
    _videoCapture?.dispose();
    _audioPlayer?.dispose();
    _connectivity?.dispose();
    _ttsService?.dispose();
    _offlineEngine?.dispose();
    _backgroundService?.dispose();
    _tripoService?.dispose();
    _marketplaceService?.dispose();
    _infoMessages.close();
    // 注意：现在 _cameraController 可能是 _videoCapture.controller 的同一份实例。
    // _videoCapture.dispose() 已经在 super.dispose 之前调过，二次 dispose 会抛。
    // 防御性吞掉异常；正常 dispose 流程中此处引用通常已被置 null。
    try {
      _cameraController?.dispose();
    } catch (_) {}
    _cameraController = null;
    super.dispose();
  }
}
