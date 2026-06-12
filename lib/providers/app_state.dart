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
  double get modelLoadProgress => _modelLoadProgress;
  bool get modelLoaded => _modelLoaded;

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
    _modelLoadProgress = 1.0;
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
      _currentStreamingText += chunk.text;
      notifyListeners();
      if (chunk.isFinal) {
        addAiMessage(_currentStreamingText);
        _currentStreamingText = '';
        notifyListeners();
      }
    };
    _sseService!.onAudio = (chunk) {
      _audioPlayer?.enqueue(chunk.base64Audio);
    };
    _sseService!.onEnd = (end) {
      _resetIdleTimer();
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
  void startListening() {
    if (_aiStatus != AiStatus.idle) return;
    _aiStatus = AiStatus.listening;
    _recordingSeconds = 0;
    _resetIdleTimer();
    notifyListeners();

    // 启动录音（云端上传分片，离线本地识别）
    _audioRecorder?.startRecording();

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
  void stopListeningAndThink() {
    if (_aiStatus != AiStatus.listening) return;
    _recordingTimer?.cancel();
    _recordingSeconds = 0;
    _aiStatus = AiStatus.thinking;
    notifyListeners();

    _audioRecorder?.stopRecording();
    _videoCapture?.stopCapture();

    _processInference();
  }

  void _processInference() async {
    if (_runMode == AppRunMode.cloudAliyun) {
      // 云端推理：通过SSE接收流式结果
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
    _cameraController?.dispose();
    super.dispose();
  }
}
