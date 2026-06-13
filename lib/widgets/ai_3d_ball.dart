import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/enums.dart';
import '../models/hardware_info.dart';

/// 3D球体封装组件
/// 尝试加载 flutter_3d_obj，失败或条件降级时自动回退为模拟3D效果
class Ai3DBall extends StatefulWidget {
  final AiStatus status;
  final AppRunMode runMode;
  final double ttsVolume;
  final HardwareInfo? hardwareInfo;

  const Ai3DBall({
    super.key,
    required this.status,
    required this.runMode,
    this.ttsVolume = 0.5,
    this.hardwareInfo,
  });

  @override
  State<Ai3DBall> createState() => _Ai3DBallState();
}

class _Ai3DBallState extends State<Ai3DBall> {
  bool _use3D = true;
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check3DCapability());
  }

  Future<void> _check3DCapability() async {
    bool can3D = true;

    if (Platform.isIOS) {
      final brightness = MediaQuery.platformBrightnessOf(context);
      if (brightness == Brightness.dark) can3D = false;
    }

    final hw = widget.hardwareInfo;
    if (hw != null && !hw.supports3D) can3D = false;

    if (mounted) {
      setState(() {
        _use3D = can3D;
        _checked = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked) return const SizedBox(width: 160, height: 190);
    return _Enhanced3DBall(
      status: widget.status,
      ttsVolume: widget.ttsVolume,
      use3D: _use3D,
    );
  }
}

/// 增强3D球体（2D降级+模拟3D效果的最终渲染器）
class _Enhanced3DBall extends StatefulWidget {
  final AiStatus status;
  final double ttsVolume;
  final bool use3D;

  const _Enhanced3DBall({
    required this.status,
    required this.ttsVolume,
    required this.use3D,
  });

  @override
  State<_Enhanced3DBall> createState() => _Enhanced3DBallState();
}

class _Enhanced3DBallState extends State<_Enhanced3DBall>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scaleAnim;
  late Animation<double> _rotateAnim;
  late Animation<double> _floatAnim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this);
    _scaleAnim = const AlwaysStoppedAnimation(1.0);
    _rotateAnim = const AlwaysStoppedAnimation(0.0);
    _floatAnim = const AlwaysStoppedAnimation(0.0);
    _applyStatus();
  }

  void _applyStatus() {
    _ctrl.stop();
    _ctrl.reset();
    switch (widget.status) {
      case AiStatus.idle:
        _ctrl.duration = const Duration(seconds: 3);
        _scaleAnim = Tween<double>(begin: 1.0, end: 1.05).animate(
          CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
        );
        _rotateAnim = const AlwaysStoppedAnimation(0.0);
        _ctrl.repeat(reverse: true);
        break;
      case AiStatus.listening:
        _ctrl.duration = const Duration(milliseconds: 800);
        _scaleAnim = Tween<double>(begin: 1.0, end: 1.1).animate(
          CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
        );
        _rotateAnim = const AlwaysStoppedAnimation(0.0);
        _ctrl.repeat(reverse: true);
        break;
      case AiStatus.thinking:
        _ctrl.duration = const Duration(seconds: 6);
        _scaleAnim = const AlwaysStoppedAnimation(1.0);
        _rotateAnim = Tween<double>(begin: 0, end: 360).animate(
          CurvedAnimation(parent: _ctrl, curve: Curves.linear),
        );
        _floatAnim = Tween<double>(begin: -6, end: 6).animate(
          CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
        );
        _ctrl.repeat();
        break;
      case AiStatus.speaking:
        _ctrl.duration = const Duration(milliseconds: 400);
        _scaleAnim = Tween<double>(begin: 0.95, end: 1.2).animate(
          CurvedAnimation(parent: _ctrl, curve: Curves.ease),
        );
        _rotateAnim = const AlwaysStoppedAnimation(0.0);
        _ctrl.repeat(reverse: true);
        break;
    }
  }

  @override
  void didUpdateWidget(_Enhanced3DBall old) {
    super.didUpdateWidget(old);
    if (old.status != widget.status) _applyStatus();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  List<Color> _getColors() {
    switch (widget.status) {
      case AiStatus.idle:
        return [const Color(0xfff5f5f5), const Color(0xffd8d8d8)];
      case AiStatus.listening:
        return [const Color(0xff86f0c6), const Color(0xff28b987)];
      case AiStatus.thinking:
        return [const Color(0xffb4b0ff), const Color(0xff635bff)];
      case AiStatus.speaking:
        return [const Color(0xfffff3b4), const Color(0xffe6b800)];
    }
  }

  String _getText() {
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
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (ctx, _) {
        double scale = _scaleAnim.value;
        if (widget.status == AiStatus.speaking) {
          scale = 0.95 + widget.ttsVolume * 0.25;
        }
        final rotate = _rotateAnim.value;
        final float = _floatAnim.value;

        Widget ball = SizedBox(
          width: 160,
          height: 160,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 波纹（listening状态）
              if (widget.status == AiStatus.listening) ...[
                const _Ripple(index: 0, color: Color(0xff86f0c6)),
                const _Ripple(index: 1, color: Color(0xff86f0c6)),
                const _Ripple(index: 2, color: Color(0xff86f0c6)),
              ],
              // 光晕（thinking状态）
              if (widget.status == AiStatus.thinking)
                Container(
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xff635bff).withValues(alpha: 0.4),
                        blurRadius: 30,
                        spreadRadius: 10,
                      ),
                    ],
                  ),
                ),
              // 核心球体
              Transform.scale(
                scale: scale,
                child: Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()
                    ..setEntry(3, 2, 0.001)
                    ..rotateZ(rotate * math.pi / 180),
                  child: Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(colors: _getColors()),
                      boxShadow: [
                        BoxShadow(
                          blurRadius: 20,
                          color: Colors.black.withValues(alpha: 0.25),
                          offset: const Offset(4, 4),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );

        // thinking状态浮动
        if (widget.status == AiStatus.thinking) {
          ball = Transform.translate(
            offset: Offset(0, float),
            child: ball,
          );
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ball,
            const SizedBox(height: 12),
            Text(
              _getText(),
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.w400,
                shadows: [Shadow(blurRadius: 6, color: Colors.black54)],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 扩散波纹
class _Ripple extends StatefulWidget {
  final int index;
  final Color color;
  const _Ripple({required this.index, required this.color});

  @override
  State<_Ripple> createState() => _RippleState();
}

class _RippleState extends State<_Ripple> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (ctx, _) {
        final progress = (_ctrl.value + widget.index * 0.33) % 1.0;
        final size = 120.0 + progress * 50;
        final opacity = (1.0 - progress).clamp(0.0, 0.5);
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: widget.color.withValues(alpha: opacity),
              width: (2.5 - progress * 2).clamp(0.5, 2.5),
            ),
          ),
        );
      },
    );
  }
}
