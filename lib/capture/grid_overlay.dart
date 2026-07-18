import 'package:flutter/material.dart';

import '../models/app_settings.dart';

class GridPattern {
  const GridPattern({required this.vertical, required this.horizontal});

  final List<double> vertical;
  final List<double> horizontal;
}

extension CameraGridPattern on CameraGridType {
  GridPattern get pattern {
    switch (this) {
      case CameraGridType.none:
        return const GridPattern(vertical: <double>[], horizontal: <double>[]);
      case CameraGridType.grid3x3:
        return const GridPattern(
          vertical: <double>[1 / 3, 2 / 3],
          horizontal: <double>[1 / 3, 2 / 3],
        );
      case CameraGridType.grid4x4:
        return const GridPattern(
          vertical: <double>[0.25, 0.5, 0.75],
          horizontal: <double>[0.25, 0.5, 0.75],
        );
      case CameraGridType.cross:
        return const GridPattern(
          vertical: <double>[0.5],
          horizontal: <double>[0.5],
        );
      case CameraGridType.thirds:
        return const GridPattern(
          vertical: <double>[],
          horizontal: <double>[1 / 3, 2 / 3],
        );
    }
  }
}

class GridOverlay extends StatelessWidget {
  const GridOverlay({required this.gridType, super.key});

  final CameraGridType gridType;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(painter: GridOverlayPainter(gridType)),
    );
  }
}

class GridOverlayPainter extends CustomPainter {
  const GridOverlayPainter(this.gridType);

  final CameraGridType gridType;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.62)
      ..strokeWidth = 1.2;
    final pattern = gridType.pattern;
    for (final fraction in pattern.vertical) {
      final x = size.width * fraction;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (final fraction in pattern.horizontal) {
      final y = size.height * fraction;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant GridOverlayPainter oldDelegate) {
    return oldDelegate.gridType != gridType;
  }
}
