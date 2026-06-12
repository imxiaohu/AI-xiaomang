import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// 图像压缩工具
/// 将任意格式图片压缩到指定分辨率和质量（JPG格式）
class ImageCompressor {
  /// 压缩图片
  /// [input] 原始图片字节数据
  /// [width] 目标宽度
  /// [height] 目标高度
  /// [quality] JPG压缩质量（0-100），不得低于55以保证VL准确率
  static Future<Uint8List> compress(
    Uint8List input, {
    required int width,
    required int height,
    int quality = 65,
  }) async {
    final decoded = img.decodeImage(input);
    if (decoded == null) return input;

    // 缩放
    final resized = img.copyResize(
      decoded,
      width: width,
      height: height,
      interpolation: img.Interpolation.linear,
    );

    // 编码为JPG（质量不低于55）
    final clampedQuality = quality.clamp(55, 100);
    return Uint8List.fromList(img.encodeJpg(resized, quality: clampedQuality));
  }

  /// 生成缩略图（用于对话气泡中的小图）
  static Future<Uint8List> thumbnail(Uint8List input, {int size = 48}) async {
    final decoded = img.decodeImage(input);
    if (decoded == null) return input;

    final thumb = img.copyResizeCropSquare(decoded, size: size);
    return Uint8List.fromList(img.encodeJpg(thumb, quality: 60));
  }
}
