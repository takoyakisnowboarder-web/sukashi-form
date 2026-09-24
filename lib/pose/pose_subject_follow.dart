import 'dart:math' as math;

import 'pose_model.dart';

const subjectFollowMaxScale = 3.0;

class SubjectFollow {
  const SubjectFollow({this.scale = 1, this.centerX, this.centerY});

  static const identity = SubjectFollow();

  final double scale;
  final double? centerX;
  final double? centerY;

  @override
  bool operator ==(Object other) {
    return other is SubjectFollow &&
        other.scale == scale &&
        other.centerX == centerX &&
        other.centerY == centerY;
  }

  @override
  int get hashCode => Object.hash(scale, centerX, centerY);
}

/// Apparent body size in normalized image units. Smaller means farther away.
double? poseSubjectSize(PoseFrame pose) {
  final shoulders = _midpoint(
    pose,
    PoseJoint.leftShoulder,
    PoseJoint.rightShoulder,
  );
  final hips = _midpoint(pose, PoseJoint.leftHip, PoseJoint.rightHip);
  final ankles = _midpoint(pose, PoseJoint.leftAnkle, PoseJoint.rightAnkle);
  if (shoulders != null && ankles != null) {
    return _distance(shoulders, ankles);
  }
  if (shoulders != null && hips != null) {
    return _distance(shoulders, hips);
  }
  if (hips != null && ankles != null) {
    return _distance(hips, ankles);
  }
  return null;
}

({double x, double y})? poseSubjectCenter(PoseFrame pose) {
  return _midpoint(pose, PoseJoint.leftHip, PoseJoint.rightHip) ??
      _midpoint(pose, PoseJoint.leftShoulder, PoseJoint.rightShoulder) ??
      _single(pose, PoseJoint.nose);
}

bool personIsInFrame(PoseFrame? pose) {
  return pose != null &&
      pose.landmarks.isNotEmpty &&
      poseSubjectCenter(pose) != null;
}

SubjectFollow followSubject({
  required PoseFrame? pose,
  required double referenceSize,
  double maxScale = subjectFollowMaxScale,
}) {
  if (pose == null || referenceSize <= 0 || !personIsInFrame(pose)) {
    return SubjectFollow.identity;
  }
  final size = poseSubjectSize(pose);
  final center = poseSubjectCenter(pose);
  final scale = size == null || size <= 0
      ? 1.0
      : (referenceSize / size).clamp(1.0, maxScale);
  return SubjectFollow(scale: scale, centerX: center?.x, centerY: center?.y);
}

/// While the person is in frame, keep them. After the last detection, release
/// the frame so they can leave. A short miss in the middle keeps the last look.
SubjectFollow playbackFollow({
  required List<PoseFrame?> poses,
  required int index,
}) {
  if (index < 0 || index >= poses.length) {
    return SubjectFollow.identity;
  }
  final reference = referenceSubjectSize(poses);
  if (reference == null) {
    return SubjectFollow.identity;
  }
  if (personIsInFrame(poses[index])) {
    return followSubject(pose: poses[index], referenceSize: reference);
  }
  final returnsLater = poses.skip(index + 1).any(personIsInFrame);
  if (!returnsLater) {
    return SubjectFollow.identity;
  }
  for (var earlier = index - 1; earlier >= 0; earlier--) {
    if (personIsInFrame(poses[earlier])) {
      return followSubject(pose: poses[earlier], referenceSize: reference);
    }
  }
  return SubjectFollow.identity;
}

double? referenceSubjectSize(Iterable<PoseFrame?> poses) {
  var best = 0.0;
  for (final pose in poses) {
    if (pose == null) {
      continue;
    }
    final size = poseSubjectSize(pose);
    if (size != null && size > best) {
      best = size;
    }
  }
  return best > 0 ? best : null;
}

({double x, double y})? _midpoint(
  PoseFrame pose,
  PoseJoint left,
  PoseJoint right,
) {
  final a = pose.visible(left);
  final b = pose.visible(right);
  if (a != null && b != null) {
    return (x: (a.x + b.x) / 2, y: (a.y + b.y) / 2);
  }
  if (a != null) {
    return (x: a.x, y: a.y);
  }
  if (b != null) {
    return (x: b.x, y: b.y);
  }
  return null;
}

({double x, double y})? _single(PoseFrame pose, PoseJoint joint) {
  final point = pose.visible(joint);
  if (point == null) {
    return null;
  }
  return (x: point.x, y: point.y);
}

double _distance(({double x, double y}) a, ({double x, double y}) b) {
  final dx = a.x - b.x;
  final dy = a.y - b.y;
  return math.sqrt(dx * dx + dy * dy);
}
