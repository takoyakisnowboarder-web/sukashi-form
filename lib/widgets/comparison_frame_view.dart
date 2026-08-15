import 'dart:io';

import 'package:flutter/material.dart';

import '../comparison/comparison_controller.dart';
import '../pose/pose_model.dart';
import '../pose/pose_skeleton_painter.dart';

/// A frame image with a logical, non-destructive alignment transform.
class ComparisonFrameView extends StatelessWidget {
  const ComparisonFrameView({
    required this.clipId,
    required this.path,
    required this.transform,
    required this.cacheWidth,
    this.pose,
    this.skeletonColor = const Color(0xFF38BDF8),
    super.key,
  });

  final String clipId;
  final String path;
  final AlignmentTransform transform;
  final int cacheWidth;
  final PoseFrame? pose;
  final Color skeletonColor;

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
            scale: transform.scale,
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
                if (pose != null)
                  CustomPaint(
                    key: Key('pose-skeleton-$clipId'),
                    painter: PoseSkeletonPainter(
                      pose: pose!,
                      color: skeletonColor,
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
