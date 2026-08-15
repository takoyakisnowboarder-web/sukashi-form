import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
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
              mode: PoseDetectionMode.single,
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
    final decoded = await _decodeForDetection(file);
    if (decoded == null) {
      return null;
    }
    try {
      final poses = await _detector.processImage(
        InputImage.fromBitmap(
          bitmap: decoded.bytes,
          width: decoded.width,
          height: decoded.height,
        ),
      );
      if (poses.isEmpty) {
        return null;
      }
      final width = decoded.width.toDouble();
      final height = decoded.height.toDouble();
      final landmarks = <PoseJoint, PosePoint>{};
      for (final entry in _jointMap.entries) {
        final landmark = poses.first.landmarks[entry.value];
        if (landmark == null) {
          continue;
        }
        final point = normalizeImagePoint(
          landmark.x,
          landmark.y,
          width: width,
          height: height,
        );
        landmarks[entry.key] = PosePoint(
          x: point.x,
          y: point.y,
          visibility: landmark.likelihood,
        );
      }
      if (landmarks.isEmpty) {
        return null;
      }
      return PoseFrame(
        imageWidth: width,
        imageHeight: height,
        landmarks: landmarks,
      );
    } on Object {
      return null;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _detector.close();
  }

  static Future<_DecodedFrame?> _decodeForDetection(File file) async {
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      return null;
    }
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 640);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) {
        return null;
      }
      return _DecodedFrame(
        bytes: data.buffer.asUint8List(),
        width: image.width,
        height: image.height,
      );
    } finally {
      image.dispose();
    }
  }
}

class _DecodedFrame {
  const _DecodedFrame({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width;
  final int height;
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
