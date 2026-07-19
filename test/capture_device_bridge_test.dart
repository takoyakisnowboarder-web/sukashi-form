import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sukashi_form/native/capture_device_bridge.dart';

void main() {
  test('録画完了時はライブラリ保存後にギャラリー保存を呼ぶ', () async {
    final bridge = _FakeCaptureDeviceBridge();
    final saver = RecordedVideoSaver(bridge);
    final calls = <String>[];

    final result = await saver.save(
      sourcePath: 'recorded.mp4',
      durationMs: 3200,
      saveToGallery: true,
      gallerySaveSupported: true,
      importIntoLibrary: (path, {required durationMs}) async {
        calls.add('library:$path:$durationMs');
      },
    );

    calls.addAll(bridge.savedPaths.map((path) => 'gallery:$path'));
    expect(calls, <String>[
      'library:recorded.mp4:3200',
      'gallery:recorded.mp4',
    ]);
    expect(result.gallerySaveFailed, isFalse);
  });

  test('設定OFFではギャラリー保存を呼ばない', () async {
    final bridge = _FakeCaptureDeviceBridge();
    final saver = RecordedVideoSaver(bridge);
    var imported = false;

    await saver.save(
      sourcePath: 'recorded.mp4',
      durationMs: 1000,
      saveToGallery: false,
      gallerySaveSupported: true,
      importIntoLibrary: (path, {required durationMs}) async {
        imported = true;
      },
    );

    expect(imported, isTrue);
    expect(bridge.savedPaths, isEmpty);
  });

  test('ギャラリー保存失敗でもクリップ保存は成功扱いになる', () async {
    final bridge = _FakeCaptureDeviceBridge(failGallerySave: true);
    final saver = RecordedVideoSaver(bridge);
    var imported = false;

    final result = await saver.save(
      sourcePath: 'recorded.mp4',
      durationMs: 1000,
      saveToGallery: true,
      gallerySaveSupported: true,
      importIntoLibrary: (path, {required durationMs}) async {
        imported = true;
      },
    );

    expect(imported, isTrue);
    expect(result.gallerySaveFailed, isTrue);
  });

  test('音量キー通知は有効中だけ1回ずつDartコールバックへ届く', () async {
    final bridge = _FakeCaptureDeviceBridge();
    var presses = 0;

    await bridge.enableVolumeKeyCapture(() => presses += 1);
    bridge.pressVolumeKey();
    bridge.pressVolumeKey();
    expect(presses, 2);

    await bridge.disableVolumeKeyCapture();
    bridge.pressVolumeKey();
    expect(presses, 2);
  });
}

class _FakeCaptureDeviceBridge implements CaptureDeviceBridge {
  _FakeCaptureDeviceBridge({this.failGallerySave = false});

  final bool failGallerySave;
  final List<String> savedPaths = <String>[];
  VoidCallback? _onVolumeKey;

  @override
  Future<void> disableVolumeKeyCapture() async {
    _onVolumeKey = null;
  }

  @override
  Future<void> enableVolumeKeyCapture(VoidCallback onPressed) async {
    _onVolumeKey = onPressed;
  }

  @override
  Future<bool> isGallerySaveSupported() async => true;

  @override
  Future<void> saveVideoToGallery(String absoluteVideoPath) async {
    savedPaths.add(absoluteVideoPath);
    if (failGallerySave) {
      throw StateError('gallery failed');
    }
  }

  void pressVolumeKey() => _onVolumeKey?.call();
}
