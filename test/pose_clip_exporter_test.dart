import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:sukashi_form/data/clip_repository.dart';
import 'package:sukashi_form/data/frame_cache_service.dart';
import 'package:sukashi_form/models/clip.dart';
import 'package:sukashi_form/pose/pose_analysis_service.dart';
import 'package:sukashi_form/pose/pose_clip_exporter.dart';
import 'package:sukashi_form/pose/pose_detector_client.dart';
import 'package:sukashi_form/pose/pose_export.dart';
import 'package:sukashi_form/pose/pose_export_sharer.dart';
import 'package:sukashi_form/pose/pose_model.dart';

void main() {
  test('1本分だけJSONを共有する', () async {
    final directory = await Directory.systemTemp.createTemp('pose_export_');
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final sharer = _RecordingSharer();
    final exporter = PoseClipExporter(
      extract: (clip) async => const FrameCacheResult(
        isComplete: true,
        frameCount: 2,
        sourceDurationMs: 5000,
        sourceFps: 30,
        absoluteFramePaths: <String>[
          '/tmp/frame_000000.jpg',
          '/tmp/frame_000001.jpg',
        ],
        fromCache: true,
      ),
      poses: PoseAnalysisService(
        _OneClipDetector(),
        PoseCacheRepository(
          ClipRepository(documentsDirectoryProvider: () async => directory),
        ),
      ),
      sharer: sharer,
    );

    await exporter.exportClip(
      Clip(
        id: 'solo',
        videoPath: 'videos/solo.mp4',
        thumbnailPath: null,
        recordedAt: DateTime.utc(2026, 8, 15),
        durationMs: 5000,
        memo: '左足荷重',
      ),
      movement: 'スノーボード 10mキッカー バックサイド720',
    );

    expect(sharer.fileName, 'sukashi-pose_0815_左足荷重.json');
    expect(sharer.contents, contains(poseExportSchema));
    expect(sharer.contents, contains('"id": "solo"'));
    expect(sharer.contents, contains('バックサイド720'));
    expect(sharer.contents, isNot(contains('"id": "other"')));
  });

  test('壊れたクリップは書き出さない', () async {
    final exporter = PoseClipExporter(
      extract: (_) async => throw StateError('should not extract'),
      poses: PoseAnalysisService(
        const UnsupportedPoseDetectorClient(),
        PoseCacheRepository(ClipRepository()),
      ),
      sharer: _RecordingSharer(),
    );

    expect(
      () => exporter.exportClip(
        Clip(
          id: 'broken',
          videoPath: 'videos/broken.mp4',
          thumbnailPath: null,
          recordedAt: DateTime.utc(2026, 8, 15),
          durationMs: 5000,
          memo: null,
          isBroken: true,
        ),
        movement: unlabeledPoseMovement,
      ),
      throwsA(isA<FormatException>()),
    );
  });
}

class _RecordingSharer implements PoseExportSharer {
  String? fileName;
  String? contents;

  @override
  Future<void> shareJsonFile({
    required String fileName,
    required String contents,
    Rect? sharePositionOrigin,
  }) async {
    this.fileName = fileName;
    this.contents = contents;
  }
}

class _OneClipDetector implements PoseDetectorClient {
  @override
  bool get isSupported => true;

  @override
  Future<PoseFrame?> detect(String imagePath) async {
    return const PoseFrame(
      imageWidth: 100,
      imageHeight: 200,
      landmarks: <PoseJoint, PosePoint>{
        PoseJoint.nose: PosePoint(x: 0.5, y: 0.1, visibility: 1),
        PoseJoint.leftHip: PosePoint(x: 0.4, y: 0.4, visibility: 1),
        PoseJoint.leftKnee: PosePoint(x: 0.4, y: 0.6, visibility: 1),
        PoseJoint.leftAnkle: PosePoint(x: 0.4, y: 0.8, visibility: 1),
      },
    );
  }

  @override
  Future<void> close() async {}
}
