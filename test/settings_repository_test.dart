import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sukashi_form/data/settings_repository.dart';
import 'package:sukashi_form/models/app_settings.dart';

void main() {
  late Directory temporaryDirectory;
  late SettingsRepository repository;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'sukashi_settings_test_',
    );
    repository = SettingsRepository(
      documentsDirectoryProvider: () async => temporaryDirectory,
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('グリッド種類とカウントダウン秒数を保存して読み戻せる', () async {
    const settings = AppSettings(
      gridType: CameraGridType.grid4x4,
      countdownSeconds: 5,
      recordingSeconds: 20,
    );

    await repository.save(settings);

    expect(await repository.load(), settings);
    expect(
      await File('${temporaryDirectory.path}/settings.json.tmp').exists(),
      isFalse,
    );
  });

  test('壊れたsettings.jsonは.brokenへ残し既定値で復帰する', () async {
    final file = File('${temporaryDirectory.path}/settings.json');
    await file.writeAsString('{broken json');

    expect(await repository.load(), AppSettings.defaults);
    expect(await file.exists(), isFalse);
    expect(
      await File('${temporaryDirectory.path}/settings.json.broken').exists(),
      isTrue,
    );
  });
}
