import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sukashi_form/data/clip_gallery_saver.dart';
import 'package:sukashi_form/data/clip_repository.dart';
import 'package:sukashi_form/models/clip.dart';
import 'package:sukashi_form/native/capture_device_bridge.dart';

void main() {
  late Directory appDirectory;
  late ClipRepository repository;

  setUp(() async {
    appDirectory = await Directory.systemTemp.createTemp('sukashi_gallery_');
    repository = ClipRepository(
      documentsDirectoryProvider: () async => appDirectory,
    );
  });

  tearDown(() async {
    if (await appDirectory.exists()) {
      await appDirectory.delete(recursive: true);
    }
  });

  test('ライブラリのクリップを写真へコピーする', () async {
    final clip = _clip();
    final video = File(await repository.resolveAbsolutePath(clip.videoPath));
    await video.parent.create(recursive: true);
    await video.writeAsBytes(const <int>[1, 2, 3]);
    final bridge = _FakeCaptureDeviceBridge();
    final saver = ClipGallerySaver(bridge, repository);

    await saver.save(clip);

    expect(bridge.savedPaths, <String>[video.path]);
  });

  test('壊れたクリップは写真へ保存しない', () async {
    final saver = ClipGallerySaver(_FakeCaptureDeviceBridge(), repository);

    await expectLater(saver.save(_clip(isBroken: true)), throwsStateError);
  });

  test('対応確認が失敗したら非対応として扱う', () async {
    final saver = ClipGallerySaver(
      _FakeCaptureDeviceBridge(gallerySupported: false, throwOnSupportCheck: true),
      repository,
    );

    expect(await saver.isSupported(), isFalse);
  });
}

Clip _clip({bool isBroken = false}) {
  return Clip(
    id: 'solo',
    videoPath: 'videos/solo.mp4',
    thumbnailPath: null,
    recordedAt: DateTime(2026, 8, 16),
    durationMs: 3200,
    memo: null,
    isBroken: isBroken,
    validationError: isBroken ? 'empty_file' : null,
  );
}

class _FakeCaptureDeviceBridge implements CaptureDeviceBridge {
  _FakeCaptureDeviceBridge({
    this.gallerySupported = true,
    this.throwOnSupportCheck = false,
  });

  final bool gallerySupported;
  final bool throwOnSupportCheck;
  final List<String> savedPaths = <String>[];

  @override
  Future<void> disableVolumeKeyCapture() async {}

  @override
  Future<void> enableVolumeKeyCapture(VoidCallback onPressed) async {}

  @override
  Future<bool> isGallerySaveSupported() async {
    if (throwOnSupportCheck) {
      throw StateError('unavailable');
    }
    return gallerySupported;
  }

  @override
  Future<void> saveVideoToGallery(String absoluteVideoPath) async {
    savedPaths.add(absoluteVideoPath);
  }
}
