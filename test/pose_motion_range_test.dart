import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sukashi_form/data/clip_repository.dart';
import 'package:sukashi_form/models/app_settings.dart';
import 'package:sukashi_form/pose/pose_analysis_service.dart';
import 'package:sukashi_form/pose/pose_detector_client.dart';
import 'package:sukashi_form/pose/pose_model.dart';
import 'package:sukashi_form/pose/pose_motion_range.dart';

void main() {
  test('撮影の元動画は最大30秒、比較範囲は最大10秒', () {
    expect(AppSettings.recordingOptions, <int>[5, 10, 20, 30]);
    expect(motionRangeSourceMaxDurationMs, 30000);
    expect(motionRangeMaxDurationMs, 10000);
  });

  test('20秒録画の動きを10秒以内の比較範囲に切る', () {
    final times = _previewTimes(durationMs: 20000);
    final poses = <PoseFrame?>[
      for (var i = 0; i < times.length; i++)
        _pose(hipX: _burstX(i, start: 8, peak: 12, end: 15)),
    ];

    final guess = guessMotionRange(
      timesMs: times,
      poses: poses,
      clipDurationMs: 20000,
    );

    expect(guess, isNotNull);
    expect(guess!.endMs - guess.startMs, lessThanOrEqualTo(10000));
    expect(guess.startMs, greaterThanOrEqualTo(0));
    expect(guess.endMs, lessThanOrEqualTo(20000));
    expect(guess.peakMs, inInclusiveRange(guess.startMs, guess.endMs));
    expect(guess.startMs, lessThan(12000));
    expect(guess.endMs, greaterThan(8000));
  });

  test('30秒録画で動きが長いときは山場を含む10秒に収める', () {
    final times = _previewTimes(durationMs: 30000);
    final poses = <PoseFrame?>[
      for (var i = 0; i < times.length; i++)
        _pose(hipX: i == 12 ? 0.95 : (i.isEven ? 0.15 : 0.7)),
    ];

    final guess = guessMotionRange(
      timesMs: times,
      poses: poses,
      clipDurationMs: 30000,
    );

    expect(guess, isNotNull);
    expect(guess!.endMs - guess.startMs, 10000);
    expect(guess.peakMs, inInclusiveRange(guess.startMs, guess.endMs));
    expect(guess.startMs, greaterThan(0));
    expect(guess.endMs, lessThan(30000));
  });

  test('ほぼ動いていないクリップは区間を出さない', () {
    final times = _previewTimes(durationMs: 30000);
    final poses = <PoseFrame?>[
      for (var i = 0; i < times.length; i++) _pose(hipX: 0.4 + i * 0.001),
    ];

    expect(
      guessMotionRange(
        timesMs: times,
        poses: poses,
        clipDurationMs: 30000,
      ),
      isNull,
    );
  });

  test('骨格が無いクリップは区間を出さない', () {
    expect(
      guessMotionRange(
        timesMs: const <double>[0, 1000, 2000, 3000],
        poses: const <PoseFrame?>[null, null, null, null],
        clipDurationMs: 3000,
      ),
      isNull,
    );
  });

  test('山場が先頭でも0秒より前にはみ出さない', () {
    final times = _previewTimes(durationMs: 20000);
    final poses = <PoseFrame?>[
      for (var i = 0; i < times.length; i++)
        _pose(hipX: i <= 3 ? 0.2 + i * 0.22 : 0.85),
    ];

    final guess = guessMotionRange(
      timesMs: times,
      poses: poses,
      clipDurationMs: 20000,
    );

    expect(guess, isNotNull);
    expect(guess!.startMs, greaterThanOrEqualTo(0));
    expect(guess.endMs, lessThanOrEqualTo(20000));
    expect(guess.endMs - guess.startMs, lessThanOrEqualTo(10000));
  });

  test('プレビュー骨格から30秒クリップの動作区間を推定する', () async {
    final directory = await Directory.systemTemp.createTemp('motion_range_');
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final poses = <String, PoseFrame>{
      for (var i = 0; i < 24; i++)
        'frame_${i.toString().padLeft(6, '0')}.jpg': _pose(
          hipX: _burstX(i, start: 10, peak: 14, end: 17),
        ),
    };
    final analyzer = PoseMotionRangeAnalyzer(
      PoseAnalysisService(
        _ScriptedDetector(poses),
        PoseCacheRepository(
          ClipRepository(documentsDirectoryProvider: () async => directory),
        ),
      ),
    );

    final analysis = await analyzer.analyze(
      clipId: 'clip',
      framePaths: poses.keys.map((name) => '/tmp/$name').toList(),
      durationMs: motionRangeSourceMaxDurationMs,
    );

    expect(analysis.unsupported, isFalse);
    expect(analysis.guess, isNotNull);
    expect(
      analysis.guess!.endMs - analysis.guess!.startMs,
      lessThanOrEqualTo(10000),
    );
    expect(analysis.guess!.startMs, lessThan(18000));
    expect(analysis.guess!.endMs, greaterThan(12000));
  });

  test('非対応端末では unsupported を返す', () async {
    final directory = await Directory.systemTemp.createTemp(
      'motion_unsupported_',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    final analyzer = PoseMotionRangeAnalyzer(
      PoseAnalysisService(
        const UnsupportedPoseDetectorClient(),
        PoseCacheRepository(
          ClipRepository(documentsDirectoryProvider: () async => directory),
        ),
      ),
    );

    final analysis = await analyzer.analyze(
      clipId: 'clip',
      framePaths: const <String>['/tmp/a.jpg', '/tmp/b.jpg', '/tmp/c.jpg'],
      durationMs: 20000,
    );
    expect(analysis.unsupported, isTrue);
    expect(analysis.guess, isNull);
  });
}

List<double> _previewTimes({required int durationMs, int frameCount = 24}) {
  final interval = durationMs / frameCount;
  return <double>[for (var i = 0; i < frameCount; i++) interval * i];
}

double _burstX(int index, {int start = 6, int peak = 8, int end = 10}) {
  if (index <= start) {
    return 0.2;
  }
  if (index >= end) {
    return 0.85;
  }
  if (index == peak) {
    return 0.8;
  }
  final t = (index - start) / (end - start);
  return 0.2 + 0.65 * t;
}

PoseFrame _pose({required double hipX}) {
  return PoseFrame(
    imageWidth: 100,
    imageHeight: 200,
    landmarks: <PoseJoint, PosePoint>{
      PoseJoint.leftHip: PosePoint(x: hipX, y: 0.5, visibility: 1),
      PoseJoint.rightHip: PosePoint(x: hipX + 0.04, y: 0.5, visibility: 1),
      PoseJoint.leftWrist: PosePoint(x: hipX - 0.05, y: 0.28, visibility: 1),
    },
  );
}

class _ScriptedDetector implements PoseDetectorClient {
  _ScriptedDetector(this.poses);

  final Map<String, PoseFrame> poses;

  @override
  bool get isSupported => true;

  @override
  Future<PoseFrame?> detect(String imagePath) async {
    return poses[imagePath.replaceAll('\\', '/').split('/').last];
  }

  @override
  Future<void> close() async {}
}
