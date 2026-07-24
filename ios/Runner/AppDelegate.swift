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
    // FrameExtractorApiImpl は probe / generateThumbnail / extractFrames を実装済み。
    // 展開の進捗は FrameExtractionProgressApi 経由で Dart へ返す。
    let messenger = engineBridge.applicationRegistrar.messenger()
    FrameExtractorApiSetup.setUp(
      binaryMessenger: messenger,
      api: FrameExtractorApiImpl(
        progressApi: FrameExtractionProgressApi(binaryMessenger: messenger)
      )
    )
  }
}
