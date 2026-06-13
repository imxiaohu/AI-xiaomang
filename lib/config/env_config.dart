/// 统一后端配置
/// baseUrl 通过编译时常量注入，允许生产环境覆盖：
///   flutter run --dart-define=backend.url=https://api.example.com
class BackendConfig {
  BackendConfig._();

  /// 后端 HTTP/HTTPS 地址（不含末尾斜杠）
  /// 在 DEBUG 模式下默认为 localhost，生产构建请通过 --dart-define 注入
  static const String baseUrl = String.fromEnvironment(
    'backend.url',
    defaultValue: 'http://192.168.31.34:8000',
  );

  /// SSE endpoint 路径
  static const String ssePath = '/sse/chat';

  /// 上传 endpoint 路径
  static const String uploadAudioPath = '/upload/audio_chunk';
  static const String uploadFramePath = '/upload/frame';
  static const String endTurnPath = '/upload/chat/end';
  static const String inferPath = '/chat/infer';

  /// Tripo 3D生成 endpoint 路径
  static const String tripoTextTo3DPath = '/tripo/text-to-3d';
  static const String tripoImageTo3DPath = '/tripo/image-to-3d';
  static const String tripoStatusPath = '/tripo/status';
  static const String tripoGlbPath = '/tripo/model';
  static const String tripoPreviewPath = '/tripo/model';

  /// 连接参数
  static const String defaultToken = 'dev_token';
}
