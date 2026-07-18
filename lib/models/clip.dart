class Clip {
  const Clip({
    required this.id,
    required this.videoPath,
    required this.thumbnailPath,
    required this.recordedAt,
    required this.durationMs,
    required this.memo,
    this.isBroken = false,
    this.validationError,
    this.trimStartMs,
    this.trimEndMs,
  });

  final String id;
  final String videoPath;
  final String? thumbnailPath;
  final DateTime recordedAt;
  final int durationMs;
  final String? memo;
  final bool isBroken;
  final String? validationError;
  final int? trimStartMs;
  final int? trimEndMs;

  bool get hasComparisonRange => trimStartMs != null && trimEndMs != null;

  int? get comparisonRangeDurationMs =>
      hasComparisonRange ? trimEndMs! - trimStartMs! : null;

  factory Clip.fromJson(Map<String, dynamic> json) {
    final clip = Clip(
      id: json['id'] as String,
      videoPath: json['videoPath'] as String,
      thumbnailPath: json['thumbnailPath'] as String?,
      recordedAt: DateTime.parse(json['recordedAt'] as String),
      durationMs: json['durationMs'] as int,
      memo: json['memo'] as String?,
      isBroken: json['isBroken'] as bool? ?? false,
      validationError: json['validationError'] as String?,
      trimStartMs: json['trimStartMs'] as int?,
      trimEndMs: json['trimEndMs'] as int?,
    );
    clip.validateComparisonRange();
    return clip;
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'videoPath': videoPath,
      'thumbnailPath': thumbnailPath,
      'recordedAt': recordedAt.toIso8601String(),
      'durationMs': durationMs,
      'memo': memo,
      'isBroken': isBroken,
      'validationError': validationError,
      'trimStartMs': trimStartMs,
      'trimEndMs': trimEndMs,
    };
  }

  Clip withMemo(String? value) {
    return Clip(
      id: id,
      videoPath: videoPath,
      thumbnailPath: thumbnailPath,
      recordedAt: recordedAt,
      durationMs: durationMs,
      memo: value,
      isBroken: isBroken,
      validationError: validationError,
      trimStartMs: trimStartMs,
      trimEndMs: trimEndMs,
    );
  }

  Clip withMetadata({
    required int durationMs,
    required String? thumbnailPath,
    required bool isBroken,
    String? validationError,
  }) {
    return Clip(
      id: id,
      videoPath: videoPath,
      thumbnailPath: thumbnailPath,
      recordedAt: recordedAt,
      durationMs: durationMs,
      memo: memo,
      isBroken: isBroken,
      validationError: validationError,
      trimStartMs: trimStartMs,
      trimEndMs: trimEndMs,
    );
  }

  Clip withComparisonRange({required int? startMs, required int? endMs}) {
    final updated = Clip(
      id: id,
      videoPath: videoPath,
      thumbnailPath: thumbnailPath,
      recordedAt: recordedAt,
      durationMs: durationMs,
      memo: memo,
      isBroken: isBroken,
      validationError: validationError,
      trimStartMs: startMs,
      trimEndMs: endMs,
    );
    updated.validateComparisonRange();
    return updated;
  }

  void validateComparisonRange() {
    if (trimStartMs == null && trimEndMs == null) {
      return;
    }
    if (trimStartMs == null || trimEndMs == null) {
      throw ArgumentError('Comparison range requires both start and end.');
    }
    if (trimStartMs! < 0 ||
        trimStartMs! >= trimEndMs! ||
        trimEndMs! > durationMs ||
        trimEndMs! - trimStartMs! > 10000) {
      throw ArgumentError('Invalid comparison range.');
    }
  }

  @override
  bool operator ==(Object other) {
    return other is Clip &&
        other.id == id &&
        other.videoPath == videoPath &&
        other.thumbnailPath == thumbnailPath &&
        other.recordedAt == recordedAt &&
        other.durationMs == durationMs &&
        other.memo == memo &&
        other.isBroken == isBroken &&
        other.validationError == validationError &&
        other.trimStartMs == trimStartMs &&
        other.trimEndMs == trimEndMs;
  }

  @override
  int get hashCode => Object.hash(
    id,
    videoPath,
    thumbnailPath,
    recordedAt,
    durationMs,
    memo,
    isBroken,
    validationError,
    trimStartMs,
    trimEndMs,
  );
}
