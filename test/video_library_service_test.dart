import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sukashi_form/data/clip_repository.dart';
import 'package:sukashi_form/data/video_library_service.dart';

void main() {
  test('取り込み動画をvideos配下へコピーし相対パスを返す', () async {
    final appDirectory = await Directory.systemTemp.createTemp(
      'sukashi_video_library_',
    );
    final sourceDirectory = await Directory.systemTemp.createTemp(
      'sukashi_video_source_',
    );
    addTearDown(() async {
      if (await appDirectory.exists()) {
        await appDirectory.delete(recursive: true);
      }
      if (await sourceDirectory.exists()) {
        await sourceDirectory.delete(recursive: true);
      }
    });
    final source = File('${sourceDirectory.path}/slow-motion.MP4');
    await source.writeAsBytes(<int>[1, 2, 3, 4]);
    final repository = ClipRepository(
      documentsDirectoryProvider: () async => appDirectory,
    );
    final service = VideoLibraryService(repository);

    final clip = await service.copyIntoLibrary(source.path, durationMs: 0);

    expect(clip.videoPath, startsWith('videos/'));
    expect(clip.videoPath, endsWith('.mp4'));
    expect(clip.durationMs, 0);
    final copied = File(await repository.resolveAbsolutePath(clip.videoPath));
    expect(await copied.readAsBytes(), <int>[1, 2, 3, 4]);
    await source.delete();
    expect(await copied.exists(), isTrue);
  });
}
