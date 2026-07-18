import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sukashi_form/data/clip_repository.dart';
import 'package:sukashi_form/data/video_metadata_service.dart';
import 'package:sukashi_form/models/clip.dart';
import 'package:sukashi_form/native/frame_extractor.g.dart';

void main() {
  late Directory appDirectory;
  late ClipRepository repository;
  late Clip clip;

  setUp(() async {
    appDirectory = await Directory.systemTemp.createTemp('sukashi_metadata_');
    repository = ClipRepository(
      documentsDirectoryProvider: () async => appDirectory,
    );
    clip = Clip(
      id: 'clip-1',
      videoPath: 'videos/clip-1.mp4',
      thumbnailPath: null,
      recordedAt: DateTime.utc(2026, 7, 17),
      durationMs: 0,
      memo: null,
    );
    final video = File(await repository.resolveAbsolutePath(clip.videoPath));
    await video.parent.create(recursive: true);
    await video.writeAsBytes(<int>[1, 2, 3]);
    await repository.saveClips(<Clip>[clip]);
  });

  tearDown(() async {
    if (await appDirectory.exists()) {
      await appDirectory.delete(recursive: true);
    }
  });

  test('probe成功で尺と相対サムネイルパスを更新して永続化する', () async {
    final fake = _FakeFrameExtractor();
    final service = VideoMetadataService(repository, frameExtractor: fake);

    final enriched = await service.enrichAndPersist(clip);

    expect(enriched.durationMs, 4321);
    expect(enriched.thumbnailPath, 'thumbnails/clip-1.jpg');
    expect(enriched.isBroken, isFalse);
    expect(await repository.loadClips(), <Clip>[enriched]);
    expect(
      fake.probedPath,
      await repository.resolveAbsolutePath(clip.videoPath),
    );
    expect(
      fake.thumbnailOutputPath,
      await repository.resolveAbsolutePath('thumbnails/clip-1.jpg'),
    );
  });

  test('probe失敗は壊れ扱いで永続化し動画を自動削除しない', () async {
    final fake = _FakeFrameExtractor(valid: false);
    final service = VideoMetadataService(repository, frameExtractor: fake);

    final enriched = await service.enrichAndPersist(clip);

    expect(enriched.isBroken, isTrue);
    expect(enriched.validationError, 'empty_file');
    expect((await repository.loadClips()).single, enriched);
    expect(
      await File(await repository.resolveAbsolutePath(clip.videoPath)).exists(),
      isTrue,
    );
    expect(fake.thumbnailCalls, 0);
  });

  test('サムネイルと尺が既にあるクリップは穴埋めを再実行しない', () async {
    final complete = clip.withMetadata(
      durationMs: 1000,
      thumbnailPath: 'thumbnails/clip-1.jpg',
      isBroken: false,
    );
    await repository.saveClips(<Clip>[complete]);
    final fake = _FakeFrameExtractor();
    final service = VideoMetadataService(repository, frameExtractor: fake);

    expect(await service.enrichAndPersist(complete), complete);
    expect(fake.probeCalls, 0);
    expect(fake.thumbnailCalls, 0);
  });

  test('同じクリップの穴埋めを多重起動しない', () async {
    final fake = _FakeFrameExtractor(delay: const Duration(milliseconds: 30));
    final service = VideoMetadataService(repository, frameExtractor: fake);

    final results = await Future.wait(<Future<Clip>>[
      service.enrichAndPersist(clip),
      service.enrichAndPersist(clip),
    ]);

    expect(results[0], results[1]);
    expect(fake.probeCalls, 1);
    expect(fake.thumbnailCalls, 1);
  });

  test('完成済みクリップの再検証はサムネイルを再生成せず破損を検出する', () async {
    final complete = clip.withMetadata(
      durationMs: 1000,
      thumbnailPath: 'thumbnails/clip-1.jpg',
      isBroken: false,
    );
    await repository.saveClips(<Clip>[complete]);
    final fake = _FakeFrameExtractor(valid: false);
    final service = VideoMetadataService(repository, frameExtractor: fake);

    final validated = await service.validateAndPersist(complete);

    expect(validated.isBroken, isTrue);
    expect(fake.probeCalls, 1);
    expect(fake.thumbnailCalls, 0);
    expect((await repository.loadClips()).single, validated);
  });
}

class _FakeFrameExtractor implements FrameExtractorClient {
  _FakeFrameExtractor({this.valid = true, this.delay = Duration.zero});

  final bool valid;
  final Duration delay;
  int probeCalls = 0;
  int thumbnailCalls = 0;
  String? probedPath;
  String? thumbnailOutputPath;

  @override
  Future<VideoInfo> probe(String absoluteVideoPath) async {
    probeCalls += 1;
    probedPath = absoluteVideoPath;
    await Future<void>.delayed(delay);
    return VideoInfo(
      isValid: valid,
      durationMs: valid ? 4321 : 0,
      width: valid ? 1920 : 0,
      height: valid ? 1080 : 0,
      rotationDegrees: 0,
      errorReason: valid ? null : 'empty_file',
    );
  }

  @override
  Future<String> generateThumbnail(
    String absoluteVideoPath,
    String absoluteOutputPath,
    int maxLongEdgePx,
  ) async {
    thumbnailCalls += 1;
    thumbnailOutputPath = absoluteOutputPath;
    final output = File(absoluteOutputPath);
    await output.parent.create(recursive: true);
    await output.writeAsBytes(<int>[0xFF, 0xD8, 0xFF, 0xD9]);
    return output.path;
  }
}
