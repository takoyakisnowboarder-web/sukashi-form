import 'package:flutter/material.dart';

import 'pose_model.dart';

class PoseSkeletonPainter extends CustomPainter {
  PoseSkeletonPainter({required this.pose, required this.color});

  final PoseFrame pose;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (pose.landmarks.isEmpty ||
        pose.imageWidth <= 0 ||
        pose.imageHeight <= 0) {
      return;
    }
    final fitted = applyBoxFit(
      BoxFit.contain,
      Size(pose.imageWidth, pose.imageHeight),
      size,
    );
    final dest = Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & size,
    );
    Offset map(PosePoint point) {
      return Offset(
        dest.left + point.x * dest.width,
        dest.top + point.y * dest.height,
      );
    }

    final bonePaint = Paint()
      ..color = color
      ..strokeWidth = 3.2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final bone in poseBones) {
      final a = pose.visible(bone.$1);
      final b = pose.visible(bone.$2);
      if (a == null || b == null) {
        continue;
      }
      canvas.drawLine(map(a), map(b), bonePaint);
    }

    final fill = Paint()..color = color;
    final highlight = Paint()..color = Colors.white;
    for (final joint in pose.landmarks.keys) {
      final point = pose.visible(joint);
      if (point == null) {
        continue;
      }
      final center = map(point);
      final radius = highlightedJoints.contains(joint) ? 5.2 : 3.2;
      canvas.drawCircle(center, radius, fill);
      if (highlightedJoints.contains(joint)) {
        canvas.drawCircle(center, radius * 0.35, highlight);
      }
    }
  }

  @override
  bool shouldRepaint(covariant PoseSkeletonPainter oldDelegate) {
    return oldDelegate.pose != pose || oldDelegate.color != color;
  }
}

class PoseAngleHud extends StatelessWidget {
  const PoseAngleHud({
    required this.label,
    required this.pose,
    required this.color,
    super.key,
  });

  final String label;
  final PoseFrame? pose;
  final Color color;

  @override
  Widget build(BuildContext context) {
    String format(String name, double? value) {
      if (value == null) {
        return '$name --';
      }
      return '$name ${value.round()}°';
    }

    final text = pose == null
        ? '$label 解析待ち'
        : pose!.landmarks.isEmpty
        ? '$label 人を検出できませんでした'
        : '$label  '
              '${format('左膝', pose!.leftKneeAngle)}  '
              '${format('右膝', pose!.rightKneeAngle)}  '
              '${format('左腰', pose!.leftHipAngle)}  '
              '${format('右腰', pose!.rightHipAngle)}  '
              '${format('左足', pose!.leftFootAngle)}  '
              '${format('右足', pose!.rightFootAngle)}';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.8)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Text(
          text,
          key: Key('pose-angle-hud-$label'),
          style: TextStyle(color: color, fontSize: 11, height: 1.25),
        ),
      ),
    );
  }
}
