import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sukashi_form/data/clip_repository.dart';
import 'package:sukashi_form/models/clip.dart';
import 'package:sukashi_form/providers/clip_providers.dart';
import 'package:sukashi_form/screens/comparison_range_screen.dart';

void main() {
  late Directory directory;
  late ClipRepository repository;
  late Clip rangedClip;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('comparison_range_ui_');
    repository = ClipRepository(
      documentsDirectoryProvider: () async => directory,
    );
    rangedClip = _clip().withComparisonRange(startMs: 5000, endMs: 10000);
    await repository.saveClips(<Clip>[rangedClip]);
  });

  tearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  testWidgets('10秒を超える範囲では保存できない', (tester) async {
    await _pumpScreen(tester, repository, rangedClip);
    final slider = tester.widget<RangeSlider>(
      find.byKey(const Key('comparison-range-slider')),
    );

    slider.onChanged!(const RangeValues(0, 11000));
    await tester.pump();

    expect(find.byKey(const Key('range-validation-error')), findsOneWidget);
    final save = tester.widget<FilledButton>(
      find.byKey(const Key('save-comparison-range')),
    );
    expect(save.onPressed, isNull);
  });
}

Future<void> _pumpScreen(
  WidgetTester tester,
  ClipRepository repository,
  Clip clip,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        clipRepositoryProvider.overrideWithValue(repository),
        clipListProvider.overrideWith(
          () => _TestClipListNotifier(<Clip>[clip]),
        ),
      ],
      child: MaterialApp(
        home: ComparisonRangeScreen(
          clipId: clip.id,
          skipPreviewForTesting: true,
        ),
      ),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

class _TestClipListNotifier extends ClipListNotifier {
  _TestClipListNotifier(this.clips);

  final List<Clip> clips;

  @override
  Future<List<Clip>> build() async => clips;
}

Clip _clip() => Clip(
  id: 'clip',
  videoPath: 'videos/clip.mp4',
  thumbnailPath: null,
  recordedAt: DateTime.utc(2026, 7, 18),
  durationMs: 30000,
  memo: null,
);
