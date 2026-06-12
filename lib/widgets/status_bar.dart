import 'package:flutter/material.dart';
import '../models/enums.dart';

/// 顶部状态栏组件
/// 显示：模式标签、连接状态、闪光灯开关、摄像头翻转
class StatusBar extends StatelessWidget {
  final AppRunMode runMode;
  final bool flashOn;
  final ConnectionStatus connectionStatus;
  final double modelLoadProgress; // 0.0~1.0，-1表示不显示
  final bool simulationMode; // 模型未集成，显示警告
  final VoidCallback onToggleFlash;
  final VoidCallback onSwitchCamera;

  const StatusBar({
    super.key,
    required this.runMode,
    required this.flashOn,
    required this.connectionStatus,
    this.modelLoadProgress = -1,
    this.simulationMode = false,
    required this.onToggleFlash,
    required this.onSwitchCamera,
  });

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    return Padding(
      padding: EdgeInsets.only(top: topPadding + 8, left: 12, right: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 模拟模式警告条
          if (simulationMode) _buildSimulationWarning(),
          // 主状态栏
          Row(
            children: [
              // 左侧：模式标签 + 连接状态
              _buildModeTag(),
              const SizedBox(width: 8),
              _buildConnectionIndicator(),
              // 中间：模型加载进度
              if (modelLoadProgress >= 0 && modelLoadProgress < 1.0) ...[
                const SizedBox(width: 12),
                Expanded(child: _buildProgressBar()),
              ] else
                const Spacer(),
              // 右侧：闪光灯 + 翻转摄像头
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
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
            '离线模式：模型未集成，仅模拟对话',
            style: TextStyle(color: Colors.white, fontSize: 11),
          ),
        ],
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
