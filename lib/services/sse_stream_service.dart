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

  // 回调
  SseTextCallback? onText;
  SseAudioCallback? onAudio;
  SseEndCallback? onEnd;
  SseErrorCallback? onError;
  SseQuotaCallback? onQuotaExceeded;
  VoidCallback? onConnected;
  VoidCallback? onDisconnected;

  SseStreamService({
    required this.baseUrl,
    required this.sessionId,
    required this.token,
  });

  String _sseBuffer = '';

  /// 连接SSE
  Future<void> connect() async {
    if (_disposed) return;
    _client?.close();
    _client = http.Client();

    final uri = Uri.parse('$baseUrl/sse/chat').replace(
      queryParameters: {'ctxId': sessionId, 'token': token},
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
    while (true) {
      final eom = _sseBuffer.indexOf('\n\n');
      if (eom == -1) {
        // 可能还有不完整的行（以单个\n结尾），检查是否需要等待更多数据
        if (_sseBuffer.contains('\n')) {
          // 有不完整的行，但还没遇到空行，继续累积
          break;
        }
        break;
      }
      final eventText = _sseBuffer.substring(0, eom);
      _sseBuffer = _sseBuffer.substring(eom + 2);
      _parseEvent(eventText);
    }
  }

  void _parseEvent(String eventText) {
    // 解析单个SSE事件：event: type\ndata: payload\n\n
    String? eventType;
    String? eventData;

    final lines = eventText.split('\n');
    for (final line in lines) {
      if (line.startsWith('event:')) {
        eventType = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        eventData = line.substring(5).trim();
      }
    }

    if (eventType == null || eventData == null) return;

    switch (eventType) {
      case 'text':
        final json = jsonDecode(eventData) as Map<String, dynamic>;
        onText?.call(SseTextChunk(
          text: json['text'] as String? ?? '',
          isFinal: json['is_final'] as bool? ?? false,
        ));
        break;
      case 'audio':
        final json = jsonDecode(eventData) as Map<String, dynamic>;
        onAudio?.call(SseAudioChunk(
          base64Audio: json['audio'] as String? ?? '',
          sampleIndex: json['index'] as int? ?? 0,
        ));
        break;
      case 'end':
        final json = jsonDecode(eventData) as Map<String, dynamic>;
        onEnd?.call(SseEnd(
          fullText: json['full_text'] as String?,
          totalAudioChunks: json['total_chunks'] as int? ?? 0,
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

