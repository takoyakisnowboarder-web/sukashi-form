import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sukashi_form/data/clip_repository.dart';
import 'package:sukashi_form/models/clip.dart';

void main() {
  late Directory temporaryDirectory;
  late ClipRepository repository;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'sukashi_form_test_',
    );
    repository = ClipRepository(
      documentsDirectoryProvider: () async => temporaryDirectory,
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('保存したクリップを同じ内容で読み込める', () async {
    final clips = <Clip>[
      Clip(
        id: 'clip-1',
        videoPath: 'videos/clip-1.mp4',
        thumbnailPath: 'thumbnails/clip-1.jpg',
        recordedAt: DateTime.utc(2026, 7, 17, 9, 30),
        durationMs: 3120,
        memo: '調子○',
      ),
    ];

    await repository.saveClips(clips);

    expect(await repository.loadClips(), clips);
    expect(
      await File('${temporaryDirectory.path}/clips.json.tmp').exists(),
      isFalse,
    );
  });

  test('削除は一覧・動画・サムネイル・フレームキャッシュのすべてに反映される', () async {
    final video = File('${temporaryDirectory.path}/videos/clip-1.mp4');
    final thumbnail = File('${temporaryDirectory.path}/thumbnails/clip-1.jpg');
    await video.parent.create(recursive: true);
    await thumbnail.parent.create(recursive: true);
    await video.writeAsString('video');
    await thumbnail.writeAsString('thumbnail');
    final cachedFrame = File(
      '${temporaryDirectory.path}/frames/clip-1/frame_000000.jpg',
    );
    await cachedFrame.parent.create(recursive: true);
    await cachedFrame.writeAsString('frame');
    final previewFrame = File(
      '${temporaryDirectory.path}/frames_preview/clip-1/frame_000000.jpg',
    );
    await previewFrame.parent.create(recursive: true);
    await previewFrame.writeAsString('preview');
    final clips = <Clip>[
      Clip(
        id: 'clip-1',
        videoPath: 'videos/clip-1.mp4',
        thumbnailPath: 'thumbnails/clip-1.jpg',
        recordedAt: DateTime.utc(2026, 7, 17),
        durationMs: 1000,
        memo: null,
      ),
    ];
    await repository.saveClips(clips);

    await repository.deleteClip('clip-1', clips);

    expect(await repository.loadClips(), isEmpty);
    expect(await video.exists(), isFalse);
    expect(await thumbnail.exists(), isFalse);
    expect(await cachedFrame.parent.exists(), isFalse);
    expect(await previewFrame.parent.exists(), isFalse);
  });

  test('壊れたJSONは.brokenへ残し空リストで復帰する', () async {
    final clipsFile = File('${temporaryDirectory.path}/clips.json');
    await clipsFile.writeAsString('{broken json');

    expect(await repository.loadClips(), isEmpty);
    expect(await clipsFile.exists(), isFalse);
    expect(
      await File('${temporaryDirectory.path}/clips.json.broken').exists(),
      isTrue,
    );
  });

  test('相対パスと絶対パスを相互変換できる', () async {
    const relative = 'videos/example.mp4';

    final absolute = await repository.resolveAbsolutePath(relative);

    expect(
      absolute,
      '${temporaryDirectory.path}${Platform.pathSeparator}videos'
      '${Platform.pathSeparator}example.mp4',
    );
    expect(await repository.toRelativePath(absolute), relative);
  });

  test('アプリ領域外の絶対パスは相対パスに変換しない', () async {
    expect(
      () =>
          repository.toRelativePath('${temporaryDirectory.parent.path}/x.mp4'),
      throwsArgumentError,
    );
  });

  test('新しい破損フィールドがない旧clips.jsonを後方互換で読める', () async {
    final clipsFile = File('${temporaryDirectory.path}/clips.json');
    await clipsFile.writeAsString(
      jsonEncode(<Map<String, Object?>>[
        <String, Object?>{
          'id': 'legacy',
          'videoPath': 'videos/legacy.mp4',
          'thumbnailPath': null,
          'recordedAt': '2026-07-17T00:00:00.000Z',
          'durationMs': 1000,
          'memo': null,
        },
      ]),
    );

    final loaded = await repository.loadClips();

    expect(loaded.single.id, 'legacy');
    expect(loaded.single.isBroken, isFalse);
    expect(loaded.single.validationError, isNull);
  });
}
