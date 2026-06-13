import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import '../models/chat_message.dart';
import '../models/enums.dart';

/// 底部对话文字面板
/// 支持上滑展开/下滑收起，半透明磨砂玻璃背景
class ChatPanel extends StatefulWidget {
  final List<ChatMessage> messages;
  final bool expanded;
  final AppRunMode runMode;
  final VoidCallback onToggle;

  const ChatPanel({
    super.key,
    required this.messages,
    required this.expanded,
    required this.runMode,
    required this.onToggle,
  });

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel>
    with SingleTickerProviderStateMixin {
  late AnimationController _slideCtrl;
  late Animation<double> _slideAnim;
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _slideAnim = CurvedAnimation(
      parent: _slideCtrl,
      curve: Curves.easeOutCubic,
    );
    if (widget.expanded) _slideCtrl.forward();
  }

  @override
  void didUpdateWidget(covariant ChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded != oldWidget.expanded) {
      if (widget.expanded) {
        _slideCtrl.forward();
      } else {
        _slideCtrl.reverse();
      }
    }
    // 新消息时滚动到底部
    if (widget.messages.length != oldWidget.messages.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollCtrl.hasClients) {
          _scrollCtrl.animateTo(
            _scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _slideCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final panelMaxHeight = screenHeight * 0.45; // 展开时最大高度

    return ListenableBuilder(
      listenable: _slideAnim,
      builder: (ctx, _) {
        return GestureDetector(
          onVerticalDragUpdate: (details) {
            if (details.delta.dy < -3 && !widget.expanded) {
              widget.onToggle();
            } else if (details.delta.dy > 3 && widget.expanded) {
              widget.onToggle();
            }
          },
          child: ClipRRect(
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(16)),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                height: widget.expanded ? panelMaxHeight : 52,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(16)),
                  border: Border(
                    top: BorderSide(
                      color: Colors.white.withValues(alpha: 0.1),
                      width: 0.5,
                    ),
                  ),
                ),
                child: Column(
                  children: [
                    // 拖拽条
                    _buildDragHandle(),
                    // 对话列表（展开时显示）
                    if (widget.expanded)
                      Expanded(
                        child: widget.messages.isEmpty
                            ? _buildEmptyHint()
                            : ListView.builder(
                                controller: _scrollCtrl,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 12),
                                itemCount: widget.messages.length,
                                itemBuilder: (ctx, i) =>
                                    _buildMessageBubble(widget.messages[i]),
                              ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 顶部拖拽条
  Widget _buildDragHandle() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  /// 空状态提示
  Widget _buildEmptyHint() {
    return Center(
      child: Text(
        '上滑展开对话面板\n按住麦克风开始提问',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.4),
          fontSize: 13,
        ),
      ),
    );
  }

  /// 单条消息气泡
  Widget _buildMessageBubble(ChatMessage msg) {
    final isUser = msg.isUser;
    final accentColor = widget.runMode == AppRunMode.offlineLocal
        ? const Color(0xff28b987)
        : const Color(0xff1976d2);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.start : MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // 用户消息：左侧小缩略图
          if (isUser && msg.thumbnailBytes != null) ...[
            _buildThumbnail(msg.thumbnailBytes!),
            const SizedBox(width: 6),
          ],
          // 气泡
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isUser
                    ? Colors.white.withValues(alpha: 0.15)
                    : accentColor.withValues(alpha: 0.25),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(14),
                  topRight: const Radius.circular(14),
                  bottomLeft: Radius.circular(isUser ? 4 : 14),
                  bottomRight: Radius.circular(isUser ? 14 : 4),
                ),
                border: Border.all(
                  color: isUser
                      ? Colors.white.withValues(alpha: 0.08)
                      : accentColor.withValues(alpha: 0.3),
                  width: 0.5,
                ),
              ),
              child: Text(
                msg.text,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ),
          ),
          // AI消息：右侧小缩略图占位
          if (!isUser) ...[
            const SizedBox(width: 6),
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [accentColor, accentColor.withValues(alpha: 0.6)],
                ),
              ),
              child: const Icon(Icons.auto_awesome, size: 14, color: Colors.white),
            ),
          ],
        ],
      ),
    );
  }

  /// 摄像头缩略图
  Widget _buildThumbnail(Uint8List bytes) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.memory(
        bytes,
        width: 36,
        height: 36,
        fit: BoxFit.cover,
      ),
    );
  }
}
