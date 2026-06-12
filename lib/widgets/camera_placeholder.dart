import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';

/// 摄像头/麦克风未授权时的占位组件
class CameraPlaceholder extends StatelessWidget {
  const CameraPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xff1a1a1a),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.06),
              ),
              child: Icon(
                Icons.videocam_off_outlined,
                color: Colors.white.withValues(alpha: 0.25),
                size: 36,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '请授予摄像头和麦克风权限以开启视觉对话',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white54,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: () => _requestPermissions(context),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: const LinearGradient(
                    colors: [Color(0xff635bff), Color(0xff4834d4)],
                  ),
                ),
                child: const Text(
                  '授权摄像头和麦克风',
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () => openAppSettings(),
              child: const Text(
                '前往设置 >',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _requestPermissions(BuildContext context) async {
    // 同时申请相机和麦克风权限
    final cameraStatus = await Permission.camera.request();
    final micStatus = await Permission.microphone.request();

    if (context.mounted) {
      final appState = context.read<AppState>();
      appState.setCameraPermission(cameraStatus.isGranted);
      appState.setMicPermission(micStatus.isGranted);
    }
  }
}
