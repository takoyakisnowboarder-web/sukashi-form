import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/clip_repository.dart';
import '../data/video_library_service.dart';
import '../data/video_metadata_service.dart';
import '../models/clip.dart';

final clipRepositoryProvider = Provider<ClipRepository>((ref) {
  return ClipRepository();
});

final videoLibraryServiceProvider = Provider<VideoLibraryService>((ref) {
  return VideoLibraryService(ref.watch(clipRepositoryProvider));
});

final videoMetadataServiceProvider = Provider<VideoMetadataService>((ref) {
  return VideoMetadataService(ref.watch(clipRepositoryProvider));
});

final clipListProvider = AsyncNotifierProvider<ClipListNotifier, List<Clip>>(
  ClipListNotifier.new,
);

class ClipListNotifier extends AsyncNotifier<List<Clip>> {
  ClipRepository get _repository => ref.read(clipRepositoryProvider);

  @override
  Future<List<Clip>> build() async {
    var clips = await _repository.loadClips();
    if (kDebugMode && !await _repository.hasDebugSeeded()) {
      if (clips.isEmpty) {
        clips = _debugClips();
        await _repository.saveClips(clips);
      }
      await _repository.markDebugSeeded();
    }
    unawaited(Future<void>(() => _backfillAll(clips)));
    return clips;
  }

  Future<void> delete(String id) async {
    final clips = state.value ?? <Clip>[];
    state = const AsyncLoading<List<Clip>>();
    state = await AsyncValue.guard(() async {
      await _repository.deleteClip(id, clips);
      return clips.where((clip) => clip.id != id).toList(growable: false);
    });
  }

  Future<void> updateMemo(String id, String? memo) async {
    final clips = state.value ?? <Clip>[];
    final normalizedMemo = memo?.trim();
    final updated = clips
        .map(
          (clip) => clip.id == id
              ? clip.withMemo(
                  normalizedMemo == null || normalizedMemo.isEmpty
                      ? null
                      : normalizedMemo,
                )
              : clip,
        )
        .toList(growable: false);
    state = const AsyncLoading<List<Clip>>();
    state = await AsyncValue.guard(() async {
      await _repository.saveClips(updated);
      return updated;
    });
  }

  Future<Clip> importVideoPath(
    String sourcePath, {
    required int durationMs,
  }) async {
    final clips = state.value ?? await _repository.loadClips();
    Clip? copiedClip;
    state = const AsyncLoading<List<Clip>>();
    try {
      copiedClip = await ref
          .read(videoLibraryServiceProvider)
          .copyIntoLibrary(sourcePath, durationMs: durationMs);
      final updated = <Clip>[copiedClip, ...clips];
      await _repository.saveClips(updated);
      state = AsyncData<List<Clip>>(updated);
    } on Object catch (error, stackTrace) {
      if (copiedClip != null) {
        await ref
            .read(videoLibraryServiceProvider)
            .deleteCopiedFile(copiedClip);
      }
      state = AsyncError<List<Clip>>(error, stackTrace);
      rethrow;
    }
    try {
      return await _backfillClip(copiedClip) ?? copiedClip;
    } on Object {
      return copiedClip;
    }
  }

  Future<void> _backfillAll(List<Clip> clips) async {
    for (final clip in clips) {
      final service = ref.read(videoMetadataServiceProvider);
      await _applyMetadataResult(
        clip,
        service.needsBackfill(clip)
            ? service.enrichAndPersist(clip)
            : service.validateAndPersist(clip),
      );
    }
  }

  Future<Clip?> _backfillClip(Clip clip) async {
    return _applyMetadataResult(
      clip,
      ref.read(videoMetadataServiceProvider).enrichAndPersist(clip),
    );
  }

  Future<Clip?> _applyMetadataResult(Clip clip, Future<Clip> operation) async {
    final enriched = await operation;
    final current = state.value;
    if (current == null || !current.any((item) => item.id == clip.id)) {
      return null;
    }
    final updated = current
        .map((item) => item.id == clip.id ? enriched : item)
        .toList(growable: false);
    state = AsyncData<List<Clip>>(updated);
    if (enriched.isBroken) {
      ref.read(clipSelectionProvider.notifier).remove(enriched.id);
    }
    return enriched;
  }

  List<Clip> _debugClips() {
    final now = DateTime.now();
    const uuid = Uuid();
    return <Clip>[
      Clip(
        id: uuid.v4(),
        videoPath: 'videos/debug_01.mp4',
        thumbnailPath: null,
        recordedAt: now.subtract(const Duration(days: 30)),
        durationMs: 3200,
        memo: '前回のフォーム',
      ),
      Clip(
        id: uuid.v4(),
        videoPath: 'videos/debug_02.mp4',
        thumbnailPath: null,
        recordedAt: now.subtract(const Duration(days: 7)),
        durationMs: 2800,
        memo: '調子○',
      ),
      Clip(
        id: uuid.v4(),
        videoPath: 'videos/debug_03.mp4',
        thumbnailPath: null,
        recordedAt: now,
        durationMs: 4100,
        memo: null,
      ),
    ];
  }
}

final clipSelectionProvider =
    NotifierProvider<ClipSelectionNotifier, List<String>>(
      ClipSelectionNotifier.new,
    );

class ClipSelectionNotifier extends Notifier<List<String>> {
  @override
  List<String> build() => <String>[];

  void toggle(String id) {
    if (state.contains(id)) {
      state = state.where((selectedId) => selectedId != id).toList();
      return;
    }
    if (state.length < 2) {
      state = <String>[...state, id];
      return;
    }
    state = <String>[state.last, id];
  }

  void remove(String id) {
    state = state.where((selectedId) => selectedId != id).toList();
  }

  void clear() {
    state = <String>[];
  }
}
