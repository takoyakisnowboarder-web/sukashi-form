import 'dart:io';
import 'dart:ui' as ui;

import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import 'pose_detector_client.dart';
import 'pose_model.dart';

/// Google ML Kit Pose Detection. Models are bundled; frames stay on device.
class MlKitPoseDetectorClient implements PoseDetectorClient {
  MlKitPoseDetectorClient({PoseDetector? detector})
    : _detector =
          detector ??
          PoseDetector(
            options: PoseDetectorOptions(
              mode: PoseDetectionMode.stream,
              model: PoseDetectionModel.base,
            ),
          );

  final PoseDetector _detector;
  bool _closed = false;

  @override
  bool get isSupported => true;

  @override
  Future<PoseFrame?> detect(String imagePath) async {
    if (_closed) {
      return null;
    }
    final file = File(imagePath);
    if (!await file.exists()) {
      return null;
    }
    final size = await _readImageSize(file);
    if (size == null || size.width <= 0 || size.height <= 0) {
      return null;
    }
    final poses = await _detector.processImage(
      InputImage.fromFilePath(imagePath),
    );
    if (poses.isEmpty) {
      return null;
    }
    final landmarks = <PoseJoint, PosePoint>{};
    for (final entry in _jointMap.entries) {
      final landmark = poses.first.landmarks[entry.value];
      if (landmark == null) {
        continue;
      }
      landmarks[entry.key] = PosePoint(
        x: landmark.x / size.width,
        y: landmark.y / size.height,
        visibility: landmark.likelihood,
      );
    }
    if (landmarks.isEmpty) {
      return null;
    }
    return PoseFrame(
      imageWidth: size.width,
      imageHeight: size.height,
      landmarks: landmarks,
    );
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _detector.close();
  }

  static Future<ui.Size?> _readImageSize(File file) async {
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      return null;
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        return ui.Size(
          descriptor.width.toDouble(),
          descriptor.height.toDouble(),
        );
      } finally {
        descriptor.dispose();
      }
    } on Object {
      return null;
    } finally {
      buffer.dispose();
    }
  }
}

const _jointMap = <PoseJoint, PoseLandmarkType>{
  PoseJoint.nose: PoseLandmarkType.nose,
  PoseJoint.leftShoulder: PoseLandmarkType.leftShoulder,
  PoseJoint.rightShoulder: PoseLandmarkType.rightShoulder,
  PoseJoint.leftElbow: PoseLandmarkType.leftElbow,
  PoseJoint.rightElbow: PoseLandmarkType.rightElbow,
  PoseJoint.leftWrist: PoseLandmarkType.leftWrist,
  PoseJoint.rightWrist: PoseLandmarkType.rightWrist,
  PoseJoint.leftHip: PoseLandmarkType.leftHip,
  PoseJoint.rightHip: PoseLandmarkType.rightHip,
  PoseJoint.leftKnee: PoseLandmarkType.leftKnee,
  PoseJoint.rightKnee: PoseLandmarkType.rightKnee,
  PoseJoint.leftAnkle: PoseLandmarkType.leftAnkle,
  PoseJoint.rightAnkle: PoseLandmarkType.rightAnkle,
  PoseJoint.leftHeel: PoseLandmarkType.leftHeel,
  PoseJoint.rightHeel: PoseLandmarkType.rightHeel,
  PoseJoint.leftFootIndex: PoseLandmarkType.leftFootIndex,
  PoseJoint.rightFootIndex: PoseLandmarkType.rightFootIndex,
};
