import 'package:flutter/material.dart';
import '../models/enums.dart';

/// 顶部状态栏组件
/// 显示：模式标签、连接状态、模型下载/加载进度、闪光灯开关、摄像头翻转
class StatusBar extends StatelessWidget {
  final AppRunMode runMode;
  final bool flashOn;
  final ConnectionStatus connectionStatus;
  final double modelLoadProgress; // 0.0~1.0，-1表示不显示
  final bool simulationMode; // 模型未集成，显示警告
  // 模型下载状态（首次启动时）
  final bool isDownloading;
  final double downloadProgress; // 0.0~1.0
  final String? downloadCurrentFile;
  final String? downloadError;
  final VoidCallback onToggleFlash;
  final VoidCallback onSwitchCamera;
  final VoidCallback? onRetryDownload;
  final bool autoFocus;
  final VoidCallback onToggleAutoFocus;
  final VoidCallback? onOpenMarketplace;
  final VoidCallback? onOpenSettings;

  const StatusBar({
    super.key,
    required this.runMode,
    required this.flashOn,
    required this.connectionStatus,
    this.modelLoadProgress = -1,
    this.simulationMode = false,
    this.isDownloading = false,
    this.downloadProgress = 0,
    this.downloadCurrentFile,
    this.downloadError,
    required this.onToggleFlash,
    required this.onSwitchCamera,
    this.onRetryDownload,
    this.autoFocus = true,
    required this.onToggleAutoFocus,
    this.onOpenMarketplace,
    this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    final hasProgress = isDownloading ||
        (modelLoadProgress >= 0 && modelLoadProgress < 1.0);
    return Padding(
      padding: EdgeInsets.only(top: topPadding + 8, left: 12, right: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 模拟模式警告条（无任何本地模型）
          if (simulationMode && !isDownloading) _buildSimulationWarning(),
          // 下载错误条
          if (downloadError != null && !isDownloading) _buildDownloadError(),
          // 下载进度条
          if (isDownloading) _buildDownloadBanner(),
          // 主状态栏
          Row(
            children: [
              // 左侧：模式标签 + 连接状态
              _buildModeTag(),
              const SizedBox(width: 8),
              _buildConnectionIndicator(),
              // 中间：模型加载/下载进度
              if (hasProgress) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: isDownloading
                      ? _buildDownloadProgressBar()
                      : _buildProgressBar(),
                ),
              ] else
                const Spacer(),
              // 右侧：设置 + 形象市场 + 对焦模式 + 闪光灯 + 翻转摄像头
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (onOpenSettings != null) ...[
                    _buildCircleIcon(
                      icon: Icons.settings_outlined,
                      color: Colors.white,
                      onTap: onOpenSettings!,
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (onOpenMarketplace != null) ...[
                    _buildCircleIcon(
                      icon: Icons.store_mall_directory_outlined,
                      color: Colors.white,
                      onTap: onOpenMarketplace!,
                    ),
                    const SizedBox(width: 8),
                  ],
                  _buildCircleIcon(
                    icon: autoFocus ? Icons.center_focus_strong : Icons.center_focus_weak,
                    color: autoFocus ? const Color(0xff635bff) : Colors.white,
                    onTap: onToggleAutoFocus,
                  ),
                  const SizedBox(width: 8),
                  _buildCircleIcon(
                    icon: flashOn ? Icons.flash_on : Icons.flash_off,
                    color: flashOn ? Colors.amber : Colors.white54,
                    onTap: onToggleFlash,
                  ),
                  const SizedBox(width: 8),
                  _buildCircleIcon(
                    icon: Icons.flip_camera_ios,
                    color: Colors.white,
                    onTap: onSwitchCamera,
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildModeTag() {
    final isOffline = runMode == AppRunMode.offlineLocal;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isOffline
            ? Colors.green.withValues(alpha: 0.85)
            : Colors.blue.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isOffline ? Icons.memory : Icons.cloud,
            color: Colors.white,
            size: 14,
          ),
          const SizedBox(width: 4),
          Text(
            isOffline ? '离线本地' : '云端增强',
            style: const TextStyle(color: Colors.white, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionIndicator() {
    Color color;
    IconData icon;
    switch (connectionStatus) {
      case ConnectionStatus.connected:
        color = Colors.green;
        icon = Icons.wifi;
        break;
      case ConnectionStatus.reconnecting:
        color = Colors.orange;
        icon = Icons.sync;
        break;
      case ConnectionStatus.disconnected:
      case ConnectionStatus.error:
        color = Colors.grey;
        icon = Icons.wifi_off;
        break;
    }
    return Icon(icon, color: color, size: 16);
  }

  Widget _buildProgressBar() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: LinearProgressIndicator(
        value: modelLoadProgress,
        backgroundColor: Colors.white24,
        valueColor: const AlwaysStoppedAnimation(Color(0xff635bff)),
        minHeight: 4,
      ),
    );
  }

  Widget _buildDownloadProgressBar() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: LinearProgressIndicator(
        value: downloadProgress.clamp(0.0, 1.0),
        backgroundColor: Colors.white24,
        valueColor: const AlwaysStoppedAnimation(Color(0xff10b981)),
        minHeight: 4,
      ),
    );
  }

  Widget _buildDownloadBanner() {
    final pct = (downloadProgress * 100).toStringAsFixed(0);
    final file = downloadCurrentFile ?? '模型';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xff10b981).withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              valueColor: AlwaysStoppedAnimation(Colors.white),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '首次启动：正在下载 $file  $pct%',
              style: const TextStyle(color: Colors.white, fontSize: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSimulationWarning() {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.warning_amber_rounded, color: Colors.white, size: 14),
          SizedBox(width: 4),
          Text(
            '离线模式：模型未就绪',
            style: TextStyle(color: Colors.white, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadError() {
    return GestureDetector(
      onTap: onRetryDownload,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.white, size: 14),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                '模型下载失败：${downloadError ?? "未知错误"}（点击重试）',
                style: const TextStyle(color: Colors.white, fontSize: 11),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCircleIcon({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withValues(alpha: 0.35),
        ),
        child: Icon(icon, color: color, size: 18),
      ),
    );
  }
}
