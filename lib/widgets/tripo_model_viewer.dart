import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';
import '../models/enums.dart';
import '../models/hardware_info.dart';
import 'ai_3d_ball.dart';

/// Tripo 3D模型渲染组件
///
/// 使用 model_viewer_plus 渲染 GLB 模型（WebView + model-viewer.js）。
///
/// 显示层级（从底到顶）：
/// 1. 渲染预览图（后端生成的 webp 预览图，仅在无 GLB 时显示）
/// 2. GLB 3D模型（可拖动/缩放）
/// 3. 状态动画叠加层（thinking/speaking/idle 效果）
/// 4. 生成中加载动画（覆盖在最上层）
///
/// 无模型时回退显示原 Ai3DBall 动画球体。
class TripoModelViewer extends StatefulWidget {
  /// GLB 模型 URL（后端下载后的本地路径）
  final String? modelUrl;

  /// 渲染预览图 URL（后端生成的 webp）
  final String? previewImageUrl;

  /// 是否正在生成中
  final bool isGenerating;

  /// 生成进度提示（0.0~1.0）
  final double? progress;

  /// 提示文案
  final String? statusText;

  /// AI 球体状态（当未生成模型时传给 Ai3DBall）
  final AiStatus aiStatus;

  /// 运行模式（传给 Ai3DBall）
  final AppRunMode runMode;

  /// TTS音量（传给 Ai3DBall）
  final double ttsVolume;

  /// 硬件信息（传给 Ai3DBall）
  final HardwareInfo? hardwareInfo;

  /// Omni VAD 状态（传给 Ai3DBall 显示 Omni 专属状态）
  final OmniVadStatus omniVadStatus;

  /// 当前模型是否生成成功
  final bool tripoSucceeded;

  /// 当前模型是否已设为形象
  final bool isAvatar;

  /// 将当前模型设为 AI 形象
  final VoidCallback? onSetAsAvatar;

  /// 清除当前形象
  final VoidCallback? onClearAvatar;

  /// 模型自动旋转
  final bool autoRotate;

  /// 阴影强度（0.0~1.0）
  final double shadowIntensity;

  /// 曝光度（0.0~2.0）
  final double exposure;

  /// 优先显示3D球体而非模型
  final bool prefer3DBall;

  const TripoModelViewer({
    super.key,
    this.modelUrl,
    this.previewImageUrl,
    this.isGenerating = false,
    this.progress,
    this.statusText,
    this.aiStatus = AiStatus.idle,
    this.runMode = AppRunMode.cloudAliyun,
    this.ttsVolume = 0.5,
    this.hardwareInfo,
    this.omniVadStatus = OmniVadStatus.none,
    this.tripoSucceeded = false,
    this.isAvatar = false,
    this.onSetAsAvatar,
    this.onClearAvatar,
    this.autoRotate = true,
    this.shadowIntensity = 0.5,
    this.exposure = 0.9,
    this.prefer3DBall = false,
  });

  @override
  State<TripoModelViewer> createState() => _TripoModelViewerState();
}

class _TripoModelViewerState extends State<TripoModelViewer>
    with SingleTickerProviderStateMixin {
  bool _modelLoadFailed = false;
  late AnimationController _animCtrl;
  late Animation<double> _floatAnim;
  late Animation<double> _scaleAnim;
  late Animation<double> _rotateAnim;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(vsync: this);
    _floatAnim = const AlwaysStoppedAnimation(0.0);
    _scaleAnim = const AlwaysStoppedAnimation(1.0);
    _rotateAnim = const AlwaysStoppedAnimation(0.0);
    _applyStateAnimation();
  }

  void _applyStateAnimation() {
    _animCtrl.stop();
    _animCtrl.reset();
    final status = widget.aiStatus;

    switch (status) {
      case AiStatus.idle:
        _animCtrl.duration = const Duration(seconds: 4);
        _scaleAnim = Tween<double>(begin: 1.0, end: 1.04).animate(
          CurvedAnimation(parent: _animCtrl, curve: Curves.easeInOut),
        );
        _rotateAnim = const AlwaysStoppedAnimation(0.0);
        _floatAnim = Tween<double>(begin: -2, end: 2).animate(
          CurvedAnimation(parent: _animCtrl, curve: Curves.easeInOut),
        );
        _animCtrl.repeat(reverse: true);
        break;
      case AiStatus.listening:
        _animCtrl.duration = const Duration(milliseconds: 800);
        _scaleAnim = Tween<double>(begin: 1.0, end: 1.08).animate(
          CurvedAnimation(parent: _animCtrl, curve: Curves.easeInOut),
        );
        _rotateAnim = const AlwaysStoppedAnimation(0.0);
        _floatAnim = const AlwaysStoppedAnimation(0.0);
        _animCtrl.repeat(reverse: true);
        break;
      case AiStatus.thinking:
        _animCtrl.duration = const Duration(seconds: 5);
        _scaleAnim = const AlwaysStoppedAnimation(1.0);
        _rotateAnim = Tween<double>(begin: 0, end: 360).animate(
          CurvedAnimation(parent: _animCtrl, curve: Curves.linear),
        );
        _floatAnim = Tween<double>(begin: -5, end: 5).animate(
          CurvedAnimation(parent: _animCtrl, curve: Curves.easeInOut),
        );
        _animCtrl.repeat();
        break;
      case AiStatus.speaking:
        _animCtrl.duration = const Duration(milliseconds: 400);
        _scaleAnim = Tween<double>(begin: 0.95, end: 1.15).animate(
          CurvedAnimation(parent: _animCtrl, curve: Curves.ease),
        );
        _rotateAnim = const AlwaysStoppedAnimation(0.0);
        _floatAnim = const AlwaysStoppedAnimation(0.0);
        _animCtrl.repeat(reverse: true);
        break;
    }
  }

  @override
  void didUpdateWidget(TripoModelViewer old) {
    super.didUpdateWidget(old);
    if (old.modelUrl != widget.modelUrl && widget.modelUrl != null) {
      _modelLoadFailed = false;
    }
    if (old.aiStatus != widget.aiStatus ||
        old.omniVadStatus != widget.omniVadStatus) {
      _applyStateAnimation();
    }
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if ((widget.modelUrl == null && !widget.isGenerating) || widget.prefer3DBall) {
      return Ai3DBall(
        status: widget.aiStatus,
        runMode: widget.runMode,
        ttsVolume: widget.ttsVolume,
        hardwareInfo: widget.hardwareInfo,
        omniVadStatus: widget.omniVadStatus,
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 200,
          height: 200,
          child: AnimatedBuilder(
            animation: _animCtrl,
            builder: (ctx, child) {
              final floatY = _floatAnim.value;
              final scale = widget.aiStatus == AiStatus.speaking
                  ? 0.95 + widget.ttsVolume * 0.20
                  : _scaleAnim.value;
              final rotateDeg = _rotateAnim.value;

              return Transform.translate(
                offset: Offset(0, floatY),
                child: Transform.scale(
                  scale: scale,
                  child: Transform.rotate(
                    angle: rotateDeg * 3.14159265359 / 180,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // 底层：渲染预览图（等待模型加载时显示）
                        if (widget.previewImageUrl != null)
                          Positioned.fill(child: _buildPreviewImage()),

                        // 中层：GLB 3D模型
                        if (widget.modelUrl != null && !_modelLoadFailed)
                          Positioned.fill(child: _buildModelViewer()),

                        // 加载失败：显示预览图 + 错误提示
                        if (_modelLoadFailed && widget.previewImageUrl != null)
                          Positioned.fill(
                              child: _buildPreviewImage(showError: true)),

                        // 状态光晕层（thinking / speaking / idle 动画效果）
                        if (!_modelLoadFailed && widget.modelUrl != null)
                          _buildStateGlowLayer(),

                        // 覆盖层：生成中显示加载动画
                        if (widget.isGenerating)
                          Positioned.fill(child: _buildLoadingOverlay()),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),

        const SizedBox(height: 12),

        Text(
          widget.statusText ?? _defaultStatusText(),
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 13,
            fontWeight: FontWeight.w400,
            shadows: [Shadow(blurRadius: 6, color: Colors.black54)],
          ),
        ),

        // 形象操作按钮（模型生成成功后显示）
        if (widget.tripoSucceeded || widget.isAvatar) ...[
          const SizedBox(height: 8),
          _buildAvatarActionButton(),
        ],
      ],
    );
  }

  Widget _buildPreviewImage({bool showError = false}) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.network(
            widget.previewImageUrl!,
            fit: BoxFit.cover,
            width: 200,
            height: 200,
            errorBuilder: (_, __, ___) => Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0x994D6AFF), Color(0x996B4EFF)],
                ),
              ),
            ),
          ),
        ),
        if (showError)
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: Colors.black54,
            ),
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.broken_image, color: Colors.white70, size: 32),
                  SizedBox(height: 8),
                  Text(
                    '3D模型加载失败\n可拖动查看预览图',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildModelViewer() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ModelViewer(
        src: widget.modelUrl!,
        alt: 'Tripo 3D Model',
        autoRotate: widget.autoRotate,
        cameraControls: true,
        disableZoom: false,
        backgroundColor: Colors.transparent,
        loading: Loading.eager,
        shadowIntensity: widget.shadowIntensity,
        exposure: widget.exposure,
        interactionPrompt: InteractionPrompt.auto,
        onWebViewCreated: (controller) {
          debugPrint('[TripoModelViewer] WebView created');
        },
      ),
    );
  }

  /// 状态光晕叠加层：thinking 显示紫色光晕，speaking 显示金色光晕，idle 显示微弱白色光晕
  Widget _buildStateGlowLayer() {
    Color glowColor;
    double blurRadius;
    double spreadRadius;

    switch (widget.aiStatus) {
      case AiStatus.thinking:
        glowColor = const Color(0xff635bff);
        blurRadius = 35;
        spreadRadius = 12;
        break;
      case AiStatus.speaking:
        glowColor = const Color(0xffffc94d);
        blurRadius = 30;
        spreadRadius = 10;
        break;
      case AiStatus.listening:
        glowColor = const Color(0xff28b987);
        blurRadius = 25;
        spreadRadius = 8;
        break;
      case AiStatus.idle:
        glowColor = Colors.white.withValues(alpha: 0.15);
        blurRadius = 15;
        spreadRadius = 4;
        break;
    }

    // 思考状态增加旋转粒子效果
    final showParticles = widget.aiStatus == AiStatus.thinking;
    final showRipple = widget.aiStatus == AiStatus.speaking;

    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          children: [
            Center(
              child: Container(
                width: 160,
                height: 160,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: glowColor.withValues(alpha: 0.5),
                      blurRadius: blurRadius,
                      spreadRadius: spreadRadius,
                    ),
                  ],
                ),
              ),
            ),
            if (showParticles) ..._buildThinkingParticles(),
            if (showRipple) ..._buildSpeakingRipples(),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildThinkingParticles() {
    final t = _animCtrl.value;
    return List.generate(6, (i) {
      final angle = (i / 6) * 2 * 3.14159265359 + t * 2 * 3.14159265359;
      final radius = 60 + 20 * math.sin(t * 2 * 3.14159265359 + i);
      final dx = math.cos(angle) * radius;
      final dy = math.sin(angle) * radius;
      return Center(
        child: Transform.translate(
          offset: Offset(dx, dy),
          child: Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xff635bff)
                  .withValues(alpha: (0.6 - (i % 3) * 0.15)),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xff635bff).withValues(alpha: 0.5),
                  blurRadius: 6,
                  spreadRadius: 2,
                ),
              ],
            ),
          ),
        ),
      );
    });
  }

  List<Widget> _buildSpeakingRipples() {
    return List.generate(2, (i) {
      final progress = (_animCtrl.value + i * 0.5) % 1.0;
      final size = 120.0 + progress * 50;
      final opacity = (1.0 - progress) * 0.4;
      return Center(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: const Color(0xffffc94d).withValues(alpha: opacity),
              width: (2.5 - progress * 2).clamp(0.5, 2.5),
            ),
          ),
        ),
      );
    });
  }

  Widget _buildLoadingOverlay() {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Colors.black.withValues(alpha: 0.5),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(
                color: Color(0xff635bff),
                strokeWidth: 3,
              ),
            ),
            const SizedBox(height: 12),
            if (widget.progress != null) ...[
              SizedBox(
                width: 120,
                child: LinearProgressIndicator(
                  value: widget.progress,
                  backgroundColor: Colors.white24,
                  valueColor: const AlwaysStoppedAnimation(Color(0xff635bff)),
                ),
              ),
              const SizedBox(height: 8),
            ],
            Text(
              widget.statusText ?? 'AI 正在生成 3D 模型…',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatarActionButton() {
    final isAvatar = widget.isAvatar;
    return GestureDetector(
      onTap: () {
        if (isAvatar) {
          widget.onClearAvatar?.call();
        } else {
          widget.onSetAsAvatar?.call();
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isAvatar
              ? Colors.red.withValues(alpha: 0.2)
              : const Color(0xff635bff).withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isAvatar
                ? Colors.red.withValues(alpha: 0.5)
                : const Color(0xff635bff).withValues(alpha: 0.5),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isAvatar ? Icons.person_off_outlined : Icons.person_pin_circle_outlined,
              color: isAvatar ? Colors.red.shade300 : const Color(0xff635bff),
              size: 16,
            ),
            const SizedBox(width: 4),
            Text(
              isAvatar ? '移除形象' : '设为 AI 形象',
              style: TextStyle(
                color: isAvatar ? Colors.red.shade300 : const Color(0xff635bff),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _defaultStatusText() {
    // Omni VAD 状态优先文案
    switch (widget.omniVadStatus) {
      case OmniVadStatus.userSpeaking:
        return '你正在说话…';
      case OmniVadStatus.userDone:
        return '已收到，正在思考…';
      case OmniVadStatus.aiThinking:
        return 'AI 正在结合画面思考…';
      case OmniVadStatus.none:
        break;
    }
    if (widget.modelUrl != null) {
      return '拖动旋转模型 · 双指缩放';
    }
    if (widget.isGenerating) {
      return 'AI 正在生成 3D 模型…';
    }
    return '按住麦克风提问';
  }
}
