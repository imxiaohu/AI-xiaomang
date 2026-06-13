import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/env_config.dart';
import '../models/enums.dart';

/// 不可变设置对象。所有用户偏好都集中在这里，
/// 由 [SettingsService] 负责加载和持久化。
@immutable
class AppSettings {
  /// 后端基础 URL（不含末尾斜杠）。空字符串表示沿用 [BackendConfig.baseUrl]。
  final String backendUrl;

  /// 用户令牌，会随每个请求以 `X-User-Token` 头发送。
  final String authToken;

  /// 默认运行模式（云端 / 离线）。
  final AppRunMode defaultRunMode;

  /// 默认 Omni 交互模式（手动 / VAD）。
  final OmniInteractionMode defaultOmniMode;

  /// TTS 音色。
  final String ttsVoice;

  /// TTS 语速（0.3 .. 1.0）。
  final double ttsRate;

  /// TTS 音量（0.0 .. 1.0）。
  final double ttsVolume;

  /// Tripo 模型名称。
  final String tripoModel;

  /// Tripo 贴图质量。
  final String tripoTextureQuality;

  /// 新生成 3D 模型的默认可见性（public / unlisted / private）。
  final String defaultModelVisibility;

  /// 市场列表分页大小。
  final int marketplacePageSize;

  /// 主题模式。
  final ThemeMode themeMode;

  /// 用户当前选中的市场模型 ID（跨重启保留）。
  final String? activeMarketplaceModelId;

  const AppSettings({
    this.backendUrl = '',
    this.authToken = BackendConfig.defaultToken,
    this.defaultRunMode = AppRunMode.cloudAliyun,
    this.defaultOmniMode = OmniInteractionMode.manual,
    this.ttsVoice = 'Cherry',
    this.ttsRate = 1.0,
    this.ttsVolume = 0.5,
    this.tripoModel = 'Tripo/Tripo-P1.0',
    this.tripoTextureQuality = 'standard',
    this.defaultModelVisibility = 'public',
    this.marketplacePageSize = 24,
    this.themeMode = ThemeMode.system,
    this.activeMarketplaceModelId,
  });

  AppSettings copyWith({
    String? backendUrl,
    String? authToken,
    AppRunMode? defaultRunMode,
    OmniInteractionMode? defaultOmniMode,
    String? ttsVoice,
    double? ttsRate,
    double? ttsVolume,
    String? tripoModel,
    String? tripoTextureQuality,
    String? defaultModelVisibility,
    int? marketplacePageSize,
    ThemeMode? themeMode,
    Object? activeMarketplaceModelId = _sentinel,
  }) {
    return AppSettings(
      backendUrl: backendUrl ?? this.backendUrl,
      authToken: authToken ?? this.authToken,
      defaultRunMode: defaultRunMode ?? this.defaultRunMode,
      defaultOmniMode: defaultOmniMode ?? this.defaultOmniMode,
      ttsVoice: ttsVoice ?? this.ttsVoice,
      ttsRate: ttsRate ?? this.ttsRate,
      ttsVolume: ttsVolume ?? this.ttsVolume,
      tripoModel: tripoModel ?? this.tripoModel,
      tripoTextureQuality: tripoTextureQuality ?? this.tripoTextureQuality,
      defaultModelVisibility:
          defaultModelVisibility ?? this.defaultModelVisibility,
      marketplacePageSize: marketplacePageSize ?? this.marketplacePageSize,
      themeMode: themeMode ?? this.themeMode,
      activeMarketplaceModelId: identical(activeMarketplaceModelId, _sentinel)
          ? this.activeMarketplaceModelId
          : activeMarketplaceModelId as String?,
    );
  }

  /// 显式支持「清空」`activeMarketplaceModelId` 的 sentinel，
  /// 因为 `copyWith` 的命名参数无法直接区分「不传」和「传 null」。
  static const Object _sentinel = Object();

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AppSettings &&
        other.backendUrl == backendUrl &&
        other.authToken == authToken &&
        other.defaultRunMode == defaultRunMode &&
        other.defaultOmniMode == defaultOmniMode &&
        other.ttsVoice == ttsVoice &&
        other.ttsRate == ttsRate &&
        other.ttsVolume == ttsVolume &&
        other.tripoModel == tripoModel &&
        other.tripoTextureQuality == tripoTextureQuality &&
        other.defaultModelVisibility == defaultModelVisibility &&
        other.marketplacePageSize == marketplacePageSize &&
        other.themeMode == themeMode &&
        other.activeMarketplaceModelId == activeMarketplaceModelId;
  }

  @override
  int get hashCode => Object.hash(
        backendUrl,
        authToken,
        defaultRunMode,
        defaultOmniMode,
        ttsVoice,
        ttsRate,
        ttsVolume,
        tripoModel,
        tripoTextureQuality,
        defaultModelVisibility,
        marketplacePageSize,
        themeMode,
        activeMarketplaceModelId,
      );
}

/// SharedPreferences 包装。所有键都带 `aivideo.setting.v1.` 前缀，
/// 方便以后做无侵入的 schema 迁移。
class SettingsService {
  static const String _prefix = 'aivideo.setting.v1.';

  static const String _kBackendUrl = '${_prefix}backend_url';
  static const String _kAuthToken = '${_prefix}auth_token';
  static const String _kDefaultRunMode = '${_prefix}default_run_mode';
  static const String _kDefaultOmniMode = '${_prefix}default_omni_mode';
  static const String _kTtsVoice = '${_prefix}tts_voice';
  static const String _kTtsRate = '${_prefix}tts_rate';
  static const String _kTtsVolume = '${_prefix}tts_volume';
  static const String _kTripoModel = '${_prefix}tripo_model';
  static const String _kTripoTextureQuality = '${_prefix}tripo_texture_quality';
  static const String _kDefaultModelVisibility =
      '${_prefix}default_model_visibility';
  static const String _kMarketplacePageSize =
      '${_prefix}marketplace_page_size';
  static const String _kThemeMode = '${_prefix}theme_mode';
  static const String _kActiveMarketplaceModelId =
      '${_prefix}active_marketplace_model_id';

  /// 加载设置；首次启动时返回 [AppSettings] 默认值。
  Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings(
      backendUrl: prefs.getString(_kBackendUrl) ?? '',
      authToken: prefs.getString(_kAuthToken) ?? BackendConfig.defaultToken,
      defaultRunMode: _parseRunMode(prefs.getString(_kDefaultRunMode)),
      defaultOmniMode: _parseOmniMode(prefs.getString(_kDefaultOmniMode)),
      ttsVoice: prefs.getString(_kTtsVoice) ?? 'Cherry',
      ttsRate: prefs.getDouble(_kTtsRate) ?? 1.0,
      ttsVolume: prefs.getDouble(_kTtsVolume) ?? 0.5,
      tripoModel: prefs.getString(_kTripoModel) ?? 'Tripo/Tripo-P1.0',
      tripoTextureQuality:
          prefs.getString(_kTripoTextureQuality) ?? 'standard',
      defaultModelVisibility:
          prefs.getString(_kDefaultModelVisibility) ?? 'public',
      marketplacePageSize: prefs.getInt(_kMarketplacePageSize) ?? 24,
      themeMode: _parseThemeMode(prefs.getString(_kThemeMode)),
      activeMarketplaceModelId:
          prefs.getString(_kActiveMarketplaceModelId),
    );
  }

  /// 持久化设置。
  Future<void> save(AppSettings s) async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setString(_kBackendUrl, s.backendUrl),
      prefs.setString(_kAuthToken, s.authToken),
      prefs.setString(_kDefaultRunMode, s.defaultRunMode.name),
      prefs.setString(_kDefaultOmniMode, s.defaultOmniMode.name),
      prefs.setString(_kTtsVoice, s.ttsVoice),
      prefs.setDouble(_kTtsRate, s.ttsRate),
      prefs.setDouble(_kTtsVolume, s.ttsVolume),
      prefs.setString(_kTripoModel, s.tripoModel),
      prefs.setString(_kTripoTextureQuality, s.tripoTextureQuality),
      prefs.setString(_kDefaultModelVisibility, s.defaultModelVisibility),
      prefs.setInt(_kMarketplacePageSize, s.marketplacePageSize),
      prefs.setString(_kThemeMode, s.themeMode.name),
      if (s.activeMarketplaceModelId == null)
        prefs.remove(_kActiveMarketplaceModelId)
      else
        prefs.setString(
            _kActiveMarketplaceModelId, s.activeMarketplaceModelId!),
    ]);
  }

  /// 清空所有已知键，恢复到 [AppSettings] 默认值。
  Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = <String>[
      _kBackendUrl,
      _kAuthToken,
      _kDefaultRunMode,
      _kDefaultOmniMode,
      _kTtsVoice,
      _kTtsRate,
      _kTtsVolume,
      _kTripoModel,
      _kTripoTextureQuality,
      _kDefaultModelVisibility,
      _kMarketplacePageSize,
      _kThemeMode,
      _kActiveMarketplaceModelId,
    ];
    for (final k in keys) {
      await prefs.remove(k);
    }
  }

  // ── 解析枚举（健壮处理未知值）──
  AppRunMode _parseRunMode(String? raw) {
    for (final m in AppRunMode.values) {
      if (m.name == raw) return m;
    }
    return AppRunMode.cloudAliyun;
  }

  OmniInteractionMode _parseOmniMode(String? raw) {
    for (final m in OmniInteractionMode.values) {
      if (m.name == raw) return m;
    }
    return OmniInteractionMode.manual;
  }

  ThemeMode _parseThemeMode(String? raw) {
    switch (raw) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }
}
