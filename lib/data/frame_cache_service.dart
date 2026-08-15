import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../models/clip.dart';
import '../native/frame_extractor.g.dart';
import 'clip_repository.dart';

class FrameExtractionProgress {
  const FrameExtractionProgress({
    required this.taskId,
    required this.completedFrames,
    required this.totalFrames,
  });

  final String taskId;
  final int completedFrames;
  final int totalFrames;

  double get fraction =>
      totalFrames == 0 ? 0 : (completedFrames / totalFrames).clamp(0, 1);
}

class FrameCacheResult {
  const FrameCacheResult({
    required this.isComplete,
    required this.frameCount,
    required this.sourceDurationMs,
    required this.sourceFps,
    required this.absoluteFramePaths,
    required this.fromCache,
  });

  final bool isComplete;
  final int frameCount;
  final int sourceDurationMs;
  final double sourceFps;
  final List<String> absoluteFramePaths;
  final bool fromCache;
}

class FrameExtractionException implements Exception {
  const FrameExtractionException(this.reason);

  final String reason;

  @override
  String toString() => 'FrameExtractionException($reason)';
}

class FrameExtractionCancelled extends FrameExtractionException {
  const FrameExtractionCancelled() : super('cancelled');
}

String framePreparationLabel({
  required int clipIndex,
  required String? memo,
  required String reason,
}) {
  final trimmed = memo?.trim() ?? '';
  final label = trimmed.isEmpty ? '${clipIndex + 1}本目' : trimmed;
  return '$label:$reason';
}

abstract interface class FrameExtractionClient {
  Stream<FrameExtractionProgress> get progress;

  Future<ExtractResult> extractFrames(String taskId, ExtractRequest request);

  Future<void> cancelExtraction(String taskId);

  void dispose();
}

class PigeonFrameExtractionClient implements FrameExtractionClient {
  PigeonFrameExtractionClient({FrameExtractorApi? api})
    : _api = api ?? FrameExtractorApi() {
    FrameExtractionProgressApi.setUp(_ProgressHandler(_progressController));
  }

  final FrameExtractorApi _api;
  final StreamController<FrameExtractionProgress> _progressController =
      StreamController<FrameExtractionProgress>.broadcast(sync: true);

  @override
  Stream<FrameExtractionProgress> get progress => _progressController.stream;

  @override
  Future<ExtractResult> extractFrames(String taskId, ExtractRequest request) {
    return _api.extractFrames(taskId, request);
  }

  @override
  Future<void> cancelExtraction(String taskId) {
    return _api.cancelExtraction(taskId);
  }

  @override
  void dispose() {
    FrameExtractionProgressApi.setUp(null);
    unawaited(_progressController.close());
  }
}

class _ProgressHandler extends FrameExtractionProgressApi {
  _ProgressHandler(this._controller);

  final StreamController<FrameExtractionProgress> _controller;

  @override
  void onProgress(String taskId, int completedFrames, int totalFrames) {
    if (!_controller.isClosed) {
      _controller.add(
        FrameExtractionProgress(
          taskId: taskId,
          completedFrames: completedFrames,
          totalFrames: totalFrames,
        ),
      );
    }
  }
}

class FrameExtractionSession {
  FrameExtractionSession({
    required this.taskId,
    required this.progress,
    required this.result,
    required this._onCancel,
  });

  final String taskId;
  final Stream<FrameExtractionProgress> progress;
  final Future<FrameCacheResult> result;
  final Future<void> Function() _onCancel;

  Future<void> cancel() => _onCancel();
}

class FrameCacheRepository {
  FrameCacheRepository(this._clipRepository, {this.rootDirectory = 'frames'});

  static const manifestFileName = 'manifest.json';
  static const manifestVersion = 2;

  final ClipRepository _clipRepository;
  final String rootDirectory;

  Future<Directory> directoryFor(String clipId) async {
    return Directory(
      await _clipRepository.resolveAbsolutePath('$rootDirectory/$clipId'),
    );
  }

  Future<FrameCacheResult?> loadCompleteCache(
    String clipId, {
    required int maxLongEdgePx,
    required int maxFrames,
    required int jpegQuality,
    required int? rangeStartMs,
    required int? rangeEndMs,
  }) async {
    final directory = await directoryFor(clipId);
    final manifestFile = File(
      '${directory.path}${Platform.pathSeparator}$manifestFileName',
    );
    if (!await manifestFile.exists()) {
      return null;
    }
    try {
      final json = Map<String, dynamic>.from(
        jsonDecode(await manifestFile.readAsString()) as Map<dynamic, dynamic>,
      );
      if (json['version'] != manifestVersion ||
          json['maxLongEdgePx'] != maxLongEdgePx ||
          json['maxFrames'] != maxFrames ||
          json['jpegQuality'] != jpegQuality ||
          json['rangeStartMs'] != rangeStartMs ||
          json['rangeEndMs'] != rangeEndMs) {
        return null;
      }
      final frameCount = json['frameCount'] as int;
      if (frameCount <= 0) {
        return null;
      }
      final paths = await _framePaths(directory, frameCount);
      for (final path in paths) {
        final file = File(path);
        if (!await file.exists() || await file.length() == 0) {
          return null;
        }
      }
      return FrameCacheResult(
        isComplete: json['isComplete'] as bool,
        frameCount: frameCount,
        sourceDurationMs: json['sourceDurationMs'] as int,
        sourceFps: (json['sourceFps'] as num).toDouble(),
        absoluteFramePaths: paths,
        fromCache: true,
      );
    } on Object {
      return null;
    }
  }

  Future<FrameCacheResult> finalizeCache(
    String clipId,
    ExtractResult nativeResult, {
    required int maxLongEdgePx,
    required int maxFrames,
    required int jpegQuality,
    required int? rangeStartMs,
    required int? rangeEndMs,
  }) async {
    final directory = await directoryFor(clipId);
    final frameCount = nativeResult.frameCount;
    if (frameCount <= 0) {
      throw const FrameExtractionException('no_frames_extracted');
    }
    final paths = await _framePaths(directory, frameCount);
    for (final path in paths) {
      final file = File(path);
      if (!await file.exists() || await file.length() == 0) {
        throw const FrameExtractionException('incomplete_frame_set');
      }
    }
    final manifestFile = File(
      '${directory.path}${Platform.pathSeparator}$manifestFileName',
    );
    final temporary = File('${manifestFile.path}.tmp');
    try {
      await temporary.writeAsString(
        jsonEncode(<String, Object?>{
          'version': manifestVersion,
          'frameCount': frameCount,
          'isComplete': nativeResult.isComplete,
          'sourceDurationMs': nativeResult.sourceDurationMs,
          'sourceFps': nativeResult.sourceFps,
          'maxLongEdgePx': maxLongEdgePx,
          'maxFrames': maxFrames,
          'jpegQuality': jpegQuality,
          'rangeStartMs': rangeStartMs,
          'rangeEndMs': rangeEndMs,
        }),
        flush: true,
      );
      await temporary.rename(manifestFile.path);
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
    return FrameCacheResult(
      isComplete: nativeResult.isComplete,
      frameCount: frameCount,
      sourceDurationMs: nativeResult.sourceDurationMs,
      sourceFps: nativeResult.sourceFps,
      absoluteFramePaths: paths,
      fromCache: false,
    );
  }

  Future<void> prepareEmptyDirectory(String clipId) async {
    await deleteClipCache(clipId);
    await (await directoryFor(clipId)).create(recursive: true);
  }

  Future<void> deleteClipCache(String clipId) async {
    final directory = await directoryFor(clipId);
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  Future<void> deleteAllCaches() async {
    final directory = Directory(
      await _clipRepository.resolveAbsolutePath(rootDirectory),
    );
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  Future<List<String>> _framePaths(Directory directory, int frameCount) async {
    return List<String>.generate(
      frameCount,
      (index) =>
          '${directory.path}${Platform.pathSeparator}'
          'frame_${index.toString().padLeft(6, '0')}.jpg',
      growable: false,
    );
  }
}

class FrameCacheService {
  FrameCacheService(
    this._clipRepository,
    this._cacheRepository,
    this._client, {
    this._uuid = const Uuid(),
    this.maxLongEdgePx = 1280,
    this.maxFrames = 600,
    this.jpegQuality = 85,
  });

  final ClipRepository _clipRepository;
  final FrameCacheRepository _cacheRepository;
  final FrameExtractionClient _client;
  final Uuid _uuid;
  final int maxLongEdgePx;
  final int maxFrames;
  final int jpegQuality;

  FrameExtractionSession startExtraction(Clip clip) {
    return startExtractionForRange(
      clip,
      rangeStartMs: clip.trimStartMs,
      rangeEndMs: clip.trimEndMs,
    );
  }

  FrameExtractionSession startExtractionForRange(
    Clip clip, {
    required int? rangeStartMs,
    required int? rangeEndMs,
  }) {
    final taskId = _uuid.v4();
    final progressController =
        StreamController<FrameExtractionProgress>.broadcast(sync: true);
    final state = _ExtractionState();
    late final Future<FrameCacheResult> result;
    result = Future<FrameCacheResult>(() async {
      StreamSubscription<FrameExtractionProgress>? subscription;
      var startedNativeExtraction = false;
      try {
        if (clip.isBroken) {
          throw const FrameExtractionException('broken_clip');
        }
        final cached = await _cacheRepository.loadCompleteCache(
          clip.id,
          maxLongEdgePx: maxLongEdgePx,
          maxFrames: maxFrames,
          jpegQuality: jpegQuality,
          rangeStartMs: rangeStartMs,
          rangeEndMs: rangeEndMs,
        );
        if (cached != null) {
          return cached;
        }
        if (state.cancelled) {
          throw const FrameExtractionCancelled();
        }

        await _cacheRepository.prepareEmptyDirectory(clip.id);
        final outputDirectory = await _cacheRepository.directoryFor(clip.id);
        final absoluteVideoPath = await _clipRepository.resolveAbsolutePath(
          clip.videoPath,
        );
        subscription = _client.progress
            .where((event) => event.taskId == taskId)
            .listen((event) {
              if (!state.cancelled && !progressController.isClosed) {
                progressController.add(event);
              }
            });
        startedNativeExtraction = true;
        final nativeResult = await _client.extractFrames(
          taskId,
          ExtractRequest(
            absoluteVideoPath: absoluteVideoPath,
            absoluteOutputDir: outputDirectory.path,
            maxLongEdgePx: maxLongEdgePx,
            maxFrames: maxFrames,
            jpegQuality: jpegQuality,
            rangeStartMs: rangeStartMs,
            rangeEndMs: rangeEndMs,
          ),
        );
        if (state.cancelled || nativeResult.errorReason == 'cancelled') {
          throw const FrameExtractionCancelled();
        }
        final errorReason = nativeResult.errorReason;
        if (errorReason != null) {
          throw FrameExtractionException(errorReason);
        }
        return await _cacheRepository.finalizeCache(
          clip.id,
          nativeResult,
          maxLongEdgePx: maxLongEdgePx,
          maxFrames: maxFrames,
          jpegQuality: jpegQuality,
          rangeStartMs: rangeStartMs,
          rangeEndMs: rangeEndMs,
        );
      } on Object {
        if (startedNativeExtraction) {
          await _cacheRepository.deleteClipCache(clip.id);
        }
        rethrow;
      } finally {
        state.completed = true;
        await subscription?.cancel();
        await progressController.close();
      }
    });

    return FrameExtractionSession(
      taskId: taskId,
      progress: progressController.stream,
      result: result,
      onCancel: () async {
        if (state.completed || state.cancelled) {
          return;
        }
        state.cancelled = true;
        await _client.cancelExtraction(taskId);
      },
    );
  }

  Future<void> deleteClipCache(String clipId) {
    return _cacheRepository.deleteClipCache(clipId);
  }

  Future<void> deleteAllCaches() {
    return _cacheRepository.deleteAllCaches();
  }
}

class _ExtractionState {
  bool cancelled = false;
  bool completed = false;
}
