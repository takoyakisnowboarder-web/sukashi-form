import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sukashi_form/data/clip_repository.dart';
import 'package:sukashi_form/data/frame_cache_service.dart';
import 'package:sukashi_form/models/clip.dart';
import 'package:sukashi_form/native/frame_extractor.g.dart';

void main() {
  late Directory temporaryDirectory;
  late ClipRepository clipRepository;
  late FrameCacheRepository cacheRepository;
  late _FakeFrameExtractionClient client;
  late FrameCacheService service;
  late Clip clip;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'sukashi_frame_cache_test_',
    );
    clipRepository = ClipRepository(
      documentsDirectoryProvider: () async => temporaryDirectory,
    );
    cacheRepository = FrameCacheRepository(clipRepository);
    client = _FakeFrameExtractionClient();
    service = FrameCacheService(clipRepository, cacheRepository, client);
    clip = Clip(
      id: 'clip-1',
      videoPath: 'videos/clip-1.mp4',
      thumbnailPath: null,
      recordedAt: DateTime.utc(2026, 7, 18),
      durationMs: 1000,
      memo: null,
    );
  });

  tearDown(() async {
    client.dispose();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('完成済みキャッシュはネイティブ展開せず再利用する', () async {
    client.onExtract = (taskId, request) async {
      await _writeFrames(request, 3);
      return _result(frameCount: 3);
    };

    final first = await service.startExtraction(clip).result;
    final second = await service.startExtraction(clip).result;

    expect(first.fromCache, isFalse);
    expect(second.fromCache, isTrue);
    expect(second.frameCount, 3);
    expect(client.extractCalls, 1);
  });

  test('破損クリップはネイティブ展開を呼ばず拒否する', () async {
    final broken = Clip(
      id: clip.id,
      videoPath: clip.videoPath,
      thumbnailPath: null,
      recordedAt: clip.recordedAt,
      durationMs: clip.durationMs,
      memo: null,
      isBroken: true,
      validationError: 'probe_failed',
    );

    await expectLater(
      service.startExtraction(broken).result,
      throwsA(
        isA<FrameExtractionException>().having(
          (error) => error.reason,
          'reason',
          'broken_clip',
        ),
      ),
    );
    expect(client.extractCalls, 0);
  });

  test('上限到達の不完全結果も有効なキャッシュとして保持する', () async {
    client.onExtract = (taskId, request) async {
      await _writeFrames(request, 2);
      return _result(frameCount: 2, isComplete: false);
    };

    final first = await service.startExtraction(clip).result;
    final second = await service.startExtraction(clip).result;

    expect(first.isComplete, isFalse);
    expect(second.isComplete, isFalse);
    expect(second.fromCache, isTrue);
    expect(client.extractCalls, 1);
  });

  test('対象タスクの進捗だけを呼び出し元へ伝える', () async {
    client.onExtract = (taskId, request) async {
      client.emit('別タスク', 9, 9);
      client.emit(taskId, 0, 2);
      client.emit(taskId, 1, 2);
      await _writeFrames(request, 2);
      client.emit(taskId, 2, 2);
      return _result(frameCount: 2);
    };
    final session = service.startExtraction(clip);
    final progressFuture = session.progress.toList();

    await session.result;
    final progress = await progressFuture;

    expect(progress.map((event) => event.completedFrames), <int>[0, 1, 2]);
    expect(progress.every((event) => event.taskId == session.taskId), isTrue);
  });

  test('キャンセル後の遅いネイティブ完了を安全に捨て部分キャッシュを削除する', () async {
    final nativeResult = Completer<ExtractResult>();
    late ExtractRequest capturedRequest;
    client.onExtract = (taskId, request) {
      capturedRequest = request;
      return nativeResult.future;
    };
    final session = service.startExtraction(clip);
    while (client.extractCalls == 0) {
      await Future<void>.delayed(Duration.zero);
    }

    await File(
      '${capturedRequest.absoluteOutputDir}/frame_000000.jpg',
    ).writeAsString('partial');
    await session.cancel();
    nativeResult.complete(_result(frameCount: 1));

    await expectLater(session.result, throwsA(isA<FrameExtractionCancelled>()));
    expect(client.cancelCalls, 1);
    expect(
      await Directory(capturedRequest.absoluteOutputDir).exists(),
      isFalse,
    );
  });
}

ExtractResult _result({required int frameCount, bool isComplete = true}) {
  return ExtractResult(
    isComplete: isComplete,
    frameCount: frameCount,
    sourceDurationMs: 1000,
    sourceFps: 30,
  );
}

Future<void> _writeFrames(ExtractRequest request, int count) async {
  final directory = Directory(request.absoluteOutputDir);
  await directory.create(recursive: true);
  for (var index = 0; index < count; index++) {
    await File(
      '${directory.path}${Platform.pathSeparator}'
      'frame_${index.toString().padLeft(6, '0')}.jpg',
    ).writeAsString('jpeg-$index');
  }
}

class _FakeFrameExtractionClient implements FrameExtractionClient {
  final StreamController<FrameExtractionProgress> _progress =
      StreamController<FrameExtractionProgress>.broadcast(sync: true);

  Future<ExtractResult> Function(String, ExtractRequest)? onExtract;
  int extractCalls = 0;
  int cancelCalls = 0;

  @override
  Stream<FrameExtractionProgress> get progress => _progress.stream;

  void emit(String taskId, int completed, int total) {
    _progress.add(
      FrameExtractionProgress(
        taskId: taskId,
        completedFrames: completed,
        totalFrames: total,
      ),
    );
  }

  @override
  Future<ExtractResult> extractFrames(String taskId, ExtractRequest request) {
    extractCalls++;
    final callback = onExtract;
    if (callback == null) {
      throw StateError('onExtract is not configured');
    }
    return callback(taskId, request);
  }

  @override
  Future<void> cancelExtraction(String taskId) async {
    cancelCalls++;
  }

  @override
  void dispose() {
    unawaited(_progress.close());
  }
}
