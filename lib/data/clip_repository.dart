import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/clip.dart';

typedef DocumentsDirectoryProvider = Future<Directory> Function();

class ClipRepository {
  ClipRepository({DocumentsDirectoryProvider? documentsDirectoryProvider})
    : _documentsDirectoryProvider =
          documentsDirectoryProvider ?? getApplicationDocumentsDirectory;

  final DocumentsDirectoryProvider _documentsDirectoryProvider;
  Directory? _cachedDirectory;

  Future<Directory> get documentsDirectory async {
    return _cachedDirectory ??= await _documentsDirectoryProvider();
  }

  Future<File> get _clipsFile async {
    final directory = await documentsDirectory;
    return File(_join(directory.path, 'clips.json'));
  }

  Future<List<Clip>> loadClips() async {
    final file = await _clipsFile;
    if (!await file.exists()) {
      return <Clip>[];
    }

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List<dynamic>) {
        throw const FormatException('clips.json must contain a list.');
      }
      return decoded
          .map(
            (item) => Clip.fromJson(
              Map<String, dynamic>.from(item as Map<dynamic, dynamic>),
            ),
          )
          .toList(growable: false);
    } on Object {
      await _preserveBrokenFile(file);
      return <Clip>[];
    }
  }

  Future<void> saveClips(List<Clip> clips) async {
    final file = await _clipsFile;
    await file.parent.create(recursive: true);
    final temporaryFile = File('${file.path}.tmp');
    try {
      await temporaryFile.writeAsString(
        jsonEncode(clips.map((clip) => clip.toJson()).toList()),
        flush: true,
      );
      await temporaryFile.rename(file.path);
    } on Object {
      if (await temporaryFile.exists()) {
        await temporaryFile.delete();
      }
      rethrow;
    }
  }

  Future<void> deleteClip(String id, List<Clip> clips) async {
    final clip = clips.where((item) => item.id == id).firstOrNull;
    if (clip == null) {
      return;
    }

    await _deleteRelativeFileIfPresent(clip.videoPath);
    final thumbnailPath = clip.thumbnailPath;
    if (thumbnailPath != null) {
      await _deleteRelativeFileIfPresent(thumbnailPath);
    }
    await _deleteRelativeDirectoryIfPresent('frames/${clip.id}');
    await saveClips(clips.where((item) => item.id != id).toList());
  }

  Future<String> resolveAbsolutePath(String relativePath) async {
    if (_looksAbsolute(relativePath)) {
      throw ArgumentError.value(
        relativePath,
        'relativePath',
        'Must be relative.',
      );
    }
    final directory = await documentsDirectory;
    return _join(directory.path, relativePath);
  }

  Future<String> toRelativePath(String absolutePath) async {
    final directory = await documentsDirectory;
    final base = _normalize(directory.path);
    final candidate = _normalize(absolutePath);
    final prefix = '$base${Platform.pathSeparator}';
    if (!candidate.toLowerCase().startsWith(prefix.toLowerCase())) {
      throw ArgumentError.value(
        absolutePath,
        'absolutePath',
        'Path is outside the application documents directory.',
      );
    }
    return candidate.substring(prefix.length).replaceAll('\\', '/');
  }

  Future<bool> hasDebugSeeded() async {
    final directory = await documentsDirectory;
    return File(_join(directory.path, '.debug_seeded')).exists();
  }

  Future<void> markDebugSeeded() async {
    final directory = await documentsDirectory;
    await File(
      _join(directory.path, '.debug_seeded'),
    ).writeAsString('seeded', flush: true);
  }

  Future<void> _deleteRelativeFileIfPresent(String relativePath) async {
    final file = File(await resolveAbsolutePath(relativePath));
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<void> _deleteRelativeDirectoryIfPresent(String relativePath) async {
    final directory = Directory(await resolveAbsolutePath(relativePath));
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  Future<void> _preserveBrokenFile(File file) async {
    var brokenPath = '${file.path}.broken';
    var suffix = 1;
    while (await File(brokenPath).exists()) {
      brokenPath = '${file.path}.broken.$suffix';
      suffix += 1;
    }
    await file.rename(brokenPath);
  }

  static bool _looksAbsolute(String path) {
    return RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path) ||
        path.startsWith('\\\\') ||
        path.startsWith('/');
  }

  static String _join(String base, String child) {
    final normalizedChild = child
        .replaceAll('\\', Platform.pathSeparator)
        .replaceAll('/', Platform.pathSeparator)
        .replaceFirst(RegExp(r'^[\\/]+'), '');
    return '$base${Platform.pathSeparator}$normalizedChild';
  }

  static String _normalize(String path) {
    return path
        .replaceAll('\\', Platform.pathSeparator)
        .replaceAll('/', Platform.pathSeparator)
        .replaceAll(RegExp(r'[\\/]+$'), '');
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
