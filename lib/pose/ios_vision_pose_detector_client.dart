import '../native/frame_extractor.g.dart';
import 'pose_detector_client.dart';
import 'pose_model.dart';

class IosVisionPoseDetectorClient implements PoseDetectorClient {
  IosVisionPoseDetectorClient({FrameExtractorApi? api})
    : _api = api ?? FrameExtractorApi();

  final FrameExtractorApi _api;

  @override
  bool get isSupported => true;

  @override
  Future<PoseFrame?> detect(String imagePath) async {
    return poseFrameFromNativeResult(await _api.detectPose(imagePath));
  }

  @override
  Future<void> close() async {}
}

PoseFrame? poseFrameFromNativeResult(NativePoseResult result) {
  if (!result.found || result.landmarks.isEmpty) {
    return null;
  }
  final landmarks = <PoseJoint, PosePoint>{};
  for (final landmark in result.landmarks) {
    final joint = poseJointNamed(landmark.joint);
    if (joint == null) {
      continue;
    }
    landmarks[joint] = PosePoint(
      x: landmark.x,
      y: landmark.y,
      visibility: landmark.visibility,
    );
  }
  if (landmarks.isEmpty) {
    return null;
  }
  return PoseFrame(
    imageWidth: result.imageWidth,
    imageHeight: result.imageHeight,
    landmarks: landmarks,
  );
}
