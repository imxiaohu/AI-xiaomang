import 'package:flutter/material.dart';
import '../services/marketplace_service.dart';

/// 3D 形象市场卡片（纯展示组件）
///
/// 200x240 圆角卡片：上方预览图 / 渐变占位 + 下方 title + owner + downloads。
/// 缺少 [MarketplaceItem.previewUrl] 时使用渐变占位，保证布局稳定。
class MarketplaceTile extends StatelessWidget {
  const MarketplaceTile({
    super.key,
    required this.item,
    required this.onTap,
    this.onLongPress,
  });

  final MarketplaceItem item;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (item.previewUrl != null)
                    Image.network(
                      item.previewUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          const GradientPlaceholder(),
                    )
                  else
                    const GradientPlaceholder(),
                  Positioned(
                    left: 6,
                    top: 6,
                    child: _TypeBadge(text: _typeZh(item.taskType)),
                  ),
                  if (item.visibility == 'unlisted')
                    const Positioned(
                      right: 6,
                      top: 6,
                      child: _TypeBadge(text: 'unlisted', color: Colors.orange),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        '@${item.ownerShort}',
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                      const Spacer(),
                      const Icon(Icons.download, size: 12, color: Colors.grey),
                      const SizedBox(width: 2),
                      Text(
                        '${item.downloads}',
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _typeZh(String t) {
    switch (t) {
      case 'text-to-3d':
        return '文生';
      case 'image-to-3d':
        return '图生';
      case 'multi-image-to-3d':
        return '多图';
      default:
        return t;
    }
  }
}

class GradientPlaceholder extends StatelessWidget {
  const GradientPlaceholder({super.key});
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xCC4D6AFF), Color(0xCC6B4EFF)],
        ),
      ),
      child: const Center(
        child: Icon(Icons.view_in_ar, size: 36, color: Colors.white70),
      ),
    );
  }
}

class _TypeBadge extends StatelessWidget {
  const _TypeBadge({required this.text, this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Colors.black54;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
