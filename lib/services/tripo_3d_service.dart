import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/env_config.dart';

enum TripoTaskStatus {
  pending,
  running,
  succeeded,
  failed,
  canceled,
  unknown,
}

class TripoUsage {
  final String? taskType;   // text-to-3d | image-to-3d | multi-image-to-3d
  final int count;
  final String textureQuality;
  final String? geometryQuality;

  const TripoUsage({
    this.taskType,
    this.count = 0,
    this.textureQuality = 'standard',
    this.geometryQuality,
  });
}

class TripoTaskResult {
  final String taskId;
  final TripoTaskStatus status;
  final String? pbrModelUrl;      // GLB with PBR material
  final String? baseModelUrl;      // 无贴图基础模型
  final String? renderedImageUrl;  // 渲染预览图
  final String? taskType;
  final String? submitTime;
  final String? endTime;
  final String? errorMessage;

  const TripoTaskResult({
    required this.taskId,
    required this.status,
    this.pbrModelUrl,
    this.baseModelUrl,
    this.renderedImageUrl,
    this.taskType,
    this.submitTime,
    this.endTime,
    this.errorMessage,
  });
}

class TripoStatusResponse {
  final int code;
  final String taskId;
  final TripoTaskStatus taskStatus;
  final String? pbrModelUrl;
  final String? baseModelUrl;
  final String? renderedImageUrl;
  final String? taskType;
  final String? submitTime;
  final String? endTime;

  const TripoStatusResponse({
    required this.code,
    required this.taskId,
    required this.taskStatus,
    this.pbrModelUrl,
    this.baseModelUrl,
    this.renderedImageUrl,
    this.taskType,
    this.submitTime,
    this.endTime,
  });
}

typedef TripoProgressCallback = void Function(TripoTaskStatus status, String? message);

/// Tripo 3D模型生成服务
/// 与后端 /tripo/* 路由通信，支持文生3D、单图生3D、多图生3D
class TripoService {
  final String baseUrl;
  final String token;

  http.Client? _client;
  Timer? _pollTimer;
  TripoProgressCallback? onProgress;
  VoidCallback? onComplete;
  ValueChanged<String>? onError;

  TripoTaskResult? _lastResult;
  TripoTaskResult? get lastResult => _lastResult;

  /// 当前活跃任务ID
  String? _activeTaskId;
  String? get activeTaskId => _activeTaskId;

  /// 是否在生成中
  bool get isGenerating => _pollTimer != null && _activeTaskId != null;

  TripoService({String? baseUrl, String? token})
      : baseUrl = baseUrl ?? BackendConfig.baseUrl,
        token = token ?? BackendConfig.defaultToken {
    _client = http.Client();
  }

  String get _baseUri => baseUrl;

  Map<String, dynamic> _extractData(http.Response resp) {
    if (resp.statusCode != 200) {
      throw Exception('Tripo API ${resp.statusCode}: ${resp.body}');
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    if (data['code'] != 0) {
      throw Exception(data['message'] ?? 'Unknown error');
    }
    return data;
  }

  /// 文生3D（原始响应：返回 model_id 等所有字段，便于上层缓存关联）
  Future<Map<String, dynamic>> textTo3DRaw({
    required String prompt,
    String model = 'Tripo/Tripo-P1.0',
    String textureQuality = 'standard',
  }) async {
    final resp = await _client!.post(
      Uri.parse('$_baseUri/tripo/text-to-3d'),
      headers: {
        'Content-Type': 'application/json',
        if (token.isNotEmpty) 'X-User-Token': token,
      },
      body: jsonEncode({
        'prompt': prompt,
        'model': model,
        'texture_quality': textureQuality,
      }),
    );
    return _extractData(resp);
  }

  /// 单图生3D（原始响应）
  Future<Map<String, dynamic>> imageTo3DRaw({
    required String imageUrl,
    String model = 'Tripo/Tripo-P1.0',
    String textureQuality = 'standard',
  }) async {
    final resp = await _client!.post(
      Uri.parse('$_baseUri/tripo/image-to-3d'),
      headers: {
        'Content-Type': 'application/json',
        if (token.isNotEmpty) 'X-User-Token': token,
      },
      body: jsonEncode({
        'image_url': imageUrl,
        'model': model,
        'texture_quality': textureQuality,
      }),
    );
    return _extractData(resp);
  }

  /// 多图生3D（原始响应）
  Future<Map<String, dynamic>> multiImageTo3DRaw({
    required List<Map<String, String>?> images,
    String model = 'Tripo/Tripo-P1.0',
    String textureQuality = 'standard',
  }) async {
    final imagesPayload = images.map((img) {
      if (img == null) return <String, dynamic>{};
      return {
        'type': img['type'] ?? 'png',
        'file_token': img['file_token'],
      };
    }).toList();

    final resp = await _client!.post(
      Uri.parse('$_baseUri/tripo/multi-image-to-3d'),
      headers: {
        'Content-Type': 'application/json',
        if (token.isNotEmpty) 'X-User-Token': token,
      },
      body: jsonEncode({
        'images': imagesPayload,
        'model': model,
        'texture_quality': textureQuality,
      }),
    );
    return _extractData(resp);
  }

  /// 文生3D
  Future<String> textTo3D({
    required String prompt,
    String model = 'Tripo/Tripo-P1.0',
    String textureQuality = 'standard',
  }) async {
    final data = await textTo3DRaw(
      prompt: prompt,
      model: model,
      textureQuality: textureQuality,
    );
    return data['task_id'] as String;
  }

  /// 单图生3D
  Future<String> imageTo3D({
    required String imageUrl,
    String model = 'Tripo/Tripo-P1.0',
    String textureQuality = 'standard',
  }) async {
    final data = await imageTo3DRaw(
      imageUrl: imageUrl,
      model: model,
      textureQuality: textureQuality,
    );
    return data['task_id'] as String;
  }

  /// 多图生3D
  /// images: 固定4个元素 [前, 左, 后, 右]，不需要的传 null
  Future<String> multiImageTo3D({
    required List<Map<String, String>?> images,
    String model = 'Tripo/Tripo-P1.0',
    String textureQuality = 'standard',
  }) async {
    final data = await multiImageTo3DRaw(
      images: images,
      model: model,
      textureQuality: textureQuality,
    );
    return data['task_id'] as String;
  }

  /// 查询任务状态
  Future<TripoStatusResponse> getStatus(String taskId) async {
    final resp = await _client!.get(
      Uri.parse('$_baseUri/tripo/status/$taskId'),
      headers: {if (token.isNotEmpty) 'X-User-Token': token},
    );

    if (resp.statusCode == 503) {
      throw Exception('DASHSCOPE_API_KEY not configured on server');
    }
    if (resp.statusCode == 404) {
      throw Exception('任务不存在或已过期（task_id有效期24小时）');
    }
    if (resp.statusCode != 200) {
      throw Exception('Failed to get status: ${resp.body}');
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return TripoStatusResponse(
      code: data['code'] as int? ?? -1,
      taskId: data['task_id'] as String? ?? taskId,
      taskStatus: _parseStatus(data['task_status'] as String? ?? 'UNKNOWN'),
      pbrModelUrl: data['pbr_model_url'] as String?,
      baseModelUrl: data['base_model_url'] as String?,
      renderedImageUrl: data['rendered_image_url'] as String?,
      taskType: data['task_type'] as String?,
      submitTime: data['submit_time'] as String?,
      endTime: data['end_time'] as String?,
    );
  }

  TripoTaskStatus _parseStatus(String s) {
    switch (s.toUpperCase()) {
      case 'PENDING':
        return TripoTaskStatus.pending;
      case 'RUNNING':
        return TripoTaskStatus.running;
      case 'SUCCEEDED':
        return TripoTaskStatus.succeeded;
      case 'FAILED':
        return TripoTaskStatus.failed;
      case 'CANCELED':
      case 'CANCELLED':
        return TripoTaskStatus.canceled;
      default:
        return TripoTaskStatus.unknown;
    }
  }

  /// 开始轮询任务状态（5秒间隔）
  void startPolling(String taskId) {
    cancelPolling();
    _activeTaskId = taskId;
    _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      try {
        final status = await getStatus(taskId);
        _lastResult = TripoTaskResult(
          taskId: taskId,
          status: status.taskStatus,
          pbrModelUrl: status.pbrModelUrl,
          baseModelUrl: status.baseModelUrl,
          renderedImageUrl: status.renderedImageUrl,
          taskType: status.taskType,
          submitTime: status.submitTime,
          endTime: status.endTime,
        );
        onProgress?.call(status.taskStatus, null);

        if (status.taskStatus == TripoTaskStatus.succeeded ||
            status.taskStatus == TripoTaskStatus.failed ||
            status.taskStatus == TripoTaskStatus.canceled) {
          cancelPolling();
          onComplete?.call();
        }
      } catch (e) {
        onError?.call(e.toString());
        cancelPolling();
      }
    });
  }

  /// 取消轮询
  void cancelPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _activeTaskId = null;
  }

  /// 获取本地GLB文件的URL
  String glbUrl(String taskId) => '$_baseUri/tripo/model/$taskId/glb';

  /// 获取本地基础模型（无贴图）URL
  String glbBaseUrl(String taskId) => '$_baseUri/tripo/model/$taskId/glb_base';

  /// 获取本地预览图的URL
  String previewUrl(String taskId) => '$_baseUri/tripo/model/$taskId/preview';

  void dispose() {
    cancelPolling();
    _client?.close();
    _client = null;
  }
}
