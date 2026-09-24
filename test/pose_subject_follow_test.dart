import 'package:flutter_test/flutter_test.dart';
import 'package:sukashi_form/pose/pose_model.dart';
import 'package:sukashi_form/pose/pose_subject_follow.dart';

void main() {
  test('近い体勢を基準に、奥で小さくなった体を拡大する', () {
    final near = _body(shoulderY: 0.2, hipY: 0.5, ankleY: 0.85);
    final far = _body(shoulderY: 0.35, hipY: 0.5, ankleY: 0.68);
    final reference = poseSubjectSize(near)!;
    final follow = followSubject(pose: far, referenceSize: reference);

    expect(follow.scale, greaterThan(1.2));
    expect(follow.scale, lessThanOrEqualTo(subjectFollowMaxScale));
    expect(follow.centerX, closeTo(0.5, 0.05));
  });

  test('基準と同じ大きさなら拡大しない', () {
    final pose = _body(shoulderY: 0.2, hipY: 0.5, ankleY: 0.85);
    final follow = followSubject(
      pose: pose,
      referenceSize: poseSubjectSize(pose)!,
    );
    expect(follow.scale, 1);
  });

  test('骨格が無いコマは拡大しない', () {
    expect(
      followSubject(pose: null, referenceSize: 0.6),
      SubjectFollow.identity,
    );
    expect(referenceSubjectSize(const <PoseFrame?>[null]), isNull);
  });

  test('消える直前の骨格で拡大を固定し、いなくなったら元に戻す', () {
    final near = _body(shoulderY: 0.2, hipY: 0.5, ankleY: 0.85);
    final far = _body(shoulderY: 0.35, hipY: 0.5, ankleY: 0.68);
    final poses = <PoseFrame?>[null, near, far, null];
    final fixed = playbackFollow(poses: poses, index: 2);

    expect(fixed.scale, greaterThan(1));
    expect(playbackFollow(poses: poses, index: 0), fixed);
    expect(playbackFollow(poses: poses, index: 1), fixed);
    expect(playbackFollow(poses: poses, index: 3), SubjectFollow.identity);
  });

  test('クリップ内の一番大きい体を基準にする', () {
    final near = _body(shoulderY: 0.15, hipY: 0.5, ankleY: 0.9);
    final far = _body(shoulderY: 0.4, hipY: 0.5, ankleY: 0.65);
    expect(
      referenceSubjectSize(<PoseFrame?>[far, near]),
      poseSubjectSize(near),
    );
  });
}

PoseFrame _body({
  required double shoulderY,
  required double hipY,
  required double ankleY,
}) {
  return PoseFrame(
    imageWidth: 100,
    imageHeight: 200,
    landmarks: <PoseJoint, PosePoint>{
      PoseJoint.leftShoulder: PosePoint(x: 0.42, y: shoulderY, visibility: 1),
      PoseJoint.rightShoulder: PosePoint(x: 0.58, y: shoulderY, visibility: 1),
      PoseJoint.leftHip: PosePoint(x: 0.44, y: hipY, visibility: 1),
      PoseJoint.rightHip: PosePoint(x: 0.56, y: hipY, visibility: 1),
      PoseJoint.leftAnkle: PosePoint(x: 0.45, y: ankleY, visibility: 1),
      PoseJoint.rightAnkle: PosePoint(x: 0.55, y: ankleY, visibility: 1),
    },
  );
}
