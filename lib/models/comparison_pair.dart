import '../comparison/comparison_controller.dart';

class ComparisonClipRange {
  const ComparisonClipRange({required this.startMs, required this.endMs});
  final double startMs;
  final double endMs;
  bool contains(double value) => value >= startMs && value <= endMs;
}

class ComparisonPairSettings {
  ComparisonPairSettings({
    required String firstClipId,
    required String secondClipId,
    required Map<String, double> referenceTimesMs,
    required Map<String, AlignmentTransform> transforms,
  }) : clipIds = (List<String>.of(<String>[firstClipId, secondClipId])..sort()),
       referenceTimesMs = Map<String, double>.unmodifiable(referenceTimesMs),
       transforms = Map<String, AlignmentTransform>.unmodifiable(transforms) {
    if (firstClipId == secondClipId ||
        !referenceTimesMs.keys.toSet().containsAll(clipIds) ||
        !transforms.keys.toSet().containsAll(clipIds)) {
      throw ArgumentError('Pair settings require two distinct clips.');
    }
  }

  final List<String> clipIds;
  final Map<String, double> referenceTimesMs;
  final Map<String, AlignmentTransform> transforms;

  String get key => keyFor(clipIds[0], clipIds[1]);
  bool containsClip(String clipId) => clipIds.contains(clipId);

  Map<String, Object> toJson() => <String, Object>{
    'clipIds': clipIds,
    'referenceTimesMs': referenceTimesMs,
    'transforms': <String, Object>{
      for (final id in clipIds) id: transforms[id]!.toJson(),
    },
  };

  factory ComparisonPairSettings.fromJson(Map<String, dynamic> json) {
    final ids = (json['clipIds'] as List<dynamic>).cast<String>();
    if (ids.length != 2 || ids[0] == ids[1]) {
      throw const FormatException('Invalid comparison pair IDs.');
    }
    final references =
        Map<String, dynamic>.from(
          json['referenceTimesMs'] as Map<dynamic, dynamic>,
        ).map(
          (key, value) =>
              MapEntry<String, double>(key, (value as num).toDouble()),
        );
    final transformsJson = Map<String, dynamic>.from(
      json['transforms'] as Map<dynamic, dynamic>,
    );
    return ComparisonPairSettings(
      firstClipId: ids[0],
      secondClipId: ids[1],
      referenceTimesMs: references,
      transforms: <String, AlignmentTransform>{
        for (final id in ids)
          id: AlignmentTransform.fromJson(
            Map<String, dynamic>.from(
              transformsJson[id] as Map<dynamic, dynamic>,
            ),
          ),
      },
    );
  }

  static String keyFor(String first, String second) {
    final ids = <String>[first, second]..sort();
    return '${ids[0]}::${ids[1]}';
  }

  @override
  bool operator ==(Object other) =>
      other is ComparisonPairSettings &&
      other.key == key &&
      _mapEquals(other.referenceTimesMs, referenceTimesMs) &&
      _mapEquals(other.transforms, transforms);

  @override
  int get hashCode => Object.hash(
    key,
    Object.hashAll(clipIds.map((id) => referenceTimesMs[id])),
    Object.hashAll(clipIds.map((id) => transforms[id])),
  );
}

bool _mapEquals<K, V>(Map<K, V> a, Map<K, V> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
