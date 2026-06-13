import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Configure AVAudioSession for background audio playback
    do {
      try AVAudioSession.sharedInstance().setCategory(
        .playAndRecord,
        mode: .default,
        options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
      )
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      print("[AppDelegate] Failed to configure AVAudioSession: \(error)")
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Bridge MethodChannel for background audio foreground service
    let channel = FlutterMethodChannel(
      name: "com.example.ai_video/foreground_service",
      binaryMessenger: engineBridge.pluginRegistry.messenger!
    )

    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "startForeground":
        // iOS: activate audio session (AVAudioSession handles background audio)
        do {
          try AVAudioSession.sharedInstance().setActive(true)
          result(true)
        } catch {
          result(FlutterError(code: "AUDIO_SESSION_ERROR", message: error.localizedDescription, details: nil))
        }

      case "stopForeground":
        // iOS: no-op, AVAudioSession stays active for background playback
        result(true)

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
