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
/// 1. 渲染预览图（后端生成的 webp 预览图）
/// 2. GLB 3D模型（可拖动/缩放）
/// 3. 生成中加载动画（覆盖在最上层）
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

  /// Omni 交互模式（传给 Ai3DBall）
  final OmniInteractionMode omniMode;

  /// TTS音量（传给 Ai3DBall）
  final double ttsVolume;

  /// 硬件信息（传给 Ai3DBall）
  final HardwareInfo? hardwareInfo;

  const TripoModelViewer({
    super.key,
    this.modelUrl,
    this.previewImageUrl,
    this.isGenerating = false,
    this.progress,
    this.statusText,
    this.aiStatus = AiStatus.idle,
    this.runMode = AppRunMode.cloudAliyun,
    this.omniMode = OmniInteractionMode.manual,
    this.ttsVolume = 0.5,
    this.hardwareInfo,
  });

  @override
  State<TripoModelViewer> createState() => _TripoModelViewerState();
}

class _TripoModelViewerState extends State<TripoModelViewer> {
  bool _modelLoadFailed = false;

  @override
  void didUpdateWidget(TripoModelViewer old) {
    super.didUpdateWidget(old);
    if (old.modelUrl != widget.modelUrl && widget.modelUrl != null) {
      _modelLoadFailed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.modelUrl == null && !widget.isGenerating) {
      return Ai3DBall(
        status: widget.aiStatus,
        runMode: widget.runMode,
        omniMode: widget.omniMode,
        ttsVolume: widget.ttsVolume,
        hardwareInfo: widget.hardwareInfo,
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 200,
          height: 200,
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
                Positioned.fill(child: _buildPreviewImage(showError: true)),

              // 覆盖层：生成中 / 加载中
              if (widget.isGenerating ||
                  (_modelLoadFailed == false &&
                      widget.modelUrl != null &&
                      widget.isGenerating == false))
                _buildLoadingOverlay(),
            ],
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
        autoRotate: true,
        cameraControls: true,
        disableZoom: false,
        backgroundColor: Colors.transparent,
        loading: Loading.eager,
        poster: widget.previewImageUrl,
        shadowIntensity: 0.5,
        exposure: 0.9,
        interactionPrompt: InteractionPrompt.auto,
        onWebViewCreated: (controller) {
          debugPrint('[TripoModelViewer] WebView created');
        },
      ),
    );
  }

  Widget _buildLoadingOverlay() {
    final showSpinner = widget.isGenerating;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Colors.black.withValues(alpha: 0.5),
      ),
      child: Center(
        child: showSpinner
            ? Column(
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
              )
            : const SizedBox.shrink(),
      ),
    );
  }

  String _defaultStatusText() {
    if (widget.modelUrl != null) {
      return '拖动旋转模型 · 双指缩放';
    }
    if (widget.isGenerating) {
      return 'AI 正在生成 3D 模型…';
    }
    return widget.omniMode == OmniInteractionMode.vad
        ? '点击麦克风开始对话'
        : '按住麦克风提问';
  }
}
