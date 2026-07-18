import 'dart:io';

import 'package:flutter/material.dart';

import '../comparison/comparison_controller.dart';

/// A frame image with a logical, non-destructive alignment transform.
class ComparisonFrameView extends StatelessWidget {
  const ComparisonFrameView({
    required this.clipId,
    required this.path,
    required this.transform,
    required this.cacheWidth,
    super.key,
  });

  final String clipId;
  final String path;
  final AlignmentTransform transform;
  final int cacheWidth;

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
            child: Image.file(
              File(path),
              key: Key('frame-image-$clipId'),
              fit: BoxFit.contain,
              cacheWidth: cacheWidth,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const Center(
                child: Icon(Icons.broken_image, color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
