import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sukashi_form/data/clip_repository.dart';
import 'package:sukashi_form/models/clip.dart';
import 'package:sukashi_form/providers/clip_providers.dart';
import 'package:sukashi_form/screens/library_screen.dart';

void main() {
  late Directory appDirectory;
  late ClipRepository repository;

  setUp(() async {
    appDirectory = await Directory.systemTemp.createTemp('sukashi_library_');
    repository = ClipRepository(
      documentsDirectoryProvider: () async => appDirectory,
    );
  });

  tearDown(() async {
    if (await appDirectory.exists()) {
      await appDirectory.delete(recursive: true);
    }
  });

  testWidgets('durationMsが0のクリップをダッシュ表示できる', (tester) async {
    await _pumpLibrary(tester, repository, <Clip>[_clip()]);
    await tester.pump();

    expect(find.text('—'), findsOneWidget);
    expect(find.text('0.0秒'), findsNothing);
  });

  testWidgets('サムネイルなしでもプレースホルダ表示が崩れない', (tester) async {
    await _pumpLibrary(tester, repository, <Clip>[_clip()]);

    expect(find.byIcon(Icons.sports_gymnastics), findsOneWidget);
  });

  testWidgets('サムネイルありでは画像ウィジェットを表示する', (tester) async {
    await _pumpLibrary(tester, repository, <Clip>[
      _clip(
        id: 'with-thumbnail',
        thumbnailPath: 'thumbnails/with-thumbnail.jpg',
      ),
    ]);
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('thumbnail-with-thumbnail')),
      findsOneWidget,
    );
  });

  testWidgets('壊れたクリップを表示し比較選択には追加しない', (tester) async {
    await _pumpLibrary(tester, repository, <Clip>[
      _clip(id: 'broken', isBroken: true),
    ]);

    expect(find.text('この動画は読み込めません'), findsOneWidget);
    await tester.tap(find.text('この動画は読み込めません'));
    await tester.pump();

    expect(find.text('比較するクリップを2本選択 (0/2)'), findsOneWidget);
    expect(find.text('この動画は比較に使用できません。'), findsOneWidget);
    await tester.longPress(find.text('この動画は読み込めません'));
    await tester.pumpAndSettle();
    expect(find.text('比較範囲を選択'), findsNothing);
    expect(find.text('座標を保存'), findsNothing);
  });

  testWidgets('範囲設定済みクリップに選択範囲を表示する', (tester) async {
    await _pumpLibrary(tester, repository, <Clip>[
      _clip(
        id: 'ranged',
        durationMs: 30000,
        trimStartMs: 12000,
        trimEndMs: 17000,
      ),
    ]);

    expect(
      find.byKey(const ValueKey<String>('comparison-range-ranged')),
      findsOneWidget,
    );
    expect(find.text('5.0秒 / 全体30.0秒'), findsOneWidget);
  });

  testWidgets('長押しメニューは1本だけの座標保存を出す', (tester) async {
    await _pumpLibrary(tester, repository, <Clip>[
      _clip(id: 'solo', durationMs: 5000),
    ]);
    await tester.longPress(find.text('メモなし'));
    await tester.pumpAndSettle();
    expect(find.text('座標を保存'), findsOneWidget);
    expect(find.text('この1本だけをJSONで書き出します'), findsOneWidget);
  });
}

class _TestClipListNotifier extends ClipListNotifier {
  _TestClipListNotifier(this.clips);

  final List<Clip> clips;

  @override
  Future<List<Clip>> build() async => clips;
}

Future<void> _pumpLibrary(
  WidgetTester tester,
  ClipRepository repository,
  List<Clip> clips,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        clipRepositoryProvider.overrideWithValue(repository),
        clipListProvider.overrideWith(() => _TestClipListNotifier(clips)),
        thumbnailWidgetBuilderProvider.overrideWithValue(
          (path, key) => ColoredBox(key: key, color: Colors.blue),
        ),
        thumbnailAbsolutePathProvider.overrideWith(
          (ref, relativePath) async => relativePath,
        ),
      ],
      child: const MaterialApp(home: LibraryScreen()),
    ),
  );
  await tester.pump();
}

Clip _clip({
  String id = 'unknown-duration',
  String? thumbnailPath,
  bool isBroken = false,
  int durationMs = 0,
  int? trimStartMs,
  int? trimEndMs,
}) {
  return Clip(
    id: id,
    videoPath: 'videos/$id.mp4',
    thumbnailPath: thumbnailPath,
    recordedAt: DateTime(2026, 7, 17, 12),
    durationMs: durationMs,
    memo: null,
    isBroken: isBroken,
    validationError: isBroken ? 'empty_file' : null,
    trimStartMs: trimStartMs,
    trimEndMs: trimEndMs,
  );
}
