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
  });

  final String id;
  final String videoPath;
  final String? thumbnailPath;
  final DateTime recordedAt;
  final int durationMs;
  final String? memo;
  final bool isBroken;
  final String? validationError;

  factory Clip.fromJson(Map<String, dynamic> json) {
    return Clip(
      id: json['id'] as String,
      videoPath: json['videoPath'] as String,
      thumbnailPath: json['thumbnailPath'] as String?,
      recordedAt: DateTime.parse(json['recordedAt'] as String),
      durationMs: json['durationMs'] as int,
      memo: json['memo'] as String?,
      isBroken: json['isBroken'] as bool? ?? false,
      validationError: json['validationError'] as String?,
    );
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
    );
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
        other.validationError == validationError;
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
  );
}
