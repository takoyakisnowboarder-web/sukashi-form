import 'dart:io';

import 'package:uuid/uuid.dart';

import '../models/clip.dart';
import 'clip_repository.dart';

class VideoLibraryService {
  VideoLibraryService(this._clipRepository, {this._uuid = const Uuid()});

  final ClipRepository _clipRepository;
  final Uuid _uuid;

  Future<Clip> copyIntoLibrary(
    String sourcePath, {
    required int durationMs,
  }) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw FileSystemException('選択した動画を読み込めません。', sourcePath);
    }
    final id = _uuid.v4();
    final extension = _safeExtension(sourcePath);
    final relativePath = 'videos/$id.$extension';
    final destination = File(
      await _clipRepository.resolveAbsolutePath(relativePath),
    );
    await destination.parent.create(recursive: true);
    await source.copy(destination.path);
    return Clip(
      id: id,
      videoPath: relativePath,
      thumbnailPath: null,
      recordedAt: DateTime.now(),
      durationMs: durationMs,
      memo: null,
    );
  }

  Future<void> deleteCopiedFile(Clip clip) async {
    final file = File(
      await _clipRepository.resolveAbsolutePath(clip.videoPath),
    );
    if (await file.exists()) {
      await file.delete();
    }
  }

  String _safeExtension(String path) {
    final fileName = path.replaceAll('\\', '/').split('/').last;
    final dot = fileName.lastIndexOf('.');
    if (dot >= 0 && dot < fileName.length - 1) {
      final candidate = fileName.substring(dot + 1).toLowerCase();
      if (RegExp(r'^[a-z0-9]{1,5}$').hasMatch(candidate)) {
        return candidate;
      }
    }
    return 'mp4';
  }
}
