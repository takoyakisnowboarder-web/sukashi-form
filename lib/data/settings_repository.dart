import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/app_settings.dart';

typedef SettingsDirectoryProvider = Future<Directory> Function();

class SettingsRepository {
  SettingsRepository({SettingsDirectoryProvider? documentsDirectoryProvider})
    : _documentsDirectoryProvider =
          documentsDirectoryProvider ?? getApplicationDocumentsDirectory;

  final SettingsDirectoryProvider _documentsDirectoryProvider;
  Directory? _cachedDirectory;

  Future<File> get _settingsFile async {
    final directory = _cachedDirectory ??= await _documentsDirectoryProvider();
    return File('${directory.path}${Platform.pathSeparator}settings.json');
  }

  Future<AppSettings> load() async {
    final file = await _settingsFile;
    if (!await file.exists()) {
      return AppSettings.defaults;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<dynamic, dynamic>) {
        throw const FormatException('settings.json must contain an object.');
      }
      return AppSettings.fromJson(Map<String, dynamic>.from(decoded));
    } on Object {
      await _preserveBrokenFile(file);
      return AppSettings.defaults;
    }
  }

  Future<void> save(AppSettings settings) async {
    final file = await _settingsFile;
    await file.parent.create(recursive: true);
    final temporaryFile = File('${file.path}.tmp');
    try {
      await temporaryFile.writeAsString(
        jsonEncode(settings.toJson()),
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

  Future<void> _preserveBrokenFile(File file) async {
    var brokenPath = '${file.path}.broken';
    var suffix = 1;
    while (await File(brokenPath).exists()) {
      brokenPath = '${file.path}.broken.$suffix';
      suffix += 1;
    }
    await file.rename(brokenPath);
  }
}
