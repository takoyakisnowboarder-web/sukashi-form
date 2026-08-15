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
  static const version = 2;

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

  PoseAnalysisSession analyzeClip({
    required String clipId,
    required List<String> framePaths,
  }) {
    var cancelled = false;
    final progress = StreamController<PoseAnalysisProgress>.broadcast(
      sync: true,
    );
    final result = Future<Map<String, PoseFrame>>(() async {
      try {
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
        for (final path in pending) {
          if (cancelled) {
            break;
          }
          cached[_key(path)] =
              await _detector.detect(path) ??
              const PoseFrame(
                imageWidth: 1,
                imageHeight: 1,
                landmarks: <PoseJoint, PosePoint>{},
              );
          completed += 1;
          progress.add(
            PoseAnalysisProgress(completed: completed, total: total),
          );
        }
        await _cache.save(clipId, cached);
        return cached;
      } finally {
        await progress.close();
      }
    });
    return PoseAnalysisSession(
      progress: progress.stream,
      result: result,
      onCancel: () async {
        cancelled = true;
        await result;
      },
    );
  }

  static String keyForPath(String path) => _key(path);

  static String _key(String path) => path.replaceAll('\\', '/').split('/').last;
}
