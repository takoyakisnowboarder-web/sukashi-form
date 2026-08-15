import 'dart:io';

import 'ios_vision_pose_detector_client.dart';
import 'ml_kit_pose_detector_client.dart';
import 'pose_model.dart';

/// On-device pose detection. Implementations must not send frames off-device.
abstract interface class PoseDetectorClient {
  bool get isSupported;

  Future<PoseFrame?> detect(String imagePath);

  Future<void> close();
}

class UnsupportedPoseDetectorClient implements PoseDetectorClient {
  const UnsupportedPoseDetectorClient();

  @override
  bool get isSupported => false;

  @override
  Future<PoseFrame?> detect(String imagePath) async => null;

  @override
  Future<void> close() async {}
}

PoseDetectorClient createDefaultPoseDetectorClient() {
  if (Platform.isIOS) {
    return IosVisionPoseDetectorClient();
  }
  if (Platform.isAndroid) {
    return MlKitPoseDetectorClient();
  }
  return const UnsupportedPoseDetectorClient();
}
