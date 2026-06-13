import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:camera/camera.dart';
import '../providers/app_state.dart';
import '../models/enums.dart';
import '../widgets/status_bar.dart';
import '../widgets/bottom_action_bar.dart';
import '../widgets/chat_panel.dart';
import '../widgets/camera_placeholder.dart';
import '../widgets/tripo_model_viewer.dart';
import '../widgets/tripo_generation_dialog.dart';

/// 主页面：全屏视频 + AI球体 + 底部操作栏 + 对话面板
class VisualChatScreen extends StatefulWidget {
  const VisualChatScreen({super.key});

  @override
  State<VisualChatScreen> createState() => _VisualChatScreenState();
}

class _VisualChatScreenState extends State<VisualChatScreen>
    with WidgetsBindingObserver {
  StreamSubscription<String>? _infoSub;
  bool _isDownloadingGlb = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initApp();
      // 监听 AppState 的提示流（3D 生成成功等），在主屏弹 SnackBar
      _infoSub = context.read<AppState>().infoMessages.listen(_onInfo);
    });
  }

  void _onInfo(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        action: SnackBarAction(
          label: '管理',
          onPressed: () {
            Navigator.of(context).pushNamed('/settings');
          },
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _initApp() async {
    final appState = context.read<AppState>();
    await appState.init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final appState = context.read<AppState>();
    if (state == AppLifecycleState.paused) {
      // 切后台：停止摄像头抽帧，仅维持麦克风收音
      appState.pauseFrameCapture();
    } else if (state == AppLifecycleState.resumed) {
      // 切前台：恢复抽帧
      appState.resumeFrameCapture();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _infoSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (ctx, appState, _) {
        return Scaffold(
          body: Stack(
            children: [
              // === 底层：全屏视频预览 ===
              _buildVideoPreview(appState),

              // === 视频底部渐变遮罩 ===
              _buildGradientMask(),

              // === 顶部状态栏 ===
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: StatusBar(
                  runMode: appState.runMode,
                  flashOn: appState.flashOn,
                  connectionStatus: appState.connectionStatus,
                  modelLoadProgress:
                      appState.modelLoaded ? -1 : appState.modelLoadProgress,
                  simulationMode: appState.simulationMode,
                  isDownloading: appState.isDownloading,
                  downloadProgress: appState.downloadProgress,
                  downloadCurrentFile: appState.downloadCurrentFile,
                  downloadError: appState.downloadError,
                  autoFocus: appState.autoFocus,
                  onToggleFlash: appState.toggleFlash,
                  onSwitchCamera: appState.switchCamera,
                  onToggleAutoFocus: appState.toggleAutoFocus,
                  onOpenMarketplace: () =>
                      Navigator.of(context).pushNamed('/marketplace'),
                  onOpenSettings: () =>
                      Navigator.of(context).pushNamed('/settings'),
                ),
              ),

              // === 悬浮AI球体 / Tripo 3D模型 ===
              Positioned(
                top: MediaQuery.of(context).size.height * 0.52,
                left: 0,
                right: 0,
                child: Center(
                  child: TripoModelViewer(
                    modelUrl: _tripoModelUrl(appState),
                    previewImageUrl: _tripoPreviewUrl(appState),
                    isGenerating: appState.tripoGenerating,
                    progress: appState.tripoGenerating ? appState.tripoProgress : null,
                    statusText: appState.tripoStatusText,
                    aiStatus: appState.aiStatus,
                    runMode: appState.runMode,
                    omniMode: appState.omniMode,
                    ttsVolume: appState.ttsVolume,
                    hardwareInfo: appState.hardwareInfo,
                    // 新增：取消 / 取消权限 / 保存 GLB
                    onCancel: appState.cancelTripoGeneration,
                    canCancel: appState.tripoCanCancel,
                    isDownloading: _isDownloadingGlb,
                    onDownloadGlb: _isDownloadingGlb ? null : _downloadGlbToLocal,
                  ),
                ),
              ),

              // === 3D生成按钮（右下角悬浮）===
              if (!appState.tripoGenerating)
                Positioned(
                  bottom: MediaQuery.of(context).size.height * 0.20,
                  right: 16,
                  child: _buildTripoButton(context, appState),
                ),

              // === 底部操作栏 ===
              Positioned(
                bottom: appState.chatPanelExpanded
                    ? _chatPanelHeight(context, expanded: true) + 10
                    : _chatPanelHeight(context, expanded: false) + _bottomSafePadding(context),
                left: 0,
                right: 0,
                child: BottomActionBar(
                  runMode: appState.runMode,
                  aiStatus: appState.aiStatus,
                  omniMode: appState.omniMode,
                  chatPanelExpanded: appState.chatPanelExpanded,
                  recordingSeconds: appState.recordingSeconds,
                  onToggleRunMode: appState.toggleRunMode,
                  onToggleOmniMode: () => appState.setOmniMode(
                    appState.omniMode == OmniInteractionMode.manual
                        ? OmniInteractionMode.vad
                        : OmniInteractionMode.manual,
                  ),
                  onToggleChatPanel: appState.toggleChatPanel,
                  onLongPressStart: () => appState.startListening(),
                  onLongPressEnd: () => appState.stopListeningAndThink(),
                  onVadTap: () => appState.toggleVadListening(),
                ),
              ),

              // === 底部对话面板 ===
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: ChatPanel(
                  messages: appState.messages,
                  expanded: appState.chatPanelExpanded,
                  runMode: appState.runMode,
                  streamingText: appState.currentStreamingText,
                  onToggle: appState.toggleChatPanel,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 视频预览区域（占70%高度）
  Widget _buildVideoPreview(AppState appState) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      height: MediaQuery.of(context).size.height * 0.70,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: !appState.cameraPermissionGranted
              ? const CameraPlaceholder()
              : _buildCameraPreview(appState),
        ),
      ),
    );
  }

  /// 真实摄像头预览
  Widget _buildCameraPreview(AppState appState) {
    final controller = appState.cameraController;
    if (controller == null || !controller.value.isInitialized) {
      return Container(
        color: const Color(0xff1a1a1a),
        child: const Center(
          child: CircularProgressIndicator(color: Color(0xff635bff)),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // 计算摄像头画面在屏幕上的实际渲染矩形（BoxFit.cover 居中裁剪后）
        final renderRect = _computeCameraRenderRect(
          controller: controller,
          boxConstraints: constraints,
        );

        return Stack(
          fit: StackFit.expand,
          children: [
            // 摄像头画面（等比例裁剪填充）
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) => _onCameraTap(
                appState,
                details.localPosition,
                controller: controller,
                renderRect: renderRect,
              ),
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: controller.value.previewSize?.height ?? 1,
                  height: controller.value.previewSize?.height ?? 1,
                  child: CameraPreview(controller),
                ),
              ),
            ),

            // 对焦指示器（点击位置显示的方框）
            if (appState.focusPoint != null)
              Positioned(
                left: appState.focusPoint!.dx - 40,
                top: appState.focusPoint!.dy - 40,
                child: const _FocusIndicator(),
              ),

            // 对焦模式提示（屏幕中央底部，1.5s 自动消失）
            Positioned(
              bottom: 12,
              left: 0,
              right: 0,
              child: Center(
                child: _FocusModeBadge(autoFocus: appState.autoFocus),
              ),
            ),

            // 底部黑边渐变
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              height: 60,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.5),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 计算 BoxFit.cover 模式下摄像头画面在屏幕上的实际渲染矩形
  Rect _computeCameraRenderRect({
    required CameraController controller,
    required BoxConstraints boxConstraints,
  }) {
    final previewSize = controller.value.previewSize;
    if (previewSize == null) {
      return Offset.zero & boxConstraints.biggest;
    }
    // CameraPreview 内部是横向的，Flutter 插件会按 deviceOrientation 旋转
    // 这里取 previewSize.height 作为显示的宽，与 CameraPreview 内的 SizedBox 一致
    final srcW = previewSize.height;
    final srcH = previewSize.width;
    final dstW = boxConstraints.maxWidth;
    final dstH = boxConstraints.maxHeight;
    if (srcW == 0 || srcH == 0) return Offset.zero & boxConstraints.biggest;

    // BoxFit.cover: 保持纵横比填满容器，超出部分裁剪
    final srcRatio = srcW / srcH;
    final dstRatio = dstW / dstH;
    double renderW, renderH;
    if (srcRatio > dstRatio) {
      // 源更"宽"：以目标高度为基准，宽度超出
      renderH = dstH;
      renderW = dstH * srcRatio;
    } else {
      // 源更"高"：以目标宽度为基准，高度超出
      renderW = dstW;
      renderH = dstW / srcRatio;
    }
    final dx = (dstW - renderW) / 2;
    final dy = (dstH - renderH) / 2;
    return Rect.fromLTWH(dx, dy, renderW, renderH);
  }

  /// 处理摄像头预览区域内的点击：触发对焦
  void _onCameraTap(
    AppState appState,
    Offset localPosition, {
    required CameraController controller,
    required Rect renderRect,
  }) {
    final previewSize = controller.value.previewSize;
    if (previewSize == null) return;
    appState.focusAt(
      localPosition,
      previewSize: previewSize,
      renderRect: renderRect,
    );
  }

  /// 视频底部渐变遮罩
  Widget _buildGradientMask() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      height: MediaQuery.of(context).size.height * 0.35,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black87],
          ),
        ),
      ),
    );
  }

  /// ChatPanel 高度（折叠52dp，展开45%屏幕高度）
  double _chatPanelHeight(BuildContext context, {required bool expanded}) {
    if (expanded) {
      return MediaQuery.of(context).size.height * 0.45;
    }
    return 52.0; // 折叠态：拖拽条+一行文字高度
  }

  double _bottomSafePadding(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    return math.max(bottom, 30.0);
  }

  /// 生成按钮：右下角悬浮
  Widget _buildTripoButton(BuildContext context, AppState appState) {
    return GestureDetector(
      onTap: () => _showTripoDialog(context, appState),
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xff635bff), Color(0xff8b5cf6)],
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xff635bff).withValues(alpha: 0.4),
              blurRadius: 12,
              spreadRadius: 2,
            ),
          ],
        ),
        child: const Icon(
          Icons.view_in_ar,
          color: Colors.white,
          size: 24,
        ),
      ),
    );
  }

  void _showTripoDialog(BuildContext context, AppState appState) {
    showDialog(
      context: context,
      builder: (ctx) => TripoGenerationDialog(
        onSubmit: (input, mode) {
          switch (mode) {
            case TripoGenerationMode.textTo3D:
              appState.startTextTo3D(input);
              break;
            case TripoGenerationMode.imageTo3D:
              appState.startImageTo3D(input);
              break;
            case TripoGenerationMode.multiImageTo3D:
              appState.startMultiImageTo3D(input);
              break;
          }
        },
      ),
    );
  }

  String? _tripoModelUrl(AppState appState) {
    // 成功后才渲染 GLB 模型
    if (!appState.tripoSucceeded) return null;
    return appState.activeGlbUrl;
  }

  String? _tripoPreviewUrl(AppState appState) {
    // 修 bug #2：市场选用后 tripoTaskId 为 null，此时 activePreviewUrl
    // 仍能从 _activeMarketplaceItem.previewUrl 解析出预览图。
    if (appState.activePreviewUrl == null) return null;
    return appState.activePreviewUrl;
  }

  /// 下载当前 3D 模型的 GLB 到本地（Documents/）
  Future<String?> _downloadGlbToLocal() async {
    final appState = context.read<AppState>();
    final tid = appState.tripoTaskId ?? appState.activeMarketplaceItem?.taskId;
    final svc = appState.tripoService;
    if (tid == null || svc == null) {
      _toast('当前没有可保存的 3D 模型');
      return null;
    }
    setState(() => _isDownloadingGlb = true);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final path = '${dir.path}/model_$tid.glb';
      final bytes = await svc.downloadGlbToFile(tid, path);
      debugPrint('[VisualChat] saved GLB ${bytes}B to $path');
      return path;
    } catch (e) {
      _toast('保存失败：$e');
      return null;
    } finally {
      if (mounted) setState(() => _isDownloadingGlb = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }
}

/// 点击屏幕时显示的对焦方框（参考 iOS 原生相机）
/// - 出现：从大缩小到正常尺寸（弹性动画）
/// - 消失：先变细（黄色 → 浅绿）然后淡出
class _FocusIndicator extends StatefulWidget {
  const _FocusIndicator();

  @override
  State<_FocusIndicator> createState() => _FocusIndicatorState();
}

class _FocusIndicatorState extends State<_FocusIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    )..forward();
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
      builder: (context, _) {
        // 0 → 0.6：1.6 → 1.0（缩小到正常）
        // 0.6 → 1.0：保持 1.0
        final t = _ctrl.value;
        final scale = t < 0.6
            ? 1.6 - (1.6 - 1.0) * (t / 0.6)
            : 1.0;
        return Transform.scale(
          scale: scale,
          child: Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              border: Border.all(
                color: const Color(0xFFFFD60A), // iOS 风格黄色
                width: 1.5,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 屏幕底部居中显示的对焦模式徽章
/// 自动对焦时显示"自动对焦"，手动对焦时显示"点按对焦"
class _FocusModeBadge extends StatelessWidget {
  const _FocusModeBadge({required this.autoFocus});
  final bool autoFocus;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        autoFocus ? '自动对焦' : '点按屏幕指定对焦点',
        style: const TextStyle(color: Colors.white, fontSize: 11),
      ),
    );
  }
}
