import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sukashi_form/data/clip_repository.dart';
import 'package:sukashi_form/pose/pose_analysis_service.dart';
import 'package:sukashi_form/pose/pose_detector_client.dart';
import 'package:sukashi_form/pose/pose_model.dart';

void main() {
  test('膝・腰・足の角度を可視点から計算する', () {
    const pose = PoseFrame(
      imageWidth: 100,
      imageHeight: 200,
      landmarks: <PoseJoint, PosePoint>{
        PoseJoint.leftHip: PosePoint(x: 0.4, y: 0.3, visibility: 1),
        PoseJoint.leftKnee: PosePoint(x: 0.4, y: 0.6, visibility: 1),
        PoseJoint.leftAnkle: PosePoint(x: 0.4, y: 0.9, visibility: 1),
        PoseJoint.leftShoulder: PosePoint(x: 0.4, y: 0.1, visibility: 1),
        PoseJoint.leftHeel: PosePoint(x: 0.35, y: 0.95, visibility: 1),
        PoseJoint.leftFootIndex: PosePoint(x: 0.5, y: 0.95, visibility: 1),
      },
    );
    expect(pose.leftKneeAngle, closeTo(180, 0.01));
    expect(pose.leftHipAngle, closeTo(180, 0.01));
    expect(pose.leftFootAngle, isNotNull);
    expect(pose.rightKneeAngle, isNull);
  });

  test('可視でない点は角度計算から除外する', () {
    const pose = PoseFrame(
      imageWidth: 100,
      imageHeight: 200,
      landmarks: <PoseJoint, PosePoint>{
        PoseJoint.leftHip: PosePoint(x: 0.4, y: 0.3, visibility: 1),
        PoseJoint.leftKnee: PosePoint(x: 0.4, y: 0.6, visibility: 0.1),
        PoseJoint.leftAnkle: PosePoint(x: 0.4, y: 0.9, visibility: 1),
      },
    );
    expect(pose.leftKneeAngle, isNull);
  });

  test('解析結果を端末内キャッシュへ往復保存する', () async {
    final directory = await Directory.systemTemp.createTemp('pose_cache_');
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final repository = ClipRepository(
      documentsDirectoryProvider: () async => directory,
    );
    final cache = PoseCacheRepository(repository);
    const pose = PoseFrame(
      imageWidth: 320,
      imageHeight: 180,
      landmarks: <PoseJoint, PosePoint>{
        PoseJoint.nose: PosePoint(x: 0.5, y: 0.2, visibility: 0.9),
      },
    );
    await cache.save('clip-a', <String, PoseFrame>{'frame_000000.jpg': pose});
    final loaded = await cache.load('clip-a');
    expect(loaded['frame_000000.jpg']!.imageWidth, 320);
    expect(loaded['frame_000000.jpg']!.landmarks[PoseJoint.nose]!.x, 0.5);
  });

  test('未解析フレームだけ検出してキャッシュする', () async {
    final directory = await Directory.systemTemp.createTemp('pose_analyze_');
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final repository = ClipRepository(
      documentsDirectoryProvider: () async => directory,
    );
    final detector = _CountingDetector();
    final service = PoseAnalysisService(
      detector,
      PoseCacheRepository(repository),
    );
    final first = service.analyzeClip(
      clipId: 'a',
      framePaths: <String>['/tmp/frame_000000.jpg', '/tmp/frame_000001.jpg'],
    );
    final firstResult = await first.result;
    expect(detector.calls, 2);
    expect(firstResult.length, 2);

    final second = service.analyzeClip(
      clipId: 'a',
      framePaths: <String>['/tmp/frame_000000.jpg', '/tmp/frame_000001.jpg'],
    );
    await second.result;
    expect(detector.calls, 2);
  });
}

class _CountingDetector implements PoseDetectorClient {
  int calls = 0;

  @override
  bool get isSupported => true;

  @override
  Future<PoseFrame?> detect(String imagePath) async {
    calls += 1;
    return const PoseFrame(
      imageWidth: 10,
      imageHeight: 10,
      landmarks: <PoseJoint, PosePoint>{
        PoseJoint.nose: PosePoint(x: 0.5, y: 0.2, visibility: 1),
      },
    );
  }

  @override
  Future<void> close() async {}
}
