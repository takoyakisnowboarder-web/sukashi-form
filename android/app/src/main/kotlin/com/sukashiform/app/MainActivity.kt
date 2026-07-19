package com.sukashiform.app

import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var captureVolumeKeys = false
    private var volumeKeyApi: VolumeKeyApi? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        volumeKeyApi = VolumeKeyApi(messenger)
        FrameExtractorApi.setUp(
            messenger,
            FrameExtractorApiImpl(
                applicationContext,
                FrameExtractionProgressApi(messenger),
                onVolumeKeyCaptureChanged = { captureVolumeKeys = it },
            ),
        )
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val isVolumeKey = event.keyCode == KeyEvent.KEYCODE_VOLUME_UP ||
            event.keyCode == KeyEvent.KEYCODE_VOLUME_DOWN
        if (!captureVolumeKeys || !isVolumeKey) {
            return super.dispatchKeyEvent(event)
        }
        if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
            volumeKeyApi?.onVolumeKeyPressed { }
        }
        // Consume DOWN, repeats and UP so capture mode never changes system volume.
        return true
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        captureVolumeKeys = false
        volumeKeyApi = null
        FrameExtractorApi.setUp(flutterEngine.dartExecutor.binaryMessenger, null)
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
