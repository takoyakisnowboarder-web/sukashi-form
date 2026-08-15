import 'dart:math' as math;

enum PoseJoint {
  nose,
  leftShoulder,
  rightShoulder,
  leftElbow,
  rightElbow,
  leftWrist,
  rightWrist,
  leftHip,
  rightHip,
  leftKnee,
  rightKnee,
  leftAnkle,
  rightAnkle,
  leftHeel,
  rightHeel,
  leftFootIndex,
  rightFootIndex,
}

class PosePoint {
  const PosePoint({required this.x, required this.y, required this.visibility});

  final double x;
  final double y;
  final double visibility;

  bool get isVisible => visibility >= 0.4;

  Map<String, Object> toJson() => <String, Object>{
    'x': x,
    'y': y,
    'v': visibility,
  };

  factory PosePoint.fromJson(Map<String, dynamic> json) {
    return PosePoint(
      x: (json['x'] as num).toDouble(),
      y: (json['y'] as num).toDouble(),
      visibility: (json['v'] as num?)?.toDouble() ?? 0,
    );
  }
}

class PoseFrame {
  const PoseFrame({
    required this.imageWidth,
    required this.imageHeight,
    required this.landmarks,
  });

  final double imageWidth;
  final double imageHeight;
  final Map<PoseJoint, PosePoint> landmarks;

  /// iOS の ML Kit は座標が出ていても likelihood が常に 0 になることがある。
  bool get treatsUnscoredPointsAsVisible {
    return landmarks.isNotEmpty &&
        landmarks.values.every((point) => point.visibility == 0);
  }

  PosePoint? visible(PoseJoint joint) {
    final point = landmarks[joint];
    if (point == null) {
      return null;
    }
    if (treatsUnscoredPointsAsVisible) {
      if (point.x < 0 || point.x > 1 || point.y < 0 || point.y > 1) {
        return null;
      }
      return point;
    }
    if (!point.isVisible) {
      return null;
    }
    return point;
  }

  /// Degrees at [vertex], or null if any point is missing.
  double? angle(PoseJoint from, PoseJoint vertex, PoseJoint to) {
    final a = visible(from);
    final b = visible(vertex);
    final c = visible(to);
    if (a == null || b == null || c == null) {
      return null;
    }
    return jointAngleDegrees(a, b, c);
  }

  double? get leftKneeAngle =>
      angle(PoseJoint.leftHip, PoseJoint.leftKnee, PoseJoint.leftAnkle);

  double? get rightKneeAngle =>
      angle(PoseJoint.rightHip, PoseJoint.rightKnee, PoseJoint.rightAnkle);

  double? get leftHipAngle =>
      angle(PoseJoint.leftShoulder, PoseJoint.leftHip, PoseJoint.leftKnee);

  double? get rightHipAngle =>
      angle(PoseJoint.rightShoulder, PoseJoint.rightHip, PoseJoint.rightKnee);

  double? get leftFootAngle =>
      angle(PoseJoint.leftHeel, PoseJoint.leftAnkle, PoseJoint.leftFootIndex);

  double? get rightFootAngle => angle(
    PoseJoint.rightHeel,
    PoseJoint.rightAnkle,
    PoseJoint.rightFootIndex,
  );

  Map<String, Object> toJson() => <String, Object>{
    'w': imageWidth,
    'h': imageHeight,
    'landmarks': <String, Object>{
      for (final entry in landmarks.entries)
        entry.key.name: entry.value.toJson(),
    },
  };

  factory PoseFrame.fromJson(Map<String, dynamic> json) {
    final raw = Map<String, dynamic>.from(json['landmarks'] as Map);
    return PoseFrame(
      imageWidth: (json['w'] as num).toDouble(),
      imageHeight: (json['h'] as num).toDouble(),
      landmarks: <PoseJoint, PosePoint>{
        for (final joint in PoseJoint.values)
          if (raw[joint.name] is Map)
            joint: PosePoint.fromJson(
              Map<String, dynamic>.from(raw[joint.name] as Map),
            ),
      },
    );
  }
}

const poseBones = <(PoseJoint, PoseJoint)>[
  (PoseJoint.leftShoulder, PoseJoint.rightShoulder),
  (PoseJoint.leftShoulder, PoseJoint.leftHip),
  (PoseJoint.rightShoulder, PoseJoint.rightHip),
  (PoseJoint.leftHip, PoseJoint.rightHip),
  (PoseJoint.leftShoulder, PoseJoint.leftElbow),
  (PoseJoint.leftElbow, PoseJoint.leftWrist),
  (PoseJoint.rightShoulder, PoseJoint.rightElbow),
  (PoseJoint.rightElbow, PoseJoint.rightWrist),
  (PoseJoint.leftHip, PoseJoint.leftKnee),
  (PoseJoint.leftKnee, PoseJoint.leftAnkle),
  (PoseJoint.rightHip, PoseJoint.rightKnee),
  (PoseJoint.rightKnee, PoseJoint.rightAnkle),
  (PoseJoint.leftAnkle, PoseJoint.leftHeel),
  (PoseJoint.leftAnkle, PoseJoint.leftFootIndex),
  (PoseJoint.leftHeel, PoseJoint.leftFootIndex),
  (PoseJoint.rightAnkle, PoseJoint.rightHeel),
  (PoseJoint.rightAnkle, PoseJoint.rightFootIndex),
  (PoseJoint.rightHeel, PoseJoint.rightFootIndex),
  (PoseJoint.nose, PoseJoint.leftShoulder),
  (PoseJoint.nose, PoseJoint.rightShoulder),
];

const highlightedJoints = <PoseJoint>{
  PoseJoint.nose,
  PoseJoint.leftShoulder,
  PoseJoint.rightShoulder,
  PoseJoint.leftHip,
  PoseJoint.rightHip,
  PoseJoint.leftKnee,
  PoseJoint.rightKnee,
  PoseJoint.leftAnkle,
  PoseJoint.rightAnkle,
  PoseJoint.leftHeel,
  PoseJoint.rightHeel,
  PoseJoint.leftFootIndex,
  PoseJoint.rightFootIndex,
};

double jointAngleDegrees(PosePoint a, PosePoint b, PosePoint c) {
  final bax = a.x - b.x;
  final bay = a.y - b.y;
  final bcx = c.x - b.x;
  final bcy = c.y - b.y;
  final dot = bax * bcx + bay * bcy;
  final mag =
      math.sqrt(bax * bax + bay * bay) * math.sqrt(bcx * bcx + bcy * bcy);
  if (mag == 0) {
    return 0;
  }
  return (math.acos((dot / mag).clamp(-1, 1)) * 180 / math.pi);
}
