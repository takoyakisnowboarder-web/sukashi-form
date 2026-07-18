import 'dart:async';
import 'dart:io';

import '../models/clip.dart';
import '../native/frame_extractor.g.dart';
import 'clip_repository.dart';

abstract interface class FrameExtractorClient {
  Future<VideoInfo> probe(String absoluteVideoPath);

  Future<String> generateThumbnail(
    String absoluteVideoPath,
    String absoluteOutputPath,
    int maxLongEdgePx,
  );
}

class PigeonFrameExtractorClient implements FrameExtractorClient {
  PigeonFrameExtractorClient({FrameExtractorApi? api})
    : _api = api ?? FrameExtractorApi();

  final FrameExtractorApi _api;

  @override
  Future<VideoInfo> probe(String absoluteVideoPath) {
    return _api.probe(absoluteVideoPath);
  }

  @override
  Future<String> generateThumbnail(
    String absoluteVideoPath,
    String absoluteOutputPath,
    int maxLongEdgePx,
  ) {
    return _api.generateThumbnail(
      absoluteVideoPath,
      absoluteOutputPath,
      maxLongEdgePx,
    );
  }
}

class VideoMetadataService {
  VideoMetadataService(
    this._repository, {
    FrameExtractorClient? frameExtractor,
    this.thumbnailLongEdgePx = 512,
  }) : _frameExtractor = frameExtractor ?? PigeonFrameExtractorClient();

  final ClipRepository _repository;
  final FrameExtractorClient _frameExtractor;
  final int thumbnailLongEdgePx;
  final Map<String, Future<Clip>> _inFlight = <String, Future<Clip>>{};
  Future<void> _writeBarrier = Future<void>.value();

  bool needsBackfill(Clip clip) {
    return !clip.isBroken &&
        (clip.durationMs == 0 || clip.thumbnailPath == null);
  }

  Future<Clip> enrichAndPersist(Clip clip) {
    if (!needsBackfill(clip)) {
      return Future<Clip>.value(clip);
    }
    final running = _inFlight[clip.id];
    if (running != null) {
      return running;
    }
    late final Future<Clip> tracked;
    tracked = _enrichAndPersist(clip).whenComplete(() {
      if (identical(_inFlight[clip.id], tracked)) {
        _inFlight.remove(clip.id);
      }
    });
    _inFlight[clip.id] = tracked;
    return tracked;
  }

  Future<Clip> validateAndPersist(Clip clip) {
    if (clip.isBroken) {
      return Future<Clip>.value(clip);
    }
    final running = _inFlight[clip.id];
    if (running != null) {
      return running;
    }
    late final Future<Clip> tracked;
    tracked = _validateAndPersist(clip).whenComplete(() {
      if (identical(_inFlight[clip.id], tracked)) {
        _inFlight.remove(clip.id);
      }
    });
    _inFlight[clip.id] = tracked;
    return tracked;
  }

  Future<Clip> _enrichAndPersist(Clip clip) async {
    final absoluteVideoPath = await _repository.resolveAbsolutePath(
      clip.videoPath,
    );
    VideoInfo info;
    try {
      info = await _frameExtractor.probe(absoluteVideoPath);
    } on Object catch (error) {
      info = VideoInfo(
        isValid: false,
        durationMs: 0,
        width: 0,
        height: 0,
        errorReason: 'probe_failed:${error.runtimeType}',
      );
    }

    if (!info.isValid) {
      final broken = clip.withMetadata(
        durationMs: 0,
        thumbnailPath: clip.thumbnailPath,
        isBroken: true,
        validationError: info.errorReason ?? 'video_unreadable',
      );
      await _persistIfPresent(broken);
      return broken;
    }

    String? thumbnailPath = clip.thumbnailPath;
    if (thumbnailPath == null) {
      const relativeOutputPrefix = 'thumbnails/';
      final requestedRelativePath = '$relativeOutputPrefix${clip.id}.jpg';
      final requestedAbsolutePath = await _repository.resolveAbsolutePath(
        requestedRelativePath,
      );
      await File(requestedAbsolutePath).parent.create(recursive: true);
      try {
        final generatedAbsolutePath = await _frameExtractor.generateThumbnail(
          absoluteVideoPath,
          requestedAbsolutePath,
          thumbnailLongEdgePx,
        );
        thumbnailPath = await _repository.toRelativePath(generatedAbsolutePath);
      } on Object {
        thumbnailPath = null;
      }
    }

    final enriched = clip.withMetadata(
      durationMs: info.durationMs,
      thumbnailPath: thumbnailPath,
      isBroken: false,
    );
    await _persistIfPresent(enriched);
    return enriched;
  }

  Future<Clip> _validateAndPersist(Clip clip) async {
    final absoluteVideoPath = await _repository.resolveAbsolutePath(
      clip.videoPath,
    );
    VideoInfo info;
    try {
      info = await _frameExtractor.probe(absoluteVideoPath);
    } on Object catch (error) {
      info = VideoInfo(
        isValid: false,
        durationMs: 0,
        width: 0,
        height: 0,
        errorReason: 'probe_failed:${error.runtimeType}',
      );
    }
    final validated = info.isValid
        ? clip.withMetadata(
            durationMs: info.durationMs,
            thumbnailPath: clip.thumbnailPath,
            isBroken: false,
          )
        : clip.withMetadata(
            durationMs: 0,
            thumbnailPath: clip.thumbnailPath,
            isBroken: true,
            validationError: info.errorReason ?? 'video_unreadable',
          );
    if (validated != clip) {
      await _persistIfPresent(validated);
    }
    return validated;
  }

  Future<bool> _persistIfPresent(Clip updated) async {
    final previousWrite = _writeBarrier;
    final nextWrite = Completer<void>();
    _writeBarrier = nextWrite.future;
    await previousWrite;
    try {
      final clips = await _repository.loadClips();
      final index = clips.indexWhere((clip) => clip.id == updated.id);
      if (index < 0) {
        return false;
      }
      final replaced = clips.toList(growable: false);
      replaced[index] = updated;
      await _repository.saveClips(replaced);
      return true;
    } finally {
      nextWrite.complete();
    }
  }
}
