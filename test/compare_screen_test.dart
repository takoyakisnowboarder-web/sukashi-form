import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sukashi_form/capture/grid_overlay.dart';
import 'package:sukashi_form/comparison/comparison_controller.dart';
import 'package:sukashi_form/data/clip_repository.dart';
import 'package:sukashi_form/data/comparison_pair_repository.dart';
import 'package:sukashi_form/data/frame_cache_service.dart';
import 'package:sukashi_form/models/app_settings.dart';
import 'package:sukashi_form/models/clip.dart';
import 'package:sukashi_form/models/comparison_pair.dart';
import 'package:sukashi_form/pose/pose_analysis_service.dart';
import 'package:sukashi_form/pose/pose_detector_client.dart';
import 'package:sukashi_form/pose/pose_model.dart';
import 'package:sukashi_form/providers/clip_providers.dart';
import 'package:sukashi_form/providers/pose_providers.dart';
import 'package:sukashi_form/screens/compare_screen.dart';
import 'package:sukashi_form/widgets/comparison_frame_view.dart';

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
    expect(extractionCalls, 2);
    await _openSettings(tester);
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

    await _openSettings(tester);
    expect(find.text('先頭を基準に同期'), findsOneWidget);
    expect(await pairRepository.loadAll(), isEmpty);
  });

  testWidgets('変換を表示へ適用しcacheWidthでデコードする', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: ComparisonFrameView(
            clipId: 'a',
            path: 'missing.jpg',
            transform: AlignmentTransform(
              dx: 12,
              dy: -7,
              scale: 1.5,
              rotation: 0.25,
            ),
            cacheWidth: 640,
          ),
        ),
      ),
    );

    final translation = tester.widget<Transform>(
      find.byKey(const Key('frame-translation-a')),
    );
    final scale = tester.widget<Transform>(
      find.byKey(const Key('frame-scale-a')),
    );
    final rotation = tester.widget<Transform>(
      find.byKey(const Key('frame-rotation-a')),
    );
    expect(translation.transform.getTranslation().x, 12);
    expect(translation.transform.getTranslation().y, -7);
    expect(scale.transform.storage[0], 1.5);
    expect(rotation.transform.storage[0], closeTo(math.cos(0.25), 0.0001));
    final image = tester.widget<Image>(find.byKey(const Key('frame-image-a')));
    expect((image.image as ResizeImage).width, 640);
  });

  testWidgets('モード切替で時刻と変換を維持し透過と分割軸を保存する', (tester) async {
    await _pump(
      tester,
      <Clip>[_clip('a', 5000), _clip('b', 5000)],
      (_) => _completedSession(),
      clipRepository,
      pairRepository,
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await _pumpFrames(tester, 20);

    expect(find.byKey(const Key('overlay-view')), findsOneWidget);
    expect(find.byKey(const Key('overlay-opacity-slider')), findsNothing);
    expect(find.byKey(const Key('frame-number-A')), findsNothing);
    await tester.drag(
      find.byKey(const Key('comparison-seek')),
      const Offset(120, 0),
    );
    await tester.pump();
    final positionBefore = tester
        .widget<Slider>(find.byKey(const Key('comparison-seek')))
        .value;

    await _openSettings(tester);
    await tester.tap(find.byKey(const Key('alignment-mode-toggle')));
    await _pumpFrames(tester, 15);
    expect(find.byKey(const Key('comparison-seek')), findsNothing);
    expect(find.byKey(const Key('reset-alignment')), findsOneWidget);
    await tester.drag(
      find.byKey(const Key('alignment-gesture-area')),
      const Offset(24, 18),
    );
    await tester.pump();
    final translated = tester.widget<Transform>(
      find.byKey(const Key('frame-translation-b')),
    );
    expect(translated.transform.getTranslation().x, closeTo(24, 0.1));
    expect(translated.transform.getTranslation().y, closeTo(18, 0.1));
    await tester.tap(find.byKey(const Key('finish-alignment')));
    await tester.pump();

    await tester.tap(find.text('分割'));
    await tester.pump();
    expect(find.byKey(const Key('overlay-opacity-slider')), findsNothing);
    expect(find.byKey(const Key('split-axis-selector')), findsNothing);
    expect(
      tester.widget<Slider>(find.byKey(const Key('comparison-seek'))).value,
      positionBefore,
    );
    expect(
      tester
          .widget<Transform>(find.byKey(const Key('frame-translation-b')))
          .transform
          .getTranslation()
          .x,
      closeTo(24, 0.1),
    );

    await _openSettings(tester);
    expect(find.byKey(const Key('split-axis-selector')), findsOneWidget);
    await tester.tap(find.text('左右'));
    await tester.pump();
    await tester.tapAt(const Offset(10, 10));
    await _pumpFrames(tester, 15);
    expect(find.byKey(const Key('split-view-horizontal')), findsOneWidget);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    final saved = (await pairRepository.loadAll()).single;
    expect(saved.splitAxis, ComparisonSplitAxis.horizontal);
    expect(saved.overlayOpacity, 0.5);
    expect(saved.transforms['b']!.dx, closeTo(24, 0.1));
    expect(saved.hasSynchronizedReference, isFalse);
  });

  testWidgets('透過スライダーがBのOpacityへ反映される', (tester) async {
    await _pump(
      tester,
      <Clip>[_clip('a', 5000), _clip('b', 5000)],
      (_) => _completedSession(),
      clipRepository,
      pairRepository,
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await _pumpFrames(tester, 20);
    await _openSettings(tester);
    await tester.drag(
      find.byKey(const Key('overlay-opacity-slider')),
      const Offset(1000, 0),
    );
    await tester.pump();
    expect(
      tester
          .widget<Opacity>(find.byKey(const Key('overlay-b-opacity')))
          .opacity,
      1,
    );
  });

  testWidgets('位置合わせリセットで対象Bを恒等変換に戻して保存する', (tester) async {
    await _pump(
      tester,
      <Clip>[_clip('a', 5000), _clip('b', 5000)],
      (_) => _completedSession(),
      clipRepository,
      pairRepository,
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await _pumpFrames(tester, 20);
    await _openSettings(tester);
    await tester.tap(find.byKey(const Key('alignment-mode-toggle')));
    await _pumpFrames(tester, 15);
    await tester.drag(
      find.byKey(const Key('alignment-gesture-area')),
      const Offset(30, -20),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('reset-alignment')));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );

    final transform = tester.widget<Transform>(
      find.byKey(const Key('frame-translation-b')),
    );
    expect(transform.transform.getTranslation().x, 0);
    expect(transform.transform.getTranslation().y, 0);
    expect(
      (await pairRepository.loadAll()).single.transforms['b'],
      const AlignmentTransform(),
    );
  });

  testWidgets('2ポインタ操作でBを拡大縮小・回転する', (tester) async {
    await _pump(
      tester,
      <Clip>[_clip('a', 5000), _clip('b', 5000)],
      (_) => _completedSession(),
      clipRepository,
      pairRepository,
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await _pumpFrames(tester, 20);
    await _openSettings(tester);
    await tester.tap(find.byKey(const Key('alignment-mode-toggle')));
    await _pumpFrames(tester, 15);

    final area = find.byKey(const Key('alignment-gesture-area'));
    final center = tester.getCenter(area);
    final first = await tester.startGesture(
      center + const Offset(-30, 0),
      pointer: 1,
    );
    final second = await tester.startGesture(
      center + const Offset(30, 0),
      pointer: 2,
    );
    await tester.pump();
    await first.moveTo(center + const Offset(-60, -30));
    await second.moveTo(center + const Offset(60, 30));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pump();

    final scale = tester.widget<Transform>(
      find.byKey(const Key('frame-scale-b')),
    );
    final rotation = tester.widget<Transform>(
      find.byKey(const Key('frame-rotation-b')),
    );
    expect(scale.transform.storage[0], greaterThan(1));
    expect(rotation.transform.storage[1].abs(), greaterThan(0.1));
  });

  testWidgets('設定シートの開閉だけでは再生位置と変換が変わらない', (tester) async {
    await _pump(
      tester,
      <Clip>[_clip('a', 5000), _clip('b', 5000)],
      (_) => _completedSession(),
      clipRepository,
      pairRepository,
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await _pumpFrames(tester, 20);
    await tester.drag(
      find.byKey(const Key('comparison-seek')),
      const Offset(90, 0),
    );
    await tester.pump();
    final before = tester
        .widget<Slider>(find.byKey(const Key('comparison-seek')))
        .value;

    await _openSettings(tester);
    expect(find.byKey(const Key('comparison-settings-sheet')), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await _pumpFrames(tester, 15);

    expect(
      tester.widget<Slider>(find.byKey(const Key('comparison-seek'))).value,
      before,
    );
    expect(
      tester
          .widget<Transform>(find.byKey(const Key('frame-translation-b')))
          .transform
          .getTranslation()
          .x,
      0,
    );
  });

  testWidgets('分割位置合わせでは触ったAだけが動く', (tester) async {
    await _pump(
      tester,
      <Clip>[_clip('a', 5000), _clip('b', 5000)],
      (_) => _completedSession(),
      clipRepository,
      pairRepository,
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await _pumpFrames(tester, 20);
    await tester.tap(find.text('分割'));
    await tester.pump();
    await _openSettings(tester);
    await tester.tap(find.byKey(const Key('alignment-mode-toggle')));
    await _pumpFrames(tester, 15);

    final area = find.byKey(const Key('alignment-gesture-area'));
    final topHalf = tester.getTopLeft(area) + const Offset(80, 100);
    final gesture = await tester.startGesture(topHalf);
    await gesture.moveBy(const Offset(22, 14));
    await gesture.up();
    await tester.pump();

    expect(
      tester
          .widget<Transform>(find.byKey(const Key('frame-translation-a')))
          .transform
          .getTranslation()
          .x,
      closeTo(22, 0.1),
    );
    expect(
      tester
          .widget<Transform>(find.byKey(const Key('frame-translation-b')))
          .transform
          .getTranslation()
          .x,
      0,
    );
  });

  testWidgets('透過の操作対象は設定シートでAへ切り替えられる', (tester) async {
    await _pump(
      tester,
      <Clip>[_clip('a', 5000), _clip('b', 5000)],
      (_) => _completedSession(),
      clipRepository,
      pairRepository,
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await _pumpFrames(tester, 20);

    await _openSettings(tester);
    final targetA = find.descendant(
      of: find.byKey(const Key('alignment-target-settings')),
      matching: find.text('A'),
    );
    expect(targetA, findsOneWidget);
    await tester.tap(targetA);
    await tester.pump();
    await tester.tap(find.byKey(const Key('alignment-mode-toggle')));
    await _pumpFrames(tester, 15);

    expect(find.byKey(const Key('alignment-target-selector')), findsNothing);
    await tester.drag(
      find.byKey(const Key('alignment-gesture-area')),
      const Offset(24, 18),
    );
    await tester.pump();
    expect(
      tester
          .widget<Transform>(find.byKey(const Key('frame-translation-a')))
          .transform
          .getTranslation()
          .x,
      closeTo(24, 0.1),
    );
    expect(
      tester
          .widget<Transform>(find.byKey(const Key('frame-translation-b')))
          .transform
          .getTranslation()
          .x,
      0,
    );
  });

  testWidgets('位置合わせ中も設定から透過の操作対象を切り替えられる', (tester) async {
    await _pump(
      tester,
      <Clip>[_clip('a', 5000), _clip('b', 5000)],
      (_) => _completedSession(),
      clipRepository,
      pairRepository,
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await _pumpFrames(tester, 20);

    await _openSettings(tester);
    await tester.tap(find.byKey(const Key('alignment-mode-toggle')));
    await _pumpFrames(tester, 15);
    await _openSettings(tester);
    final targetA = find.descendant(
      of: find.byKey(const Key('alignment-target-settings')),
      matching: find.text('A'),
    );
    await tester.tap(targetA);
    await tester.pump();
    await tester.tapAt(const Offset(10, 10));
    await _pumpFrames(tester, 15);

    await tester.drag(
      find.byKey(const Key('alignment-gesture-area')),
      const Offset(20, 12),
    );
    await tester.pump();
    expect(
      tester
          .widget<Transform>(find.byKey(const Key('frame-translation-a')))
          .transform
          .getTranslation()
          .x,
      closeTo(20, 0.1),
    );
    expect(
      tester
          .widget<Transform>(find.byKey(const Key('frame-translation-b')))
          .transform
          .getTranslation()
          .x,
      0,
    );
  });

  testWidgets('比較グリッドは設定シートでONと種類選択を保存する', (tester) async {
    await _pump(
      tester,
      <Clip>[_clip('a', 5000), _clip('b', 5000)],
      (_) => _completedSession(),
      clipRepository,
      pairRepository,
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await _pumpFrames(tester, 20);

    await _openSettings(tester);
    await tester.tap(find.byKey(const Key('comparison-grid-toggle')));
    await tester.pump();
    expect(find.byKey(const Key('comparison-grid-type-cross')), findsOneWidget);
    await tester.tap(find.byKey(const Key('comparison-grid-type-cross')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('alignment-mode-toggle')));
    await _pumpFrames(tester, 15);

    expect(find.byType(GridOverlay), findsOneWidget);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    expect(
      (await pairRepository.loadAll()).single.gridType,
      CameraGridType.cross,
    );
  });

  testWidgets('骨格表示をオンにすると角度と骨格オーバーレイが出る', (tester) async {
    final detector = _FakePoseDetector();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          clipRepositoryProvider.overrideWithValue(clipRepository),
          comparisonPairRepositoryProvider.overrideWithValue(pairRepository),
          clipListProvider.overrideWith(
            () => _TestClipListNotifier(<Clip>[
              _clip('a', 5000),
              _clip('b', 5000),
            ]),
          ),
          comparisonExtractionStarterProvider.overrideWithValue(
            (_) => _completedSession(),
          ),
          poseDetectorClientProvider.overrideWithValue(detector),
          poseAnalysisServiceProvider.overrideWithValue(
            PoseAnalysisService(detector, _MemoryPoseCache(clipRepository)),
          ),
        ],
        child: const MaterialApp(
          home: CompareScreen(clipIds: <String>['a', 'b']),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await _pumpFrames(tester, 20);

    await _openSettings(tester);
    await tester.ensureVisible(find.byKey(const Key('pose-overlay-toggle')));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('pose-overlay-toggle')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await _pumpFrames(tester, 20);

    expect(find.byKey(const Key('pose-angle-hud')), findsOneWidget);
    expect(find.textContaining('左膝'), findsWidgets);
    expect(find.byKey(const Key('pose-skeleton-a')), findsOneWidget);
    expect(find.byKey(const Key('pose-skeleton-b')), findsOneWidget);
  });
}

Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('comparison-settings')));
  await _pumpFrames(tester, 15);
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

class _MemoryPoseCache extends PoseCacheRepository {
  _MemoryPoseCache(super.clipRepository);

  final Map<String, Map<String, PoseFrame>> _store =
      <String, Map<String, PoseFrame>>{};

  @override
  Future<Map<String, PoseFrame>> load(String clipId) async {
    return Map<String, PoseFrame>.of(
      _store[clipId] ?? <String, PoseFrame>{},
    );
  }

  @override
  Future<void> save(String clipId, Map<String, PoseFrame> frames) async {
    _store[clipId] = Map<String, PoseFrame>.of(frames);
  }
}

class _FakePoseDetector implements PoseDetectorClient {
  @override
  bool get isSupported => true;

  @override
  Future<PoseFrame?> detect(String imagePath) async {
    return const PoseFrame(
      imageWidth: 100,
      imageHeight: 200,
      landmarks: <PoseJoint, PosePoint>{
        PoseJoint.leftHip: PosePoint(x: 0.4, y: 0.35, visibility: 1),
        PoseJoint.leftKnee: PosePoint(x: 0.4, y: 0.6, visibility: 1),
        PoseJoint.leftAnkle: PosePoint(x: 0.4, y: 0.85, visibility: 1),
        PoseJoint.rightHip: PosePoint(x: 0.6, y: 0.35, visibility: 1),
        PoseJoint.rightKnee: PosePoint(x: 0.6, y: 0.6, visibility: 1),
        PoseJoint.rightAnkle: PosePoint(x: 0.6, y: 0.85, visibility: 1),
        PoseJoint.leftShoulder: PosePoint(x: 0.4, y: 0.15, visibility: 1),
        PoseJoint.rightShoulder: PosePoint(x: 0.6, y: 0.15, visibility: 1),
        PoseJoint.leftHeel: PosePoint(x: 0.38, y: 0.9, visibility: 1),
        PoseJoint.leftFootIndex: PosePoint(x: 0.48, y: 0.9, visibility: 1),
        PoseJoint.rightHeel: PosePoint(x: 0.58, y: 0.9, visibility: 1),
        PoseJoint.rightFootIndex: PosePoint(x: 0.68, y: 0.9, visibility: 1),
        PoseJoint.nose: PosePoint(x: 0.5, y: 0.08, visibility: 1),
      },
    );
  }

  @override
  Future<void> close() async {}
}

Clip _clip(String id, int durationMs) => Clip(
  id: id,
  videoPath: 'videos/$id.mp4',
  thumbnailPath: null,
  recordedAt: DateTime.utc(2026, 7, 19),
  durationMs: durationMs,
  memo: null,
);
