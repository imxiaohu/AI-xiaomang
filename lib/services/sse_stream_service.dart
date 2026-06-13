import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/sse_message.dart';

/// SSE事件回调
typedef SseTextCallback = void Function(SseTextChunk chunk);
typedef SseAudioCallback = void Function(SseAudioChunk chunk);
typedef SseEndCallback = void Function(SseEnd end);
typedef SseErrorCallback = void Function(SseError error);
typedef SseQuotaCallback = void Function(SseQuotaExceeded quota);

/// SSE客户端服务
/// 支持：文本分片推送、MP3音频分片推送（base64解码）、心跳检测、自动重连
class SseStreamService {
  final String baseUrl;
  final String sessionId;
  final String token;

  http.Client? _client;
  StreamSubscription? _subscription;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;

  int _reconnectCount = 0;
  static const int _maxReconnect = 5;

  bool _disposed = false;

  // Last-Event-ID 续传：记录最近一次成功收到的事件 ID
  // 重连时通过 query string 传给后端，从该位置之后开始重放
  int? _lastEventId;

  /// 暴露当前 lastEventId（用于诊断 / 强制重置时清零）
  int? get lastEventId => _lastEventId;

  /// 重置 lastEventId（用于 App 重启 / 主动放弃续传场景）
  void resetLastEventId() {
    _lastEventId = null;
  }

  // 回调
  SseTextCallback? onText;
  SseAudioCallback? onAudio;
  SseEndCallback? onEnd;
  SseErrorCallback? onError;
  SseQuotaCallback? onQuotaExceeded;
  VoidCallback? onConnected;
  VoidCallback? onDisconnected;

  // Omni 模式 VAD 事件回调
  VoidCallback? onOmniSpeechStarted;
  VoidCallback? onOmniSpeechStopped;
  VoidCallback? onOmniCommitted;
  SseAudioCallback? onOmniAudio; // Omni PCM 24kHz mono

  SseStreamService({
    required this.baseUrl,
    required this.sessionId,
    required this.token,
  });

  String _sseBuffer = '';
  // SSE 事件分隔符：sse_starlette 默认发 \r\n\r\n，但有些代理/CDN 会规范化为 \n\n
  // 这里两个都搜
  static final RegExp _sseEventSep = RegExp(r'\r\n\r\n|\n\n');

  /// 连接SSE
  Future<void> connect() async {
    if (_disposed) return;
    _client?.close();
    _client = http.Client();

    // 构造 query 参数：ctxId / token + 可选的 lastEventId 续传
    final queryParams = <String, String>{
      'ctxId': sessionId,
      'token': token,
    };
    if (_lastEventId != null && _lastEventId! > 0) {
      // 续传：从 _lastEventId 之后开始重放
      queryParams['lastEventId'] = _lastEventId.toString();
    }
    final uri = Uri.parse('$baseUrl/sse/chat').replace(
      queryParameters: queryParams,
    );

    try {
      final request = http.Request('GET', uri);
      request.headers['Accept'] = 'text/event-stream';
      request.headers['Cache-Control'] = 'no-cache';

      final streamedResponse = await _client!.send(request);
      final stream = streamedResponse.stream;

      _reconnectCount = 0;
      _startHeartbeat();
      onConnected?.call();

      _subscription = stream.listen(
        (data) => _handleData(utf8.decode(data)),
        onError: _handleError,
        onDone: _handleDone,
      );
    } catch (e) {
      _scheduleReconnect();
    }
  }

  void _handleData(String raw) {
    // 任何数据都重置超时计时器
    _lastDataTime = DateTime.now();

    _sseBuffer += raw;
    // 关键修复：sse_starlette 默认发 \r\n 行尾（CRLF），事件间用 \r\n\r\n 分隔
    // 原代码只搜 \n\n，匹配不到 → 事件被永远缓存，客户端看不到回复
    while (true) {
      final match = _sseEventSep.firstMatch(_sseBuffer);
      if (match == null) {
        // 还没遇到事件结束分隔符（可能事件跨 chunk 到达），继续累积
        break;
      }
      final eom = match.start;
      final eventText = _sseBuffer.substring(0, eom);
      _sseBuffer = _sseBuffer.substring(match.end);
      _parseEvent(eventText);
    }
  }

  void _parseEvent(String eventText) {
    // 解析单个SSE事件：event: type\nid: <num>\ndata: payload\n\n
    // 行尾可能是 \n 或 \r\n，统一 trim
    // 注意：后端 EventBus 改造后，事件现在会带 id 字段
    String? eventType;
    String? eventData;
    String? eventId;

    final lines = eventText.split('\n');
    for (final rawLine in lines) {
      // 去掉可能的 \r（CRLF 行尾）
      final line = rawLine.endsWith('\r') ? rawLine.substring(0, rawLine.length - 1) : rawLine;
      if (line.startsWith('event:')) {
        eventType = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        eventData = line.substring(5).trim();
      } else if (line.startsWith('id:')) {
        // Last-Event-ID：用于断线重连续传
        eventId = line.substring(3).trim();
      }
    }

    if (eventType == null || eventData == null) return;

    // 记录最近事件 ID（用于重连时传给后端）
    if (eventId != null) {
      final parsed = int.tryParse(eventId);
      if (parsed != null) {
        _lastEventId = parsed;
      }
    }

    switch (eventType) {
      case 'text':
        final json = jsonDecode(eventData) as Map<String, dynamic>;
        onText?.call(SseTextChunk(
          text: json['text'] as String? ?? '',
          isFinal: json['is_final'] as bool? ?? false,
          source: json['source'] as String?,
        ));
        break;
      case 'audio':
        final json = jsonDecode(eventData) as Map<String, dynamic>;
        onAudio?.call(SseAudioChunk(
          base64Audio: json['audio'] as String? ?? '',
          sampleIndex: json['index'] as int? ?? 0,
        ));
        break;
      case 'heartbeat':
        // 心跳：3秒一次，收到即重置计时器
        break;
      case 'error':
        final json = jsonDecode(eventData) as Map<String, dynamic>;
        onError?.call(SseError(
          code: json['code'] as String? ?? 'unknown',
          message: json['message'] as String? ?? 'Unknown error',
        ));
        break;
      case 'quota_exceeded':
        final json = jsonDecode(eventData) as Map<String, dynamic>;
        onQuotaExceeded?.call(SseQuotaExceeded(
          reason: json['reason'] as String? ?? 'Quota exceeded',
        ));
        break;
      // Omni 模式 VAD 事件
      case 'omni_speech_started':
        onOmniSpeechStarted?.call();
        break;
      case 'omni_speech_stopped':
        onOmniSpeechStopped?.call();
        break;
      case 'omni_committed':
        onOmniCommitted?.call();
        break;
      // Omni 音频流（PCM 24kHz stereo）
      case 'omni_audio':
        final json = jsonDecode(eventData) as Map<String, dynamic>;
        onOmniAudio?.call(SseAudioChunk(
          base64Audio: json['audio'] as String? ?? '',
          sampleIndex: json['index'] as int? ?? 0,
        ));
        break;
      case 'end':
        final json = jsonDecode(eventData) as Map<String, dynamic>;
        onEnd?.call(SseEnd(
          fullText: json['full_text'] as String?,
          totalAudioChunks: json['total_audio_chunks'] as int? ?? 0,
          audioSeconds: (json['audio_seconds'] as num?)?.toDouble() ?? 0.0,
        ));
        break;
    }
  }

  void _handleError(Object e) {
    _lastDataTime = null;
    if (_disposed) return;
    _scheduleReconnect();
  }

  void _handleDone() {
    if (_disposed) return;
    _stopHeartbeat();
    onDisconnected?.call();
    _scheduleReconnect();
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    // 3秒心跳检测：3s发送ping，5s无响应触发重连
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      // 客户端不主动发心跳，只被动接收；此处通过计时器检测超时
      _checkTimeout();
    });
  }

  DateTime? _lastDataTime;
  Timer? _timeoutTimer;

  void _checkTimeout() {
    _lastDataTime ??= DateTime.now();
    final elapsed = DateTime.now().difference(_lastDataTime!).inSeconds;
    if (elapsed >= 5) {
      // 5秒无数据，触发重连
      _lastDataTime = null;
      _scheduleReconnect();
    }
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _timeoutTimer?.cancel();
    _heartbeatTimer = null;
    _timeoutTimer = null;
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    if (_reconnectCount >= _maxReconnect) {
      // 5次重连失败，通知上层切换离线模式
      onError?.call(const SseError(
        code: 'max_reconnect',
        message: 'SSE重连次数已达上限，切换离线模式',
      ));
      return;
    }
    _reconnectCount++;
    onDisconnected?.call();
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      connect();
    });
  }

  /// 发送HTTP POST音频分片
  Future<void> sendAudioChunk(Uint8List pcmData) async {
    if (_disposed || _client == null) return;
    final encoded = base64Encode(pcmData);
    try {
      await _client!.post(
        Uri.parse('$baseUrl/upload/audio_chunk'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'ctxId': sessionId, 'audio': encoded}),
      );
    } catch (_) {}
  }

  /// 发送HTTP POST图像帧
  Future<void> sendFrame(Uint8List jpgData) async {
    if (_disposed || _client == null) return;
    final encoded = base64Encode(jpgData);
    try {
      await _client!.post(
        Uri.parse('$baseUrl/upload/frame'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'ctxId': sessionId, 'frame': encoded}),
      );
    } catch (_) {}
  }

  /// 结束当前推理轮次
  Future<void> endTurn() async {
    if (_disposed || _client == null) return;
    try {
      await _client!.post(
        Uri.parse('$baseUrl/upload/chat/end'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'ctxId': sessionId}),
      );
    } catch (_) {}
  }

  /// 切换 Omni 交互模式
  Future<void> setMode(String mode) async {
    if (_disposed || _client == null) return;
    try {
      await _client!.post(
        Uri.parse('$baseUrl/upload/mode'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'ctxId': sessionId, 'mode': mode}),
      );
    } catch (_) {}
  }

  /// 断开连接
  void disconnect() {
    _disposed = true;
    _stopHeartbeat();
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _client?.close();
    _client = null;
    onDisconnected?.call();
  }

  void dispose() => disconnect();
}
