import 'dart:convert';
import 'dart:io';

import '../models/comparison_pair.dart';
import 'clip_repository.dart';

class ComparisonPairRepository {
  ComparisonPairRepository(this._clipRepository);

  static const _version = 1;
  final ClipRepository _clipRepository;

  Future<File> get _file async =>
      File(await _clipRepository.resolveAbsolutePath('comparison_pairs.json'));

  Future<List<ComparisonPairSettings>> loadAll() async {
    final file = await _file;
    if (!await file.exists()) return <ComparisonPairSettings>[];
    try {
      final json = Map<String, dynamic>.from(
        jsonDecode(await file.readAsString()) as Map<dynamic, dynamic>,
      );
      if (json['version'] != _version) throw const FormatException('version');
      return (json['pairs'] as List<dynamic>)
          .map(
            (item) => ComparisonPairSettings.fromJson(
              Map<String, dynamic>.from(item as Map<dynamic, dynamic>),
            ),
          )
          .toList(growable: false);
    } on Object {
      await _preserveBroken(file);
      return <ComparisonPairSettings>[];
    }
  }

  Future<ComparisonPairSettings?> loadPair(
    String firstClipId,
    String secondClipId, {
    required Map<String, ComparisonClipRange> currentRanges,
  }) async {
    final pairs = await loadAll();
    final key = ComparisonPairSettings.keyFor(firstClipId, secondClipId);
    ComparisonPairSettings? found;
    for (final pair in pairs) {
      if (pair.key == key) found = pair;
    }
    if (found == null) return null;
    final valid =
        !found.hasSynchronizedReference ||
        found.clipIds.every((id) {
          final range = currentRanges[id];
          final reference = found!.referenceTimesMs[id];
          return range != null &&
              reference != null &&
              range.contains(reference);
        });
    if (valid) return found;
    await _saveAll(
      pairs.where((pair) => pair.key != key).toList(growable: false),
    );
    return null;
  }

  Future<void> savePair(ComparisonPairSettings settings) async {
    final pairs = await loadAll();
    await _saveAll(<ComparisonPairSettings>[
      ...pairs.where((pair) => pair.key != settings.key),
      settings,
    ]);
  }

  Future<void> deletePairsContaining(String clipId) async {
    final pairs = await loadAll();
    final remaining = pairs
        .where((pair) => !pair.containsClip(clipId))
        .toList(growable: false);
    if (remaining.length != pairs.length) await _saveAll(remaining);
  }

  Future<void> _saveAll(List<ComparisonPairSettings> pairs) async {
    final file = await _file;
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsString(
        jsonEncode(<String, Object>{
          'version': _version,
          'pairs': pairs.map((pair) => pair.toJson()).toList(growable: false),
        }),
        flush: true,
      );
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _preserveBroken(File file) async {
    var path = '${file.path}.broken';
    var suffix = 1;
    while (await File(path).exists()) {
      path = '${file.path}.broken.$suffix';
      suffix += 1;
    }
    await file.rename(path);
  }
}
