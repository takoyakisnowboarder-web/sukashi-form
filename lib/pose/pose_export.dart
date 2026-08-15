import '../comparison/comparison_controller.dart';
import '../models/clip.dart';
import 'pose_analysis_service.dart';
import 'pose_model.dart';

const poseExportSchema = 'sukashi-form-pose/1';

const poseExportSummary =
    '動作解析用の関節座標と角度。映像そのものではなく、切り取った範囲を時系列の点にしたもの。movement に種目と技の説明がある。';

const unlabeledPoseMovement = '未記入';

String normalizePoseMovement(String? raw) {
  final trimmed = raw?.trim() ?? '';
  return trimmed.isEmpty ? unlabeledPoseMovement : trimmed;
}

const _exportJoints = <String, PoseJoint>{
  'head': PoseJoint.nose,
  'leftShoulder': PoseJoint.leftShoulder,
  'rightShoulder': PoseJoint.rightShoulder,
  'leftHip': PoseJoint.leftHip,
  'rightHip': PoseJoint.rightHip,
  'leftKnee': PoseJoint.leftKnee,
  'rightKnee': PoseJoint.rightKnee,
  'leftAnkle': PoseJoint.leftAnkle,
  'rightAnkle': PoseJoint.rightAnkle,
};

Map<String, Object?> buildPoseMotionDocument({
  required Clip clip,
  required ComparisonTrack track,
  required Map<String, PoseFrame> posesByPath,
  String? movement,
}) {
  final movementLabel = normalizePoseMovement(movement);
  return <String, Object?>{
    'schema': poseExportSchema,
    'kind': 'motion-landmarks',
    'summary': poseExportSummary,
    'movement': movementLabel,
    'timeStep': 'every-extracted-frame',
    'coordinateSpace': 'image-normalized-top-left',
    'units': <String, String>{'xy': '0-1', 'angles': 'degrees', 'time': 's'},
    'clip': <String, Object?>{
      'id': clip.id,
      'recordedAt': clip.recordedAt.toIso8601String(),
      'memo': clip.memo,
      'movement': movementLabel,
      'rangeStartMs': track.rangeStartMs,
      'rangeEndMs': track.rangeEndMs,
      'durationMs': track.rangeEndMs - track.rangeStartMs,
    },
    'frames': <Map<String, Object?>>[
      for (var index = 0; index < track.frames.length; index++)
        _frameJson(
          index: index,
          frame: track.frames[index],
          rangeStartMs: track.rangeStartMs,
          pose: posesByPath[track.frames[index].path] ??
              posesByPath[PoseAnalysisService.keyForPath(track.frames[index].path)],
        ),
    ],
  };
}

String poseExportFileName(Clip clip) {
  final stamp =
      '${clip.recordedAt.month.toString().padLeft(2, '0')}'
      '${clip.recordedAt.day.toString().padLeft(2, '0')}';
  final memo = _fileToken(clip.memo);
  final suffix = memo.isEmpty ? clip.id : memo;
  return 'sukashi-pose_${stamp}_$suffix.json';
}

Map<String, Object?> _frameJson({
  required int index,
  required ComparisonFrame frame,
  required double rangeStartMs,
  required PoseFrame? pose,
}) {
  final found = pose != null && pose.landmarks.isNotEmpty;
  final json = <String, Object?>{
    'index': index,
    't': _secondsFromStart(frame.timeMs, rangeStartMs),
    'found': found,
  };
  if (!found || pose == null) {
    return json;
  }
  for (final entry in _exportJoints.entries) {
    final point = pose.visible(entry.value);
    if (point == null) {
      continue;
    }
    json[entry.key] = <double>[
      _roundCoord(point.x),
      _roundCoord(point.y),
    ];
  }
  final angles = <String, int>{
    if (pose.leftKneeAngle != null) 'leftKnee': pose.leftKneeAngle!.round(),
    if (pose.rightKneeAngle != null) 'rightKnee': pose.rightKneeAngle!.round(),
    if (pose.leftHipAngle != null) 'leftHip': pose.leftHipAngle!.round(),
    if (pose.rightHipAngle != null) 'rightHip': pose.rightHipAngle!.round(),
  };
  if (angles.isNotEmpty) {
    json['angles'] = angles;
  }
  return json;
}

double _secondsFromStart(double timeMs, double rangeStartMs) {
  return double.parse(((timeMs - rangeStartMs) / 1000).toStringAsFixed(3));
}

double _roundCoord(double value) => double.parse(value.toStringAsFixed(4));

String _fileToken(String? value) {
  final trimmed = value?.trim() ?? '';
  if (trimmed.isEmpty) {
    return '';
  }
  return trimmed
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
      .replaceAll(RegExp(r'\s+'), '_')
      .replaceAll(RegExp(r'_+'), '_');
}
