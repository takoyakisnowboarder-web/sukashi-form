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
    // FrameExtractorApiImpl は probe / generateThumbnail を実装済み(フェーズ1)。
    // extractFrames などはフェーズ2以降で実装する。
    let messenger = engineBridge.applicationRegistrar.messenger()
    FrameExtractorApiSetup.setUp(binaryMessenger: messenger, api: FrameExtractorApiImpl())
  }
}
