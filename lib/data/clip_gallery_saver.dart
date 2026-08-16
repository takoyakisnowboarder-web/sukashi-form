import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/clip.dart';
import '../native/capture_device_bridge.dart';
import '../providers/clip_providers.dart';
import 'clip_repository.dart';

final clipGallerySaverProvider = Provider<ClipGallerySaver>((ref) {
  return ClipGallerySaver(
    ref.watch(captureDeviceBridgeProvider),
    ref.watch(clipRepositoryProvider),
  );
});

class ClipGallerySaver {
  const ClipGallerySaver(this._deviceBridge, this._repository);

  final CaptureDeviceBridge _deviceBridge;
  final ClipRepository _repository;

  Future<bool> isSupported() async {
    try {
      return await _deviceBridge.isGallerySaveSupported();
    } on Object {
      return false;
    }
  }

  Future<void> save(Clip clip) async {
    if (clip.isBroken) {
      throw StateError('Broken clips cannot be saved to the photo library.');
    }
    final path = await _repository.resolveAbsolutePath(clip.videoPath);
    await _deviceBridge.saveVideoToGallery(path);
  }
}
