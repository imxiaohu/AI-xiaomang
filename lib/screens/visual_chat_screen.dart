import 'dart:math' as math;
import 'package:flutter/material.dart';
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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initApp();
    });
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
                  onToggleFlash: appState.toggleFlash,
                  onSwitchCamera: appState.switchCamera,
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
                    statusText: appState.tripoGenerating ? appState.tripoStatusText : null,
                    aiStatus: appState.aiStatus,
                    runMode: appState.runMode,
                    omniMode: appState.omniMode,
                    ttsVolume: appState.ttsVolume,
                    hardwareInfo: appState.hardwareInfo,
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

    return Stack(
      fit: StackFit.expand,
      children: [
        // 摄像头画面（等比例裁剪填充）
        FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: controller.value.previewSize?.height ?? 1,
            height: controller.value.previewSize?.height ?? 1,
            child: CameraPreview(controller),
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
    final tid = appState.tripoTaskId;
    if (tid == null) return null;
    return appState.activePreviewUrl;
  }
}
