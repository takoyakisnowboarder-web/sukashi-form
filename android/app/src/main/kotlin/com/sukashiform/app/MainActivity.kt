package com.sukashiform.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        FrameExtractorApi.setUp(
            flutterEngine.dartExecutor.binaryMessenger,
            FrameExtractorApiImpl(
                FrameExtractionProgressApi(flutterEngine.dartExecutor.binaryMessenger),
            ),
        )
    }
}
