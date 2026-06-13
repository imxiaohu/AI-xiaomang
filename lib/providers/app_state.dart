import 'dart:async';
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
import '../utils/tts_service.dart';
import '../config/env_config.dart';

/// 全局业务状态编排
/// 管理：SSE连接生命周期、录音/抽帧/推理/播报时序、自动降级触发
class AppState extends ChangeNotifier {
  // ==============================
  // 运行模式
  // ==============================
  AppRunMode _runMode = AppRunMode.offlineLocal;
  AppRunMode get runMode => _runMode;

  // ==============================
  // Omni 交互模式
  // ==============================
  OmniInteractionMode _omniMode = OmniInteractionMode.manual;
  OmniInteractionMode get omniMode => _omniMode;

  Future<void> setOmniMode(OmniInteractionMode mode) async {
    if (_omniMode == mode) return;
    _omniMode = mode;
    notifyListeners();
    // 通知后端切换模式
    await _sseService?.setMode(mode == OmniInteractionMode.vad ? 'vad' : 'manual');
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
  bool _simulationMode = false;
  double get modelLoadProgress => _modelLoadProgress;
  bool get modelLoaded => _modelLoaded;
  bool get simulationMode => _simulationMode;

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

  String? get tripoTaskId => _tripoTaskId;
  String? get tripoModelUrl => _tripoModelUrl;
  String? get tripoPreviewUrl => _tripoPreviewUrl;
  bool get tripoGenerating => _tripoGenerating;
  double get tripoProgress => _tripoProgress;
  String get tripoStatusText => _tripoStatusText;
  String? get tripoError => _tripoError;

  // ==============================
  // 初始化
  // ==============================
  bool _disposed = false;
  Future<void> init() async {
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
    _audioPlayer!.onPlaybackComplete = () {
      goIdle();
    };

    // 初始化摄像头
    await _initCamera();

    // 初始化后台保活服务
    _backgroundService = BackgroundAudioService();
    _backgroundService!.onError = (e) {
      debugPrint('[AppState] Background service error: $e');
    };

    // 初始化离线AI引擎
    _offlineEngine = OfflineAIEngine();
    _offlineEngine!.onWhisperResult = (text) {
      debugPrint('[AppState] Whisper result: $text');
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
    await _offlineEngine!.init(_hardwareInfo);
    _modelLoaded = _offlineEngine!.isWhisperReady;
    _simulationMode = _offlineEngine!.isSimulationMode;
    _modelLoadProgress = 1.0;

    // 初始化 Tripo 3D服务
    _initTripo();

    notifyListeners();
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isNotEmpty) {
        _cameraController = CameraController(
          _cameras.first,
          ResolutionPreset.low,
          enableAudio: false,
        );
        await _cameraController!.initialize();
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
    _sseService = SseStreamService(
      baseUrl: BackendConfig.baseUrl,
      sessionId: _sessionId,
      token: BackendConfig.defaultToken,
    );
    _sseService!.onConnected = () {
      _connectionStatus = ConnectionStatus.connected;
      notifyListeners();
    };
    _sseService!.onDisconnected = () {
      _connectionStatus = ConnectionStatus.reconnecting;
      notifyListeners();
    };
    _sseService!.onError = (e) {
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
      }
      notifyListeners();
      if (chunk.isFinal) {
        addAiMessage(_currentStreamingText);
        _currentStreamingText = '';
        _userMessageSaved = false;
        notifyListeners();
      }
    };
    _sseService!.onAudio = (chunk) {
      _audioPlayer?.enqueue(chunk.base64Audio);
    };
    _sseService!.onOmniAudio = (chunk) {
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
      // 关键：end 事件到达时，把 Omni 累积的 PCM 立刻拼成 WAV 播放，
      // 避免 < 200ms 的尾段留到下次 turn 一起播（那会延迟 200ms+）
      _audioPlayer?.flushPending();
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
        baseUrl: BackendConfig.baseUrl,
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
    notifyListeners();

    // 关键：必须先 await 录音器完成"最后一块 chunk + end=true"信号的上传，
    // 再触发 endTurn，否则 session.audio_buffer 在后端可能仍为空，
    // 导致 Omni 报 "buffer too small, or have no audio"。
    await _audioRecorder?.stopRecording();
    _videoCapture?.stopCapture();

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
          baseUrl: BackendConfig.baseUrl,
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
      notifyListeners();
      await _audioRecorder?.stopRecording();
      _videoCapture?.stopCapture();
      // 隔离上一 turn 残留的音频缓冲
      _audioPlayer?.startNewTurn();
      _sseService?.endTurn();
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
      // 离线推理：Whisper ASR + Qwen-VL 视觉理解 + 本地回答
      try {
        // 第一步：从录音服务获取最新PCM数据，Whisper ASR识别
        final pcmData = await _audioRecorder?.getLatestPcmData();
        String userText;
        if (pcmData != null && pcmData.isNotEmpty) {
          userText = await _offlineEngine!.recognizeSpeech(pcmData);
        } else {
          userText = '你好';
        }

        // 第二步：将用户提问存入消息列表（显示在ChatPanel）
        addUserMessage(userText);

        // 第三步：从视频捕获获取最新帧，Qwen-VL视觉推理
        String answer;
        if (_offlineEngine?.isVLReady == true) {
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
        addAiMessage('离线推理失败，请检查模型文件是否正确放置在assets目录');
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
    _resetIdleTimer();
    // 停止后台保活（idle状态节能）
    _backgroundService?.stop();
    notifyListeners();
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
        baseUrl: BackendConfig.baseUrl,
        sessionId: _sessionId,
      );
    }
    if (granted && _cameraPermissionGranted) {
      _videoCapture = VideoCaptureService(
        baseUrl: BackendConfig.baseUrl,
        sessionId: _sessionId,
      );
      _videoCapture!.init(_cameras);
    }
  }

  // ==============================
  // 摄像头控制
  // ==============================
  void toggleFlash() {
    if (_aiStatus == AiStatus.listening) return;
    _flashOn = !_flashOn;
    _cameraController?.setFlashMode(_flashOn ? FlashMode.torch : FlashMode.off);
    notifyListeners();
  }

  Future<void> switchCamera() async {
    if (_aiStatus == AiStatus.listening) return;
    await _videoCapture?.switchCamera(_cameras);
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
  void _initTripo() {
    _tripoService = TripoService(baseUrl: BackendConfig.baseUrl);
    _tripoService!.onProgress = (status, _) {
      _tripoGenerating = true;
      switch (status) {
        case TripoTaskStatus.pending:
          _tripoStatusText = '任务已提交，等待处理…';
          _tripoProgress = 0.1;
          break;
        case TripoTaskStatus.running:
          _tripoStatusText = 'AI 正在生成 3D 模型…';
          _tripoProgress = 0.4;
          break;
        case TripoTaskStatus.succeeded:
          _tripoStatusText = '3D 模型生成成功！';
          _tripoProgress = 1.0;
          _tripoGenerating = false;
          _tripoModelUrl = _tripoService!.lastResult?.pbrModelUrl;
          _tripoPreviewUrl = _tripoService!.lastResult?.renderedImageUrl;
          _tripoError = null;
          break;
        case TripoTaskStatus.failed:
          _tripoStatusText = '生成失败，请重试';
          _tripoGenerating = false;
          _tripoError = _tripoService!.lastResult?.errorMessage;
          break;
        case TripoTaskStatus.canceled:
          _tripoStatusText = '任务已取消';
          _tripoGenerating = false;
          _tripoError = '任务已取消';
          break;
        case TripoTaskStatus.unknown:
          _tripoStatusText = '等待服务器响应…';
          break;
      }
      notifyListeners();
    };
    _tripoService!.onError = (error) {
      _tripoGenerating = false;
      _tripoError = error;
      _tripoStatusText = '网络错误：$error';
      notifyListeners();
    };
  }

  Future<void> startTextTo3D(String prompt) async {
    if (_tripoService == null) return;
    try {
      _tripoGenerating = true;
      _tripoStatusText = '正在提交生成任务…';
      _tripoProgress = 0.05;
      _tripoError = null;
      notifyListeners();

      final taskId = await _tripoService!.textTo3D(prompt: prompt);
      _tripoTaskId = taskId;
      _tripoService!.startPolling(taskId);
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
      notifyListeners();

      final taskId = await _tripoService!.imageTo3D(imageUrl: imageUrl);
      _tripoTaskId = taskId;
      _tripoService!.startPolling(taskId);
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

      final taskId = await _tripoService!.multiImageTo3D(images: images);
      _tripoTaskId = taskId;
      _tripoService!.startPolling(taskId);
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
    _tripoService?.cancelPolling();
    notifyListeners();
  }

  /// 获取当前活跃 GLB 的完整 URL（优先本地路径，后端下载完成后返回本地路径）
  String? get activeGlbUrl {
    final tid = _tripoTaskId;
    if (tid == null || _tripoService == null) return null;
    // lastResult.pbrModelUrl 来自后端 /status 接口，后端已做本地/远程降级
    return _tripoService!.lastResult?.pbrModelUrl ??
        '${BackendConfig.baseUrl}/tripo/model/$tid/glb';
  }

  /// 获取当前活跃预览图的完整 URL
  /// 优先用后端 /status 接口降级后的 URL（本地未就绪时返回远程 rendered_image_url），
  /// 兜底用本地路径（后端下载完成后可通过此路径访问）
  String? get activePreviewUrl {
    final tid = _tripoTaskId;
    if (tid == null || _tripoService == null) return null;
    // lastResult.renderedImageUrl 来自后端 /status 接口，已做本地/远程降级
    return _tripoService!.lastResult?.renderedImageUrl ??
        _tripoService!.previewUrl(tid);
  }

  /// 当前模型是否生成成功
  bool get tripoSucceeded =>
      _tripoTaskId != null &&
      _tripoService?.lastResult?.status == TripoTaskStatus.succeeded;

  /// 当前模型 GLB URL（远程或本地）
  String? get tripoPbrUrl => _tripoService?.lastResult?.pbrModelUrl;

  /// 当前渲染预览图 URL
  String? get tripoRenderedUrl => _tripoService?.lastResult?.renderedImageUrl;

  @override
  void dispose() {
    _disposed = true;
    _recordingTimer?.cancel();
    _modeSwitchUnlockTimer?.cancel();
    _idleTimer?.cancel();
    _sseService?.dispose();
    _audioRecorder?.dispose();
    _videoCapture?.dispose();
    _audioPlayer?.dispose();
    _connectivity?.dispose();
    _ttsService?.dispose();
    _offlineEngine?.dispose();
    _backgroundService?.dispose();
    _tripoService?.dispose();
    _cameraController?.dispose();
    super.dispose();
  }
}
