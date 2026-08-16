class CameraZoom {
  const CameraZoom({
    required this.min,
    required this.max,
    required this.current,
  });

  static const unset = CameraZoom(min: 1, max: 1, current: 1);

  final double min;
  final double max;
  final double current;

  bool get canZoom => max > min + 0.05;

  String get label => '${current.toStringAsFixed(1)}x';

  CameraZoom copyWith({double? min, double? max, double? current}) {
    return CameraZoom(
      min: min ?? this.min,
      max: max ?? this.max,
      current: current ?? this.current,
    );
  }
}

double zoomAfterPinch({
  required double startZoom,
  required double scale,
  required double min,
  required double max,
}) {
  if (max < min) {
    return min;
  }
  return (startZoom * scale).clamp(min, max);
}
