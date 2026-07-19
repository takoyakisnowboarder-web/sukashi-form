import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'frame_extractor.g.dart';

abstract interface class CaptureDeviceBridge {
  Future<bool> isGallerySaveSupported();

  Future<void> saveVideoToGallery(String absoluteVideoPath);

  Future<void> enableVolumeKeyCapture(VoidCallback onPressed);

  Future<void> disableVolumeKeyCapture();
}

final captureDeviceBridgeProvider = Provider<CaptureDeviceBridge>((ref) {
  return PigeonCaptureDeviceBridge();
});

class PigeonCaptureDeviceBridge implements CaptureDeviceBridge {
  PigeonCaptureDeviceBridge({FrameExtractorApi? api})
    : _api = api ?? FrameExtractorApi();

  final FrameExtractorApi _api;

  @override
  Future<bool> isGallerySaveSupported() => _api.isGallerySaveSupported();

  @override
  Future<void> saveVideoToGallery(String absoluteVideoPath) =>
      _api.saveVideoToGallery(absoluteVideoPath);

  @override
  Future<void> enableVolumeKeyCapture(VoidCallback onPressed) async {
    final handler = _VolumeKeyHandler(onPressed);
    VolumeKeyApi.setUp(handler);
    await _api.setVolumeKeyCaptureEnabled(true);
  }

  @override
  Future<void> disableVolumeKeyCapture() async {
    await _api.setVolumeKeyCaptureEnabled(false);
    VolumeKeyApi.setUp(null);
  }
}

class _VolumeKeyHandler implements VolumeKeyApi {
  _VolumeKeyHandler(this._onPressed);

  final VoidCallback _onPressed;

  @override
  void onVolumeKeyPressed() => _onPressed();
}

typedef ImportRecordedVideo =
    Future<void> Function(String path, {required int durationMs});

class RecordedVideoSaveResult {
  const RecordedVideoSaveResult({required this.gallerySaveFailed});

  final bool gallerySaveFailed;
}

/// Saves the app-library copy first. Gallery export is deliberately secondary.
class RecordedVideoSaver {
  const RecordedVideoSaver(this._deviceBridge);

  final CaptureDeviceBridge _deviceBridge;

  Future<RecordedVideoSaveResult> save({
    required String sourcePath,
    required int durationMs,
    required bool saveToGallery,
    required bool gallerySaveSupported,
    required ImportRecordedVideo importIntoLibrary,
  }) async {
    await importIntoLibrary(sourcePath, durationMs: durationMs);
    if (!saveToGallery || !gallerySaveSupported) {
      return const RecordedVideoSaveResult(gallerySaveFailed: false);
    }
    try {
      await _deviceBridge.saveVideoToGallery(sourcePath);
      return const RecordedVideoSaveResult(gallerySaveFailed: false);
    } on Object {
      return const RecordedVideoSaveResult(gallerySaveFailed: true);
    }
  }
}
