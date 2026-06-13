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
/// 1. GLB 3D模型（可拖动/缩放）
/// 2. 生成中加载动画（覆盖在最上层）
///
/// 无模型时回退显示原 Ai3DBall 动画球体。
class TripoModelViewer extends StatefulWidget {
  /// GLB 模型 URL（带 scheme 的绝对地址，model_viewer_plus iOS 端不接受相对路径）
  final String? modelUrl;

  /// 渲染预览图 URL（已不再用于展示，保留字段以兼容调用方）
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

  /// 取消回调（生成中显示右上角 ✕ 按钮）
  final VoidCallback? onCancel;

  /// 是否可以取消（false 时不显示 ✕ 按钮）
  final bool canCancel;

  /// 保存 GLB 回调（成功后显示下载按钮）
  final Future<String?> Function()? onDownloadGlb;

  /// 下载中状态（外部控制，禁用按钮）
  final bool isDownloading;

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
    this.onCancel,
    this.canCancel = false,
    this.onDownloadGlb,
    this.isDownloading = false,
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
              if (widget.modelUrl != null && !_modelLoadFailed)
                Positioned.fill(child: _buildModelViewer()),

              if (_modelLoadFailed)
                Positioned.fill(child: _buildModelLoadFailed()),

              if (widget.isGenerating) _buildLoadingOverlay(),

              if (widget.isGenerating &&
                  widget.canCancel &&
                  widget.onCancel != null)
                Positioned(
                  top: 4,
                  right: 4,
                  child: _buildCancelButton(),
                ),

              if (!widget.isGenerating &&
                  widget.modelUrl != null &&
                  widget.onDownloadGlb != null)
                Positioned(
                  bottom: 4,
                  right: 4,
                  child: _buildDownloadButton(),
                ),
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

  Widget _buildModelLoadFailed() {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0x994D6AFF), Color(0x996B4EFF)],
        ),
      ),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image, color: Colors.white70, size: 32),
            SizedBox(height: 8),
            Text(
              '3D模型加载失败\n请稍后重试',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModelViewer() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      // 修 bug：model_viewer_plus 内部 WebView 在 src 变更时不会自动 reload，
      // 表现：选用市场新模型后，主页 3D 区域还是显示旧模型；冷启动后正常。
      // 根因：ModelViewer subtree 在 widget rebuild 时 key 不变，Flutter 不销毁 WebView，
      // <model-viewer> 元素的 src 属性虽然更新了，但 model-viewer.js 不重置内部 GLB 加载。
      // 修复：用 ValueKey 绑定 modelUrl，URL 变时强制 Flutter 销毁旧 WebView、建新的。
      child: ModelViewer(
        key: ValueKey('model_viewer_${widget.modelUrl}'),
        // 修 bug #1：必须是带 scheme 的绝对 URL
        src: widget.modelUrl!,
        alt: 'Tripo 3D Model',
        autoRotate: true,
        cameraControls: true,
        disableZoom: false,
        backgroundColor: Colors.transparent,
        loading: Loading.eager,
        shadowIntensity: 0.5,
        exposure: 0.9,
        interactionPrompt: InteractionPrompt.auto,
        onWebViewCreated: (controller) {
          debugPrint('[TripoModelViewer] WebView created for ${widget.modelUrl}');
        },
      ),
    );
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

  Widget _buildCancelButton() {
    return Material(
      color: Colors.black54,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: widget.onCancel,
        child: const Padding(
          padding: EdgeInsets.all(6),
          child: Icon(Icons.close, color: Colors.white, size: 18),
        ),
      ),
    );
  }

  Widget _buildDownloadButton() {
    return Material(
      color: Colors.black54,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: widget.isDownloading
            ? null
            : () async {
                final path = await widget.onDownloadGlb?.call();
                if (path != null && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('已保存到：$path'),
                      duration: const Duration(seconds: 4),
                    ),
                  );
                }
              },
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: widget.isDownloading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2,
                  ),
                )
              : const Icon(Icons.download_rounded, color: Colors.white, size: 18),
        ),
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
