import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sukashi_form/data/clip_repository.dart';
import 'package:sukashi_form/native/frame_extractor.g.dart';
import 'package:sukashi_form/pose/ios_vision_pose_detector_client.dart';
import 'package:sukashi_form/pose/pose_analysis_service.dart';
import 'package:sukashi_form/pose/pose_detector_client.dart';
import 'package:sukashi_form/pose/pose_model.dart';

void main() {
  test('画素座標は画像サイズで0-1に直し、既に正規化済みなら触らない', () {
    final pixels = normalizeImagePoint(80, 40, width: 100, height: 200);
    expect(pixels.x, closeTo(0.8, 0.0001));
    expect(pixels.y, closeTo(0.2, 0.0001));
    final normalized = normalizeImagePoint(0.4, 0.6, width: 100, height: 200);
    expect(normalized.x, 0.4);
    expect(normalized.y, 0.6);
  });

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

  test('全点の信頼度が0でも画面内の点は使う', () {
    const pose = PoseFrame(
      imageWidth: 100,
      imageHeight: 200,
      landmarks: <PoseJoint, PosePoint>{
        PoseJoint.leftHip: PosePoint(x: 0.4, y: 0.3, visibility: 0),
        PoseJoint.leftKnee: PosePoint(x: 0.4, y: 0.6, visibility: 0),
        PoseJoint.leftAnkle: PosePoint(x: 0.4, y: 0.9, visibility: 0),
      },
    );
    expect(pose.leftKneeAngle, closeTo(180, 0.01));
    expect(pose.visible(PoseJoint.leftKnee), isNotNull);
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

  test('関節名から PoseJoint を引ける', () {
    expect(poseJointNamed('leftKnee'), PoseJoint.leftKnee);
    expect(poseJointNamed('nose'), PoseJoint.nose);
    expect(poseJointNamed('unknown'), isNull);
  });

  test('iOS Vision の検出結果を骨格フレームへ写す', () {
    final pose = poseFrameFromNativeResult(
      NativePoseResult(
        found: true,
        imageWidth: 720,
        imageHeight: 1280,
        landmarks: <NativePoseLandmark>[
          NativePoseLandmark(
            joint: 'leftKnee',
            x: 0.4,
            y: 0.6,
            visibility: 0.9,
          ),
          NativePoseLandmark(
            joint: 'notAJoint',
            x: 0.1,
            y: 0.1,
            visibility: 1,
          ),
        ],
      ),
    );
    expect(pose, isNotNull);
    expect(pose!.imageWidth, 720);
    expect(pose.landmarks[PoseJoint.leftKnee]!.y, 0.6);
    expect(pose.landmarks.containsKey(PoseJoint.nose), isFalse);
  });

  test('人が見つからない Vision 結果は空として扱う', () {
    expect(
      poseFrameFromNativeResult(
        NativePoseResult(
          found: false,
          imageWidth: 1,
          imageHeight: 1,
          landmarks: <NativePoseLandmark>[],
        ),
      ),
      isNull,
    );
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
