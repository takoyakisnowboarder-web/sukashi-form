import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sukashi_form/data/clip_repository.dart';
import 'package:sukashi_form/data/comparison_pair_repository.dart';
import 'package:sukashi_form/data/frame_cache_service.dart';
import 'package:sukashi_form/models/clip.dart';
import 'package:sukashi_form/models/comparison_pair.dart';
import 'package:sukashi_form/providers/clip_providers.dart';
import 'package:sukashi_form/screens/compare_screen.dart';

void main() {
  late Directory directory;
  late ClipRepository clipRepository;
  late ComparisonPairRepository pairRepository;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('compare_screen_');
    clipRepository = ClipRepository(
      documentsDirectoryProvider: () async => directory,
    );
    pairRepository = _MemoryPairRepository(clipRepository);
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  testWidgets('10秒超で範囲未設定なら範囲選択へ誘導する', (tester) async {
    final clips = <Clip>[_clip('a', 15000), _clip('b', 5000)];
    await _pump(
      tester,
      clips,
      (_) => _completedSession(),
      clipRepository,
      pairRepository,
    );
    expect(find.text('比較範囲が必要です'), findsOneWidget);
    expect(find.text('このクリップは10秒を超えています。比較範囲を選択してください。'), findsOneWidget);
    expect(find.text('範囲を選択'), findsOneWidget);
  });

  testWidgets('展開進捗を1/2本目形式で表示する', (tester) async {
    final progress = StreamController<FrameExtractionProgress>.broadcast();
    final pending = Completer<FrameCacheResult>();
    final session = FrameExtractionSession(
      taskId: 'pending',
      progress: progress.stream,
      result: pending.future,
      onCancel: () async {},
    );
    await _pump(
      tester,
      <Clip>[_clip('a', 5000), _clip('b', 5000)],
      (_) => session,
      clipRepository,
      pairRepository,
    );
    progress.add(
      const FrameExtractionProgress(
        taskId: 'pending',
        completedFrames: 7,
        totalFrames: 30,
      ),
    );
    await tester.pump();
    expect(find.text('1/2本目: 7/30 フレーム'), findsOneWidget);
    await progress.close();
  });

  testWidgets('基準設定の途中キャンセルで元の同期状態へ戻る', (tester) async {
    var extractionCalls = 0;
    await _pump(
      tester,
      <Clip>[_clip('a', 5000), _clip('b', 5000)],
      (_) {
        extractionCalls += 1;
        return _completedSession();
      },
      clipRepository,
      pairRepository,
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await _pumpFrames(tester, 20);
    await tester.drag(
      find.byKey(const Key('comparison-scroll')),
      const Offset(0, -1000),
    );
    await tester.pump();
    expect(extractionCalls, 2);
    expect(
      find.text('先頭を基準に同期'),
      findsOneWidget,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((widget) => widget.data)
          .toList()
          .toString(),
    );

    await tester.tap(find.byKey(const Key('start-reference')));
    await tester.pump();
    expect(find.text('ステップ1: Aの基準を選択'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-reference')));
    await tester.pump();
    expect(find.text('ステップ2: Bの基準を選択'), findsOneWidget);
    await tester.tap(find.byKey(const Key('cancel-reference')));
    await tester.pump();

    expect(find.text('先頭を基準に同期'), findsOneWidget);
    expect(await pairRepository.loadAll(), isEmpty);
  });
}

Future<void> _pump(
  WidgetTester tester,
  List<Clip> clips,
  FrameExtractionSession Function(Clip) starter,
  ClipRepository clipRepository,
  ComparisonPairRepository pairRepository,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        clipRepositoryProvider.overrideWithValue(clipRepository),
        comparisonPairRepositoryProvider.overrideWithValue(pairRepository),
        clipListProvider.overrideWith(() => _TestClipListNotifier(clips)),
        comparisonExtractionStarterProvider.overrideWithValue(starter),
      ],
      child: const MaterialApp(
        home: CompareScreen(clipIds: <String>['a', 'b']),
      ),
    ),
  );
  await _pumpFrames(tester, 10);
}

Future<void> _pumpFrames(WidgetTester tester, int count) async {
  for (var index = 0; index < count; index++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

FrameExtractionSession _completedSession() => FrameExtractionSession(
  taskId: 'done',
  progress: const Stream<FrameExtractionProgress>.empty(),
  result: Future<FrameCacheResult>.value(
    const FrameCacheResult(
      isComplete: true,
      frameCount: 3,
      sourceDurationMs: 5000,
      sourceFps: 30,
      absoluteFramePaths: <String>[
        'missing_0.jpg',
        'missing_1.jpg',
        'missing_2.jpg',
      ],
      fromCache: true,
    ),
  ),
  onCancel: () async {},
);

class _TestClipListNotifier extends ClipListNotifier {
  _TestClipListNotifier(this.clips);
  final List<Clip> clips;
  @override
  Future<List<Clip>> build() async => clips;
}

class _MemoryPairRepository extends ComparisonPairRepository {
  _MemoryPairRepository(super.clipRepository);

  final List<ComparisonPairSettings> pairs = <ComparisonPairSettings>[];

  @override
  Future<List<ComparisonPairSettings>> loadAll() async => List.of(pairs);

  @override
  Future<ComparisonPairSettings?> loadPair(
    String firstClipId,
    String secondClipId, {
    required Map<String, ComparisonClipRange> currentRanges,
  }) async {
    final key = ComparisonPairSettings.keyFor(firstClipId, secondClipId);
    for (final pair in pairs) {
      if (pair.key == key) return pair;
    }
    return null;
  }

  @override
  Future<void> savePair(ComparisonPairSettings settings) async {
    pairs
      ..removeWhere((pair) => pair.key == settings.key)
      ..add(settings);
  }
}

Clip _clip(String id, int durationMs) => Clip(
  id: id,
  videoPath: 'videos/$id.mp4',
  thumbnailPath: null,
  recordedAt: DateTime.utc(2026, 7, 19),
  durationMs: durationMs,
  memo: null,
);
