import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/enums.dart';

/// AI状态球形动效组件
/// 4种状态：idle(空闲) / listening(聆听) / thinking(思考) / speaking(播报)
class AiStatusBall extends StatefulWidget {
  final AiStatus status;
  final AppRunMode runMode;
  final double ttsVolume; // 0.0~1.0，speaking状态跟随音量缩放

  const AiStatusBall({
    super.key,
    required this.status,
    required this.runMode,
    this.ttsVolume = 0.5,
  });

  @override
  State<AiStatusBall> createState() => _AiStatusBallState();
}

class _AiStatusBallState extends State<AiStatusBall>
    with TickerProviderStateMixin {
  // 主呼吸/旋转动画
  late AnimationController _mainCtrl;
  late Animation<double> _scaleAnim;
  late Animation<double> _rotateAnim;

  // 聆听波纹动画
  late AnimationController _rippleCtrl;

  // 思考浮动动画
  late AnimationController _floatCtrl;
  late Animation<double> _floatAnim;

  // 光晕闪烁动画
  late AnimationController _glowCtrl;
  late Animation<double> _glowAnim;

  @override
  void initState() {
    super.initState();

    _mainCtrl = AnimationController(vsync: this);
    _rippleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
    _floatCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    _floatAnim = Tween<double>(begin: -6, end: 6).animate(
      CurvedAnimation(parent: _floatCtrl, curve: Curves.easeInOut),
    );
    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _glowAnim = Tween<double>(begin: 0.3, end: 0.8).animate(
      CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOut),
    );

    _applyStatusAnimation();
  }

  void _applyStatusAnimation() {
    // 停止所有动画
    _mainCtrl.stop();
    _mainCtrl.reset();
    _floatCtrl.stop();
    _floatCtrl.reset();
    _glowCtrl.stop();
    _glowCtrl.reset();

    switch (widget.status) {
      case AiStatus.idle:
        _mainCtrl.duration = const Duration(seconds: 3);
        _scaleAnim = Tween<double>(begin: 1.0, end: 1.05).animate(
          CurvedAnimation(parent: _mainCtrl, curve: Curves.easeInOut),
        );
        _rotateAnim = const AlwaysStoppedAnimation(0);
        _mainCtrl.repeat(reverse: true);
        break;

      case AiStatus.listening:
        _mainCtrl.duration = const Duration(milliseconds: 800);
        _scaleAnim = Tween<double>(begin: 1.0, end: 1.1).animate(
          CurvedAnimation(parent: _mainCtrl, curve: Curves.easeInOut),
        );
        _rotateAnim = const AlwaysStoppedAnimation(0);
        _mainCtrl.repeat(reverse: true);
        break;

      case AiStatus.thinking:
        _mainCtrl.duration = const Duration(seconds: 6);
        _scaleAnim = const AlwaysStoppedAnimation(1.0);
        _rotateAnim = Tween<double>(begin: 0, end: 360).animate(
          CurvedAnimation(parent: _mainCtrl, curve: Curves.linear),
        );
        _mainCtrl.repeat();
        _floatCtrl.repeat(reverse: true);
        _glowCtrl.repeat(reverse: true);
        break;

      case AiStatus.speaking:
        _mainCtrl.duration = const Duration(milliseconds: 400);
        _scaleAnim = Tween<double>(begin: 0.95, end: 1.2).animate(
          CurvedAnimation(parent: _mainCtrl, curve: Curves.ease),
        );
        _rotateAnim = const AlwaysStoppedAnimation(0);
        _mainCtrl.repeat(reverse: true);
        break;
    }
  }

  @override
  void didUpdateWidget(covariant AiStatusBall oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status) {
      _applyStatusAnimation();
    }
  }

  @override
  void dispose() {
    _mainCtrl.dispose();
    _rippleCtrl.dispose();
    _floatCtrl.dispose();
    _glowCtrl.dispose();
    super.dispose();
  }

  // --- 球体渐变配色 ---
  RadialGradient _getBallGradient() {
    switch (widget.status) {
      case AiStatus.idle:
        return const RadialGradient(
          colors: [Color(0xfff5f5f5), Color(0xffd8d8d8)],
        );
      case AiStatus.listening:
        return const RadialGradient(
          colors: [Color(0xff86f0c6), Color(0xff28b987)],
        );
      case AiStatus.thinking:
        return const RadialGradient(
          colors: [Color(0xffb4b0ff), Color(0xff635bff)],
        );
      case AiStatus.speaking:
        return const RadialGradient(
          colors: [Color(0xfffff3b4), Color(0xffe6b800)],
        );
    }
  }

  // --- 状态提示文案 ---
  String _getStatusText() {
    switch (widget.status) {
      case AiStatus.idle:
        return '按住麦克风提问';
      case AiStatus.listening:
        return '正在聆听你的声音…';
      case AiStatus.thinking:
        return 'AI正在结合画面思考答案…';
      case AiStatus.speaking:
        return 'AI正在回答';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 球体主体
        SizedBox(
          width: 160,
          height: 160,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 聆听状态：扩散波纹
              if (widget.status == AiStatus.listening) ...[
                _buildRipple(0),
                _buildRipple(1),
                _buildRipple(2),
              ],
              // 思考状态：光晕
              if (widget.status == AiStatus.thinking)
                AnimatedBuilder(
                  animation: _glowAnim,
                  builder: (ctx, _) {
                    return Container(
                      width: 140,
                      height: 140,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xff635bff)
                                .withValues(alpha: _glowAnim.value * 0.4),
                            blurRadius: 30,
                            spreadRadius: 10,
                          ),
                        ],
                      ),
                    );
                  },
                ),
              // 核心球体
              AnimatedBuilder(
                animation: Listenable.merge([_scaleAnim, _rotateAnim]),
                builder: (ctx, child) {
                  // speaking状态：根据TTS音量动态调整缩放
                  double scale = _scaleAnim.value;
                  if (widget.status == AiStatus.speaking) {
                    scale = 0.95 + widget.ttsVolume * 0.25;
                  }
                  return Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.diagonal3Values(scale, scale, 1.0)
                      ..rotateZ(_rotateAnim.value * math.pi / 180),
                    child: widget.status == AiStatus.thinking
                        ? AnimatedBuilder(
                            animation: _floatAnim,
                            builder: (ctx, child) {
                              return Transform.translate(
                                offset: Offset(0, _floatAnim.value),
                                child: child,
                              );
                            },
                            child: _buildBall(),
                          )
                        : _buildBall(),
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // 状态文案
        Text(
          _getStatusText(),
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 13,
            fontWeight: FontWeight.w400,
            shadows: [
              Shadow(blurRadius: 6, color: Colors.black54),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBall() {
    return Container(
      width: 120,
      height: 120,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: _getBallGradient(),
        boxShadow: [
          BoxShadow(
            blurRadius: 20,
            color: Colors.black.withValues(alpha: 0.25),
          ),
        ],
      ),
    );
  }

  /// 构建扩散波纹圈
  Widget _buildRipple(int index) {
    return AnimatedBuilder(
      animation: _rippleCtrl,
      builder: (ctx, _) {
        // 每圈延迟偏移
        final progress = (_rippleCtrl.value + index * 0.33) % 1.0;
        final size = 120.0 + progress * 50;
        final opacity = (1.0 - progress).clamp(0.0, 0.5);
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: const Color(0xff86f0c6).withValues(alpha: opacity),
              width: 2.5 - progress * 2,
            ),
          ),
        );
      },
    );
  }
}
