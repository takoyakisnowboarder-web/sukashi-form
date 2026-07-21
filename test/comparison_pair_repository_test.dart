import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sukashi_form/comparison/comparison_controller.dart';
import 'package:sukashi_form/data/clip_repository.dart';
import 'package:sukashi_form/data/comparison_pair_repository.dart';
import 'package:sukashi_form/models/app_settings.dart';
import 'package:sukashi_form/models/comparison_pair.dart';
import 'package:sukashi_form/models/clip.dart';
import 'package:sukashi_form/providers/clip_providers.dart';

void main() {
  late Directory directory;
  late ComparisonPairRepository repository;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('comparison_pairs_');
    repository = ComparisonPairRepository(
      ClipRepository(documentsDirectoryProvider: () async => directory),
    );
  });
  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('保存と読込が往復一致しID順序を入れ替えても同じ設定を引く', () async {
    final pair = _pair();
    await repository.savePair(pair);
    final loaded = await repository.loadPair(
      'b',
      'a',
      currentRanges: _ranges(),
    );
    expect(loaded, pair);
    expect(
      await File('${directory.path}/comparison_pairs.json.tmp').exists(),
      isFalse,
    );
  });

  test('範囲外の基準時刻は破棄される', () async {
    await repository.savePair(_pair());
    final loaded = await repository.loadPair(
      'a',
      'b',
      currentRanges: <String, ComparisonClipRange>{
        'a': const ComparisonClipRange(startMs: 2000, endMs: 3000),
        'b': const ComparisonClipRange(startMs: 0, endMs: 5000),
      },
    );
    expect(loaded, isNull);
    expect(await repository.loadAll(), isEmpty);
  });

  test('クリップ削除でそのクリップを含む設定だけ消える', () async {
    await repository.savePair(_pair());
    await repository.savePair(
      ComparisonPairSettings(
        firstClipId: 'b',
        secondClipId: 'c',
        referenceTimesMs: const <String, double>{'b': 2000, 'c': 1000},
        transforms: const <String, AlignmentTransform>{
          'b': AlignmentTransform(),
          'c': AlignmentTransform(),
        },
      ),
    );
    await repository.deletePairsContaining('a');
    final remaining = await repository.loadAll();
    expect(remaining.single.key, ComparisonPairSettings.keyFor('b', 'c'));
  });

  test('ClipListNotifierのクリップ削除でもペア設定が消える', () async {
    final clipRepository = ClipRepository(
      documentsDirectoryProvider: () async => directory,
    );
    final pairRepository = ComparisonPairRepository(clipRepository);
    final video = File('${directory.path}/videos/a.mp4');
    await video.parent.create(recursive: true);
    await video.writeAsString('video');
    await clipRepository.markDebugSeeded();
    final clip = Clip(
      id: 'a',
      videoPath: 'videos/a.mp4',
      thumbnailPath: null,
      recordedAt: DateTime.utc(2026, 7, 19),
      durationMs: 5000,
      memo: null,
    );
    await clipRepository.saveClips(<Clip>[clip]);
    await pairRepository.savePair(_pair());
    final container = ProviderContainer(
      overrides: [
        clipRepositoryProvider.overrideWithValue(clipRepository),
        comparisonPairRepositoryProvider.overrideWithValue(pairRepository),
        clipListProvider.overrideWith(() => _PairDeletionNotifier(clip)),
      ],
    );
    addTearDown(container.dispose);
    await container.read(clipListProvider.future);

    await container.read(clipListProvider.notifier).delete('a');

    expect(await pairRepository.loadAll(), isEmpty);
  });

  test('壊れJSONはbrokenへ退避し既定復帰する', () async {
    final file = File('${directory.path}/comparison_pairs.json');
    await file.writeAsString('{broken');
    expect(await repository.loadAll(), isEmpty);
    expect(await File('${file.path}.broken').exists(), isTrue);
  });

  test('未同期でも変換・分割軸・透過率を保存して復元する', () async {
    final settings = ComparisonPairSettings(
      firstClipId: 'a',
      secondClipId: 'b',
      referenceTimesMs: const <String, double>{},
      transforms: const <String, AlignmentTransform>{
        'a': AlignmentTransform(),
        'b': AlignmentTransform(dx: 12, dy: -3, scale: 1.2, rotation: 0.1),
      },
      hasSynchronizedReference: false,
      splitAxis: ComparisonSplitAxis.horizontal,
      overlayOpacity: 0.75,
      gridType: CameraGridType.cross,
    );
    await repository.savePair(settings);

    final loaded = await repository.loadPair(
      'b',
      'a',
      currentRanges: <String, ComparisonClipRange>{
        'a': const ComparisonClipRange(startMs: 2000, endMs: 3000),
        'b': const ComparisonClipRange(startMs: 2000, endMs: 3000),
      },
    );

    expect(loaded, settings);
    expect(loaded!.hasSynchronizedReference, isFalse);
    expect(loaded.splitAxis, ComparisonSplitAxis.horizontal);
    expect(loaded.overlayOpacity, 0.75);
    expect(loaded.gridType, CameraGridType.cross);
  });

  test('フェーズ4a JSONは同期済み・上下・透過50%として後方互換で読む', () async {
    final file = File('${directory.path}/comparison_pairs.json');
    await file.writeAsString(
      '{"version":1,"pairs":[{'
      '"clipIds":["a","b"],'
      '"referenceTimesMs":{"a":1000,"b":2000},'
      '"transforms":{"a":{"dx":0,"dy":0,"scale":1,"rotation":0},'
      '"b":{"dx":0,"dy":0,"scale":1,"rotation":0}}}]}',
    );

    final loaded = (await repository.loadAll()).single;
    expect(loaded.hasSynchronizedReference, isTrue);
    expect(loaded.splitAxis, ComparisonSplitAxis.vertical);
    expect(loaded.overlayOpacity, 0.5);
  });
}

class _PairDeletionNotifier extends ClipListNotifier {
  _PairDeletionNotifier(this.clip);
  final Clip clip;
  @override
  Future<List<Clip>> build() async => <Clip>[clip];
}

ComparisonPairSettings _pair() => ComparisonPairSettings(
  firstClipId: 'a',
  secondClipId: 'b',
  referenceTimesMs: const <String, double>{'a': 1000, 'b': 2000},
  transforms: const <String, AlignmentTransform>{
    'a': AlignmentTransform(),
    'b': AlignmentTransform(dx: 2, dy: 3, scale: 1.1, rotation: 0.2),
  },
);

Map<String, ComparisonClipRange> _ranges() =>
    const <String, ComparisonClipRange>{
      'a': ComparisonClipRange(startMs: 0, endMs: 5000),
      'b': ComparisonClipRange(startMs: 0, endMs: 5000),
    };
