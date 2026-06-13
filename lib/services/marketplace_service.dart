import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/env_config.dart';

/// 市场条目（公开响应）
@immutable
class MarketplaceItem {
  final String id;
  final String taskId;
  final String ownerId;
  final String taskType; // text-to-3d | image-to-3d | multi-image-to-3d
  final String? prompt;
  final String modelName;
  final String textureQuality;
  final String status; // PENDING / RUNNING / SUCCEEDED / FAILED / CANCELED
  final String? title;
  final String tags;
  final String visibility; // public | unlisted | private
  final int downloads;
  final int views;
  final String? glbUrl;
  final String? baseUrl;
  final String? previewUrl;
  final DateTime createdAt;
  final DateTime updatedAt;

  const MarketplaceItem({
    required this.id,
    required this.taskId,
    required this.ownerId,
    required this.taskType,
    required this.modelName,
    required this.textureQuality,
    required this.status,
    required this.tags,
    required this.visibility,
    required this.downloads,
    required this.views,
    required this.createdAt,
    required this.updatedAt,
    this.prompt,
    this.title,
    this.glbUrl,
    this.baseUrl,
    this.previewUrl,
  });

  factory MarketplaceItem.fromJson(Map<String, dynamic> j) {
    DateTime parseDate(dynamic v) {
      if (v is String && v.isNotEmpty) {
        return DateTime.tryParse(v) ?? DateTime.now();
      }
      return DateTime.now();
    }

    return MarketplaceItem(
      id: (j['id'] ?? '') as String,
      taskId: (j['task_id'] ?? '') as String,
      ownerId: (j['owner_id'] ?? 'anonymous') as String,
      taskType: (j['task_type'] ?? 'text-to-3d') as String,
      prompt: j['prompt'] as String?,
      modelName: (j['model_name'] ?? 'Tripo/Tripo-P1.0') as String,
      textureQuality: (j['texture_quality'] ?? 'standard') as String,
      status: (j['status'] ?? 'UNKNOWN') as String,
      title: j['title'] as String?,
      tags: (j['tags'] ?? '') as String,
      visibility: (j['visibility'] ?? 'public') as String,
      downloads: (j['downloads'] ?? 0) as int,
      views: (j['views'] ?? 0) as int,
      glbUrl: j['glb_url'] as String?,
      baseUrl: j['base_url'] as String?,
      previewUrl: j['preview_url'] as String?,
      createdAt: parseDate(j['created_at']),
      updatedAt: parseDate(j['updated_at']),
    );
  }

  MarketplaceItem copyWith({
    String? title,
    String? tags,
    String? visibility,
    int? downloads,
    int? views,
    String? glbUrl,
    String? baseUrl,
    String? previewUrl,
  }) {
    return MarketplaceItem(
      id: id,
      taskId: taskId,
      ownerId: ownerId,
      taskType: taskType,
      prompt: prompt,
      modelName: modelName,
      textureQuality: textureQuality,
      status: status,
      title: title ?? this.title,
      tags: tags ?? this.tags,
      visibility: visibility ?? this.visibility,
      downloads: downloads ?? this.downloads,
      views: views ?? this.views,
      glbUrl: glbUrl ?? this.glbUrl,
      baseUrl: baseUrl ?? this.baseUrl,
      previewUrl: previewUrl ?? this.previewUrl,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  /// 短化的 owner ID（最多 8 字符），用于 UI 卡片显示
  String get ownerShort =>
      ownerId.length <= 8 ? ownerId : ownerId.substring(0, 8);

  /// UI 展示用：优先用 [title] 退化到 [prompt] 退化到类型占位
  String get displayTitle {
    if (title != null && title!.isNotEmpty) return title!;
    if (prompt != null && prompt!.isNotEmpty) {
      final s = prompt!.replaceAll('\n', ' ').trim();
      return s.length > 40 ? '${s.substring(0, 40)}…' : s;
    }
    switch (taskType) {
      case 'image-to-3d':
        return 'Image-to-3D model';
      case 'multi-image-to-3d':
        return 'Multi-image-to-3D model';
      default:
        return '3D model';
    }
  }

  /// 把后端返回的相对 URL 拼成绝对 URL。
  String? resolveUrl(String? maybe, {required String base}) {
    if (maybe == null) return null;
    if (maybe.startsWith('http://') || maybe.startsWith('https://')) return maybe;
    final sep = (base.endsWith('/') || maybe.startsWith('/')) ? '' : '/';
    return '$base$sep$maybe';
  }
}

/// 市场分页响应
@immutable
class MarketplaceList {
  final List<MarketplaceItem> items;
  final int total;
  final int page;
  final int pageSize;

  const MarketplaceList({
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
  });

  factory MarketplaceList.fromJson(Map<String, dynamic> j) {
    final raw = (j['items'] ?? const <dynamic>[]) as List<dynamic>;
    return MarketplaceList(
      items: raw
          .whereType<Map<String, dynamic>>()
          .map(MarketplaceItem.fromJson)
          .toList(),
      total: (j['total'] ?? 0) as int,
      page: (j['page'] ?? 1) as int,
      pageSize: (j['page_size'] ?? 24) as int,
    );
  }
}

/// 3D 形象市场后端客户端
///
/// 所有需要鉴权的接口都会带上 `X-User-Token: <token>` 头；
/// 私有模型访问会被后端 403 拦截（MarketplaceService 透传该错误）。
class MarketplaceService {
  final String baseUrl;
  final String token;
  http.Client _client;

  MarketplaceService({String? baseUrl, String? token})
      : baseUrl = baseUrl ?? BackendConfig.baseUrl,
        token = token ?? BackendConfig.defaultToken,
        _client = http.Client();

  /// 暴露底层 client（设置页"测试连接"等场景使用）
  http.Client get httpClient => _client;

  Map<String, String> _headers({bool json = true}) {
    return {
      if (json) 'Content-Type': 'application/json',
      if (token.isNotEmpty) 'X-User-Token': token,
    };
  }

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final base = Uri.parse(baseUrl);
    final cleanedQuery = <String, String>{};
    query?.forEach((k, v) {
      if (v == null) return;
      final s = v.toString();
      if (s.isEmpty) return;
      cleanedQuery[k] = s;
    });
    return base.replace(
      path: '${base.path}$path'.replaceAll(RegExp(r'/+'), '/'),
      queryParameters: cleanedQuery.isEmpty ? null : cleanedQuery,
    );
  }

  Never _throwFor(http.Response resp) {
    throw HttpException(
      statusCode: resp.statusCode,
      body: resp.body,
      method: resp.request?.method ?? 'GET',
      url: resp.request?.url.toString() ?? '',
    );
  }

  // ── 公开列表 ──
  Future<MarketplaceList> list({
    String? q,
    String? type,
    String sort = 'recent',
    int page = 1,
    int pageSize = 24,
  }) async {
    final resp = await _client.get(
      _uri('/tripo/marketplace', {
        'q': q,
        'type': type,
        'sort': sort,
        'page': page,
        'page_size': pageSize,
      }),
      headers: _headers(json: false),
    );
    if (resp.statusCode != 200) _throwFor(resp);
    return MarketplaceList.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
  }

  // ── 我的模型 ──
  Future<List<MarketplaceItem>> myModels() async {
    final resp = await _client.get(
      _uri('/tripo/marketplace/me'),
      headers: _headers(json: false),
    );
    if (resp.statusCode != 200) _throwFor(resp);
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    final items = (j['items'] as List<dynamic>? ?? const <dynamic>[]);
    return items
        .whereType<Map<String, dynamic>>()
        .map(MarketplaceItem.fromJson)
        .toList();
  }

  // ── 单条详情 ──
  Future<MarketplaceItem> get(String modelId) async {
    final resp = await _client.get(
      _uri('/tripo/marketplace/$modelId'),
      headers: _headers(json: false),
    );
    if (resp.statusCode != 200) _throwFor(resp);
    return MarketplaceItem.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
  }

  // ── 下载（递增计数器，返回带 URL 的条目）──
  Future<MarketplaceItem> download(String modelId) async {
    final resp = await _client.post(
      _uri('/tripo/marketplace/$modelId/download'),
      headers: _headers(json: false),
    );
    if (resp.statusCode != 200) _throwFor(resp);
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    // 后端返回的 download 响应里只有 URL，缺字段。回填到原 item 后返回。
    final base = await get(modelId);
    return base.copyWith(downloads: base.downloads + 1).copyWith(
      glbUrl: (j['glb_url'] as String?) ?? base.glbUrl,
      baseUrl: (j['base_url'] as String?) ?? base.baseUrl,
      previewUrl: (j['preview_url'] as String?) ?? base.previewUrl,
    );
  }

  // ── 改可见性 ──
  Future<MarketplaceItem> setVisibility(String modelId, String visibility) async {
    final resp = await _client.patch(
      _uri('/tripo/marketplace/$modelId/visibility'),
      headers: _headers(),
      body: jsonEncode({'visibility': visibility}),
    );
    if (resp.statusCode != 200) _throwFor(resp);
    return MarketplaceItem.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
  }

  // ── 改 title / tags ──
  Future<MarketplaceItem> update(
    String modelId, {
    String? title,
    String? tags,
  }) async {
    final body = <String, dynamic>{};
    if (title != null) body['title'] = title;
    if (tags != null) body['tags'] = tags;
    final resp = await _client.put(
      _uri('/tripo/marketplace/$modelId'),
      headers: _headers(),
      body: jsonEncode(body),
    );
    if (resp.statusCode != 200) _throwFor(resp);
    return MarketplaceItem.fromJson(
      jsonDecode(resp.body) as Map<String, dynamic>,
    );
  }

  // ── 删除 ──
  Future<void> delete(String modelId) async {
    final resp = await _client.delete(
      _uri('/tripo/marketplace/$modelId'),
      headers: _headers(json: false),
    );
    if (resp.statusCode != 200) _throwFor(resp);
  }

  // ── 缓存统计 / 清理（用于设置页"3D 模型 → 缓存"区块）──
  Future<Map<String, dynamic>> cacheStats() async {
    final resp = await _client.get(
      _uri('/tripo/marketplace/cache/stats'),
      headers: _headers(json: false),
    );
    if (resp.statusCode != 200) _throwFor(resp);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<int> clearCache({int olderThanDays = 0}) async {
    final resp = await _client.delete(
      _uri('/tripo/marketplace/cache', {'older_than_days': olderThanDays}),
      headers: _headers(json: false),
    );
    if (resp.statusCode != 200) _throwFor(resp);
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    return (j['removed_files'] ?? 0) as int;
  }

  /// 把后端返回的相对 glb_url 拼成绝对地址（model_viewer 需要 http://）
  String resolveGlbUrl(MarketplaceItem item) =>
      item.resolveUrl(item.glbUrl, base: baseUrl) ?? '';

  String resolvePreviewUrl(MarketplaceItem item) =>
      item.resolveUrl(item.previewUrl, base: baseUrl) ?? '';

  void dispose() {
    _client.close();
  }
}

/// 简单的 HTTP 错误包装，便于上层在 SnackBar 中显示后端返回的 detail。
class HttpException implements Exception {
  final int statusCode;
  final String body;
  final String method;
  final String url;

  HttpException({
    required this.statusCode,
    required this.body,
    required this.method,
    required this.url,
  });

  /// 提取 FastAPI `{"detail": "..."}` 中的 detail 文本；没有时降级到原始 body。
  String get displayMessage {
    try {
      final j = jsonDecode(body);
      if (j is Map && j['detail'] is String) return j['detail'] as String;
    } catch (_) {}
    return body;
  }

  @override
  String toString() => 'HTTP $statusCode $method $url: ${displayMessage}';
}
