import 'package:flutter_test/flutter_test.dart';
import 'package:sukashi_form/comparison/comparison_controller.dart';
import 'package:sukashi_form/models/clip.dart';
import 'package:sukashi_form/pose/pose_export.dart';
import 'package:sukashi_form/pose/pose_model.dart';

void main() {
  test('切り取った範囲の全コマを秒つき座標と角度に変換する', () {
    final document = buildPoseMotionDocument(
      clip: _clip('a', memo: '左足荷重'),
      track: ComparisonTrack.evenlySpaced(
        clipId: 'a',
        rangeStartMs: 1200,
        rangeEndMs: 6200,
        paths: <String>['/tmp/frame_000000.jpg', '/tmp/frame_000001.jpg'],
      ),
      posesByPath: <String, PoseFrame>{
        '/tmp/frame_000000.jpg': _pose,
      },
    );

    expect(document['schema'], poseExportSchema);
    expect(document['kind'], 'motion-landmarks');
    expect(document['summary'], contains('動作解析'));
    expect(document['movement'], unlabeledPoseMovement);
    final clip = Map<String, Object?>.from(document['clip']! as Map);
    expect(clip['memo'], '左足荷重');
    expect(clip['durationMs'], 5000);
    final frames = (document['frames']! as List).cast<Map<String, Object?>>();
    expect(frames, hasLength(2));
    expect(frames[0]['t'], 0);
    expect(frames[0]['found'], isTrue);
    expect(frames[0]['head'], <double>[0.5, 0.08]);
    expect(frames[0]['leftKnee'], <double>[0.4, 0.6]);
    expect((frames[0]['angles']! as Map)['leftKnee'], 180);
    expect(frames[1]['found'], isFalse);
    expect(frames[1].containsKey('head'), isFalse);
  });

  test('動作説明が空なら未記入、書いてあればそのまま入れる', () {
    final blank = buildPoseMotionDocument(
      clip: _clip('a'),
      track: ComparisonTrack.evenlySpaced(
        clipId: 'a',
        rangeStartMs: 0,
        rangeEndMs: 1000,
        paths: <String>['/tmp/frame_000000.jpg'],
      ),
      posesByPath: const <String, PoseFrame>{},
      movement: '   ',
    );
    expect(blank['movement'], unlabeledPoseMovement);
    final labeled = buildPoseMotionDocument(
      clip: _clip('a'),
      track: ComparisonTrack.evenlySpaced(
        clipId: 'a',
        rangeStartMs: 0,
        rangeEndMs: 1000,
        paths: <String>['/tmp/frame_000000.jpg'],
      ),
      posesByPath: const <String, PoseFrame>{},
      movement: 'スノーボード 10mキッカー バックサイド720',
    );
    expect(labeled['movement'], 'スノーボード 10mキッカー バックサイド720');
  });

  test('ファイル名は日付とメモを使う', () {
    expect(
      poseExportFileName(_clip('clip-1', memo: '左足 荷重')),
      'sukashi-pose_0815_左足_荷重.json',
    );
    expect(poseExportFileName(_clip('clip-1')), 'sukashi-pose_0815_clip-1.json');
  });
}

const _pose = PoseFrame(
  imageWidth: 100,
  imageHeight: 200,
  landmarks: <PoseJoint, PosePoint>{
    PoseJoint.nose: PosePoint(x: 0.5, y: 0.08, visibility: 1),
    PoseJoint.leftShoulder: PosePoint(x: 0.4, y: 0.15, visibility: 1),
    PoseJoint.leftHip: PosePoint(x: 0.4, y: 0.35, visibility: 1),
    PoseJoint.leftKnee: PosePoint(x: 0.4, y: 0.6, visibility: 1),
    PoseJoint.leftAnkle: PosePoint(x: 0.4, y: 0.85, visibility: 1),
  },
);

Clip _clip(String id, {String? memo}) => Clip(
  id: id,
  videoPath: 'videos/$id.mp4',
  thumbnailPath: null,
  recordedAt: DateTime.utc(2026, 8, 15),
  durationMs: 5000,
  memo: memo,
);
