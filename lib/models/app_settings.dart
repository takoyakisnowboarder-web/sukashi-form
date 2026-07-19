enum CameraGridType {
  none('なし'),
  grid3x3('格子3×3'),
  grid4x4('格子4×4'),
  cross('十字'),
  thirds('三分割');

  const CameraGridType(this.label);

  final String label;

  CameraGridType get next {
    return CameraGridType.values[(index + 1) % CameraGridType.values.length];
  }

  static CameraGridType fromName(Object? value) {
    return CameraGridType.values
            .where((item) => item.name == value)
            .firstOrNull ??
        CameraGridType.none;
  }
}

class AppSettings {
  const AppSettings({
    required this.gridType,
    required this.countdownSeconds,
    required this.recordingSeconds,
    required this.saveToGallery,
  });

  static const defaults = AppSettings(
    gridType: CameraGridType.none,
    countdownSeconds: 0,
    recordingSeconds: 10,
    saveToGallery: true,
  );

  static const countdownOptions = <int>[0, 3, 5, 10];
  static const recordingOptions = <int>[5, 10, 20, 30];

  final CameraGridType gridType;
  final int countdownSeconds;
  final int recordingSeconds;
  final bool saveToGallery;

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final countdown = json['countdownSeconds'];
    final recording = json['recordingSeconds'];
    return AppSettings(
      gridType: CameraGridType.fromName(json['gridType']),
      countdownSeconds: countdown is int && countdownOptions.contains(countdown)
          ? countdown
          : 0,
      recordingSeconds: recording is int && recordingOptions.contains(recording)
          ? recording
          : 10,
      saveToGallery: json['saveToGallery'] is bool
          ? json['saveToGallery'] as bool
          : true,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'gridType': gridType.name,
    'countdownSeconds': countdownSeconds,
    'recordingSeconds': recordingSeconds,
    'saveToGallery': saveToGallery,
  };

  AppSettings copyWith({
    CameraGridType? gridType,
    int? countdownSeconds,
    int? recordingSeconds,
    bool? saveToGallery,
  }) {
    return AppSettings(
      gridType: gridType ?? this.gridType,
      countdownSeconds: countdownSeconds ?? this.countdownSeconds,
      recordingSeconds: recordingSeconds ?? this.recordingSeconds,
      saveToGallery: saveToGallery ?? this.saveToGallery,
    );
  }

  int get nextCountdownSeconds {
    final index = countdownOptions.indexOf(countdownSeconds);
    return countdownOptions[(index + 1) % countdownOptions.length];
  }

  int get nextRecordingSeconds {
    final index = recordingOptions.indexOf(recordingSeconds);
    return recordingOptions[(index + 1) % recordingOptions.length];
  }

  @override
  bool operator ==(Object other) {
    return other is AppSettings &&
        other.gridType == gridType &&
        other.countdownSeconds == countdownSeconds &&
        other.recordingSeconds == recordingSeconds &&
        other.saveToGallery == saveToGallery;
  }

  @override
  int get hashCode =>
      Object.hash(gridType, countdownSeconds, recordingSeconds, saveToGallery);
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
