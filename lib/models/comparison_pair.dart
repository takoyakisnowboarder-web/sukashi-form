import '../comparison/comparison_controller.dart';
import 'app_settings.dart';

enum ComparisonSplitAxis { vertical, horizontal }

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
    this.hasSynchronizedReference = true,
    this.splitAxis = ComparisonSplitAxis.vertical,
    this.overlayOpacity = 0.5,
    this.gridType = CameraGridType.none,
  }) : clipIds = (List<String>.of(<String>[firstClipId, secondClipId])..sort()),
       referenceTimesMs = Map<String, double>.unmodifiable(referenceTimesMs),
       transforms = Map<String, AlignmentTransform>.unmodifiable(transforms) {
    if (firstClipId == secondClipId ||
        (hasSynchronizedReference &&
            !referenceTimesMs.keys.toSet().containsAll(clipIds)) ||
        !transforms.keys.toSet().containsAll(clipIds)) {
      throw ArgumentError('Pair settings require two distinct clips.');
    }
    if (!overlayOpacity.isFinite || overlayOpacity < 0 || overlayOpacity > 1) {
      throw ArgumentError.value(overlayOpacity, 'overlayOpacity');
    }
  }

  final List<String> clipIds;
  final Map<String, double> referenceTimesMs;
  final Map<String, AlignmentTransform> transforms;
  final bool hasSynchronizedReference;
  final ComparisonSplitAxis splitAxis;
  final double overlayOpacity;
  final CameraGridType gridType;

  String get key => keyFor(clipIds[0], clipIds[1]);
  bool containsClip(String clipId) => clipIds.contains(clipId);

  Map<String, Object> toJson() => <String, Object>{
    'clipIds': clipIds,
    'referenceTimesMs': referenceTimesMs,
    'hasSynchronizedReference': hasSynchronizedReference,
    'splitAxis': splitAxis.name,
    'overlayOpacity': overlayOpacity,
    'gridType': gridType.name,
    'transforms': <String, Object>{
      for (final id in clipIds) id: transforms[id]!.toJson(),
    },
  };

  factory ComparisonPairSettings.fromJson(Map<String, dynamic> json) {
    final ids = (json['clipIds'] as List<dynamic>).cast<String>();
    if (ids.length != 2 || ids[0] == ids[1]) {
      throw const FormatException('Invalid comparison pair IDs.');
    }
    final referencesJson = json['referenceTimesMs'];
    final references = referencesJson == null
        ? <String, double>{}
        : Map<String, dynamic>.from(
            referencesJson as Map<dynamic, dynamic>,
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
      // フェーズ4aの旧JSONにはこのフラグがなく、基準時刻2件を必ず持つ。
      hasSynchronizedReference:
          json['hasSynchronizedReference'] as bool? ?? true,
      splitAxis: ComparisonSplitAxis.values.byName(
        json['splitAxis'] as String? ?? ComparisonSplitAxis.vertical.name,
      ),
      overlayOpacity: (json['overlayOpacity'] as num?)?.toDouble() ?? 0.5,
      gridType: CameraGridType.fromName(json['gridType']),
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
      other.hasSynchronizedReference == hasSynchronizedReference &&
      other.splitAxis == splitAxis &&
      other.overlayOpacity == overlayOpacity &&
      other.gridType == gridType &&
      _mapEquals(other.referenceTimesMs, referenceTimesMs) &&
      _mapEquals(other.transforms, transforms);

  @override
  int get hashCode => Object.hash(
    key,
    hasSynchronizedReference,
    splitAxis,
    overlayOpacity,
    gridType,
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
