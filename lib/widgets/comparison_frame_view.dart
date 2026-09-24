import 'dart:io';

import 'package:flutter/material.dart';

import '../comparison/comparison_controller.dart';
import '../pose/pose_model.dart';
import '../pose/pose_skeleton_painter.dart';
import '../pose/pose_subject_follow.dart';

/// A frame image with a logical, non-destructive alignment transform.
class ComparisonFrameView extends StatelessWidget {
  const ComparisonFrameView({
    required this.clipId,
    required this.path,
    required this.transform,
    required this.cacheWidth,
    this.pose,
    this.skeletonColor = const Color(0xFF38BDF8),
    this.follow = SubjectFollow.identity,
    super.key,
  });

  final String clipId;
  final String path;
  final AlignmentTransform transform;
  final int cacheWidth;
  final PoseFrame? pose;
  final Color skeletonColor;
  final SubjectFollow follow;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Transform.translate(
        key: Key('frame-translation-$clipId'),
        offset: Offset(transform.dx, transform.dy),
        child: Transform.rotate(
          key: Key('frame-rotation-$clipId'),
          angle: transform.rotation,
          child: Transform.scale(
            key: Key('frame-scale-$clipId'),
            alignment: _followAlignment(follow),
            scale: transform.scale * follow.scale,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                Image.file(
                  File(path),
                  key: Key('frame-image-$clipId'),
                  fit: BoxFit.contain,
                  cacheWidth: cacheWidth,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const Center(
                    child: Icon(Icons.broken_image, color: Colors.white),
                  ),
                ),
                if (pose != null && pose!.landmarks.isNotEmpty)
                  Positioned.fill(
                    child: CustomPaint(
                      key: Key('pose-skeleton-$clipId'),
                      painter: PoseSkeletonPainter(
                        pose: pose!,
                        color: skeletonColor,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Alignment _followAlignment(SubjectFollow follow) {
  final x = follow.centerX;
  final y = follow.centerY;
  if (x == null || y == null || follow.scale <= 1.01) {
    return Alignment.center;
  }
  return Alignment((x - 0.5) * 2, (y - 0.5) * 2);
}
