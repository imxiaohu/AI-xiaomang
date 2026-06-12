import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/enums.dart';

/// 底部交互操作栏
/// 包含：模式切换按钮、长按录音主按钮、对话面板展开按钮
class BottomActionBar extends StatelessWidget {
  final AppRunMode runMode;
  final AiStatus aiStatus;
  final bool chatPanelExpanded;
  final double recordingSeconds; // 当前录音秒数
  final VoidCallback onToggleRunMode;
  final VoidCallback onToggleChatPanel;
  final VoidCallback onLongPressStart;
  final VoidCallback onLongPressEnd;

  const BottomActionBar({
    super.key,
    required this.runMode,
    required this.aiStatus,
    required this.chatPanelExpanded,
    this.recordingSeconds = 0,
    required this.onToggleRunMode,
    required this.onToggleChatPanel,
    required this.onLongPressStart,
    required this.onLongPressEnd,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 录音时长文字（聆听状态显示）
          if (aiStatus == AiStatus.listening)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '${recordingSeconds.toStringAsFixed(1)}s',
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  fontWeight: FontWeight.w300,
                ),
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // 左侧：模式切换小按钮（idle状态可点击）
              _buildSmallCircleButton(
                icon: runMode == AppRunMode.offlineLocal
                    ? Icons.memory
                    : Icons.cloud,
                onTap: aiStatus == AiStatus.idle ? onToggleRunMode : null,
                tooltip: runMode == AppRunMode.offlineLocal ? '离线模式' : '云端模式',
              ),
              const SizedBox(width: 32),
              // 中心：长按录音大圆按钮
              _buildMicButton(),
              const SizedBox(width: 32),
              // 右侧：对话面板展开按钮
              _buildSmallCircleButton(
                icon: chatPanelExpanded
                    ? Icons.keyboard_arrow_down
                    : Icons.chat_bubble_outline,
                onTap: onToggleChatPanel,
                tooltip: chatPanelExpanded ? '收起对话' : '展开对话',
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 中心长按录音按钮 (直径80dp)
  Widget _buildMicButton() {
    final isListening = aiStatus == AiStatus.listening;
    final isDisabled = aiStatus == AiStatus.thinking ||
        aiStatus == AiStatus.speaking;

    // 渐变配色
    Gradient gradient;
    if (isListening) {
      gradient = runMode == AppRunMode.offlineLocal
          ? const RadialGradient(
              colors: [Color(0xff4cd099), Color(0xff209c6c)])
          : const RadialGradient(
              colors: [Color(0xff63a8ff), Color(0xff1976d2)]);
    } else {
      gradient = const RadialGradient(
          colors: [Color(0xff555555), Color(0xff2d2d2d)]);
    }

    return GestureDetector(
      onLongPressStart: isDisabled
          ? null
          : (_) {
              HapticFeedback.mediumImpact();
              onLongPressStart();
            },
      onLongPressEnd: isDisabled
          ? null
          : (_) {
              onLongPressEnd();
            },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 80,
        height: 80,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: gradient,
          boxShadow: [
            if (isListening)
              BoxShadow(
                color: (runMode == AppRunMode.offlineLocal
                        ? const Color(0xff28b987)
                        : const Color(0xff1976d2))
                    .withValues(alpha: 0.5),
                blurRadius: 20,
                spreadRadius: 4,
              ),
            const BoxShadow(blurRadius: 15, color: Colors.black38),
          ],
        ),
        child: Icon(
          isListening ? Icons.mic : Icons.mic_none,
          color: isDisabled ? Colors.white30 : Colors.white,
          size: 32,
        ),
      ),
    );
  }

  /// 辅助小圆按钮 (直径40dp)
  Widget _buildSmallCircleButton({
    required IconData icon,
    VoidCallback? onTap,
    String? tooltip,
  }) {
    return Tooltip(
      message: tooltip ?? '',
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedOpacity(
          opacity: onTap == null ? 0.3 : 1.0,
          duration: const Duration(milliseconds: 200),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withValues(alpha: 0.35),
            ),
            child: Icon(icon, color: Colors.white, size: 20),
          ),
        ),
      ),
    );
  }
}
