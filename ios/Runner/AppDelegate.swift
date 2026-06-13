import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 配置 iOS 音频会话：允许播放+录音共存，避免 SoLoud 回调被录音会话覆盖导致 SIGABRT
    do {
      let session = AVAudioSession.sharedInstance()
      // 使用 .voiceChat mode：让 iOS 启用 VoiceProcessingIO audio unit，
      // 内置回声消除（AEC）+ 自动增益（AGC）+ 噪声抑制，从硬件层把扬声器
      // 输出的 TTS 音频从 mic 输入里剥离掉。这是 VAD 模式防"AI 自言自语"
      // 死循环的物理层兜底（即便客户端 pause/resume 时序有竞态，硬件 AEC
      // 仍能保证上行的 mic 数据不包含扬声器回声）。
      try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
      try session.setActive(true)
    } catch {
      NSLog("[AppDelegate] AVAudioSession config failed: \(error)")
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
