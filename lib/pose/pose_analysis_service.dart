import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../data/clip_repository.dart';
import 'pose_detector_client.dart';
import 'pose_model.dart';

class PoseAnalysisProgress {
  const PoseAnalysisProgress({required this.completed, required this.total});

  final int completed;
  final int total;
}

class PoseAnalysisSession {
  PoseAnalysisSession({
    required this.progress,
    required this.result,
    required Future<void> Function() onCancel,
  }) : _onCancel = onCancel;

  final Stream<PoseAnalysisProgress> progress;
  final Future<Map<String, PoseFrame>> result;
  final Future<void> Function() _onCancel;

  Future<void> cancel() => _onCancel();
}

class PoseCacheRepository {
  PoseCacheRepository(this._clipRepository);

  static const fileName = 'pose_landmarks.json';
  static const version = 6;

  final ClipRepository _clipRepository;

  Future<File> _fileFor(String clipId) async {
    final path = await _clipRepository.resolveAbsolutePath(
      'frames/$clipId/$fileName',
    );
    return File(path);
  }

  Future<Map<String, PoseFrame>> load(String clipId) async {
    final file = await _fileFor(clipId);
    if (!await file.exists()) {
      return <String, PoseFrame>{};
    }
    try {
      final json = Map<String, dynamic>.from(
        jsonDecode(await file.readAsString()) as Map,
      );
      if (json['version'] != version) {
        return <String, PoseFrame>{};
      }
      final frames = Map<String, dynamic>.from(json['frames'] as Map);
      return <String, PoseFrame>{
        for (final entry in frames.entries)
          if (entry.value is Map)
            entry.key: PoseFrame.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
            ),
      };
    } on Object {
      return <String, PoseFrame>{};
    }
  }

  Future<void> save(String clipId, Map<String, PoseFrame> frames) async {
    final file = await _fileFor(clipId);
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsString(
        jsonEncode(<String, Object>{
          'version': version,
          'frames': <String, Object>{
            for (final entry in frames.entries) entry.key: entry.value.toJson(),
          },
        }),
        flush: true,
      );
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }
}

class PoseAnalysisService {
  PoseAnalysisService(this._detector, this._cache);

  final PoseDetectorClient _detector;
  final PoseCacheRepository _cache;
  Future<void> _queue = Future<void>.value();

  bool get isSupported => _detector.isSupported;

  PoseAnalysisSession analyzeClip({
    required String clipId,
    required List<String> framePaths,
  }) {
    final cancelled = _CancelFlag();
    final progress = StreamController<PoseAnalysisProgress>.broadcast(
      sync: true,
    );
    final previous = _queue;
    final result = () async {
      await previous;
      try {
        return await _analyzePending(
          clipId: clipId,
          framePaths: framePaths,
          cancelled: cancelled,
          progress: progress,
        );
      } finally {
        await progress.close();
      }
    }();
    _queue = result.then((_) {}, onError: (_) {});
    return PoseAnalysisSession(
      progress: progress.stream,
      result: result,
      onCancel: () async {
        cancelled.value = true;
        await result;
      },
    );
  }

  Future<Map<String, PoseFrame>> _analyzePending({
    required String clipId,
    required List<String> framePaths,
    required _CancelFlag cancelled,
    required StreamController<PoseAnalysisProgress> progress,
  }) async {
    final cached = await _cache.load(clipId);
    final pending = framePaths
        .where((path) => !cached.containsKey(_key(path)))
        .toList(growable: false);
    final total = framePaths.length;
    var completed = total - pending.length;
    progress.add(PoseAnalysisProgress(completed: completed, total: total));
    if (pending.isEmpty || !_detector.isSupported) {
      return cached;
    }
    var dirty = false;
    for (final path in pending) {
      if (cancelled.value) {
        break;
      }
      try {
        final detected = await _detector.detect(path);
        if (cancelled.value) {
          break;
        }
        cached[_key(path)] =
            detected ??
            const PoseFrame(
              imageWidth: 1,
              imageHeight: 1,
              landmarks: <PoseJoint, PosePoint>{},
            );
        dirty = true;
      } on Object {
        // Detector/platform failures are retried next time.
      }
      completed += 1;
      progress.add(PoseAnalysisProgress(completed: completed, total: total));
    }
    if (dirty) {
      await _cache.save(clipId, cached);
    }
    return cached;
  }

  static String keyForPath(String path) => _key(path);

  static String _key(String path) => path.replaceAll('\\', '/').split('/').last;
}

class _CancelFlag {
  bool value = false;
}
