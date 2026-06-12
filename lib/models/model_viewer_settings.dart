/// 3D模型显示与生成配置
class ModelViewerSettings {
  /// 自动旋转
  final bool autoRotate;

  /// 阴影强度（0.0~1.0）
  final double shadowIntensity;

  /// 曝光度（0.0~2.0）
  final double exposure;

  /// 3D生成模型类型
  final String tripoModel;

  /// 贴图质量
  final String textureQuality;

  /// 默认AI形象taskId
  final String? avatarTaskId;

  /// 闪光灯默认开启
  final bool flashDefaultOn;

  /// 默认摄像头（true=后摄，false=前摄）
  final bool defaultBackCamera;

  /// 显示调试信息
  final bool showDebugInfo;

  /// 优先使用3D球体而非模型
  final bool prefer3DBall;

  const ModelViewerSettings({
    this.autoRotate = true,
    this.shadowIntensity = 0.5,
    this.exposure = 0.9,
    this.tripoModel = 'Tripo/Tripo-P1.0',
    this.textureQuality = 'standard',
    this.avatarTaskId,
    this.flashDefaultOn = false,
    this.defaultBackCamera = true,
    this.showDebugInfo = false,
    this.prefer3DBall = false,
  });

  ModelViewerSettings copyWith({
    bool? autoRotate,
    double? shadowIntensity,
    double? exposure,
    String? tripoModel,
    String? textureQuality,
    String? avatarTaskId,
    bool? flashDefaultOn,
    bool? defaultBackCamera,
    bool? showDebugInfo,
    bool? prefer3DBall,
    bool clearAvatarTaskId = false,
  }) {
    return ModelViewerSettings(
      autoRotate: autoRotate ?? this.autoRotate,
      shadowIntensity: shadowIntensity ?? this.shadowIntensity,
      exposure: exposure ?? this.exposure,
      tripoModel: tripoModel ?? this.tripoModel,
      textureQuality: textureQuality ?? this.textureQuality,
      avatarTaskId:
          clearAvatarTaskId ? null : (avatarTaskId ?? this.avatarTaskId),
      flashDefaultOn: flashDefaultOn ?? this.flashDefaultOn,
      defaultBackCamera: defaultBackCamera ?? this.defaultBackCamera,
      showDebugInfo: showDebugInfo ?? this.showDebugInfo,
      prefer3DBall: prefer3DBall ?? this.prefer3DBall,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'autoRotate': autoRotate,
      'shadowIntensity': shadowIntensity,
      'exposure': exposure,
      'tripoModel': tripoModel,
      'textureQuality': textureQuality,
      'avatarTaskId': avatarTaskId,
      'flashDefaultOn': flashDefaultOn,
      'defaultBackCamera': defaultBackCamera,
      'showDebugInfo': showDebugInfo,
      'prefer3DBall': prefer3DBall,
    };
  }

  factory ModelViewerSettings.fromJson(Map<String, dynamic> json) {
    return ModelViewerSettings(
      autoRotate: json['autoRotate'] as bool? ?? true,
      shadowIntensity: (json['shadowIntensity'] as num?)?.toDouble() ?? 0.5,
      exposure: (json['exposure'] as num?)?.toDouble() ?? 0.9,
      tripoModel: json['tripoModel'] as String? ?? 'Tripo/Tripo-P1.0',
      textureQuality: json['textureQuality'] as String? ?? 'standard',
      avatarTaskId: json['avatarTaskId'] as String?,
      flashDefaultOn: json['flashDefaultOn'] as bool? ?? false,
      defaultBackCamera: json['defaultBackCamera'] as bool? ?? true,
      showDebugInfo: json['showDebugInfo'] as bool? ?? false,
      prefer3DBall: json['prefer3DBall'] as bool? ?? false,
    );
  }
}

/// 静态可用选项
class ModelViewerOptions {
  static const List<String> tripoModelOptions = [
    'Tripo/Tripo-P1.0',
    'Tripo/Tripo-H3.1',
  ];

  static const List<String> tripoModelLabels = [
    'P1.0（标准）',
    'H3.1（精细）',
  ];

  static const List<String> textureQualityOptions = [
    'standard',
    'detailed',
  ];

  static const List<String> textureQualityLabels = [
    '标准',
    '精细',
  ];
}
