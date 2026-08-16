class CameraZoom {
  const CameraZoom({
    required this.min,
    required this.max,
    required this.current,
  });

  static const unset = CameraZoom(min: 1, max: 1, current: 1);
  static const userMax = 5.0;
  static const presets = <double>[1, 2, 3, 4, 5];

  factory CameraZoom.fromDevice({
    required double min,
    required double max,
  }) {
    final cappedMax = cameraZoomCap(deviceMax: max, min: min);
    return CameraZoom(min: min, max: cappedMax, current: min);
  }

  final double min;
  final double max;
  final double current;

  bool get canZoom => max > min + 0.05;

  List<double> get availablePresets =>
      availableZoomPresets(min: min, max: max);

  String get label {
    if ((current - current.roundToDouble()).abs() < 0.05) {
      return '${current.round()}x';
    }
    return '${current.toStringAsFixed(1)}x';
  }

  CameraZoom copyWith({double? min, double? max, double? current}) {
    return CameraZoom(
      min: min ?? this.min,
      max: max ?? this.max,
      current: current ?? this.current,
    );
  }
}

double cameraZoomCap({required double deviceMax, required double min}) {
  final capped = deviceMax < CameraZoom.userMax ? deviceMax : CameraZoom.userMax;
  return capped < min ? min : capped;
}

List<double> availableZoomPresets({
  required double min,
  required double max,
}) {
  return CameraZoom.presets
      .where((zoom) => zoom + 0.01 >= min && zoom - 0.01 <= max)
      .toList(growable: false);
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
