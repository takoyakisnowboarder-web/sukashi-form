import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Android の MainActivity#configureFlutterEngine と同じ配線。
    // 実体は FrameExtractorApiStub(全メソッド unimplemented)。
    // AVAssetImageGenerator による実装は Codex に Mac/Xcode 環境が揃ってから着手する。
    let messenger = engineBridge.applicationRegistrar.messenger()
    FrameExtractorApiSetup.setUp(binaryMessenger: messenger, api: FrameExtractorApiStub())
  }
}
