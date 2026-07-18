import 'package:flutter_test/flutter_test.dart';
import 'package:sukashi_form/models/clip.dart';

void main() {
  test('旧JSONでは比較範囲がnullになる', () {
    final clip = Clip.fromJson(<String, dynamic>{
      'id': 'legacy',
      'videoPath': 'videos/legacy.mp4',
      'thumbnailPath': null,
      'recordedAt': '2026-07-18T00:00:00.000Z',
      'durationMs': 30000,
      'memo': null,
    });

    expect(clip.trimStartMs, isNull);
    expect(clip.trimEndMs, isNull);
  });

  for (final testCase in <({String name, int start, int end})>[
    (name: '負値', start: -1, end: 1000),
    (name: '逆転', start: 2000, end: 1000),
    (name: '10秒超', start: 0, end: 10001),
    (name: '動画長超', start: 25000, end: 31000),
  ]) {
    test('${testCase.name}の比較範囲を拒否する', () {
      expect(
        () => _clip().withComparisonRange(
          startMs: testCase.start,
          endMs: testCase.end,
        ),
        throwsArgumentError,
      );
    });
  }

  test('有効な範囲とリセットを扱える', () {
    final ranged = _clip().withComparisonRange(startMs: 12000, endMs: 17000);
    expect(ranged.comparisonRangeDurationMs, 5000);

    final reset = ranged.withComparisonRange(startMs: null, endMs: null);
    expect(reset.hasComparisonRange, isFalse);
  });
}

Clip _clip() => Clip(
  id: 'clip',
  videoPath: 'videos/clip.mp4',
  thumbnailPath: null,
  recordedAt: DateTime.utc(2026, 7, 18),
  durationMs: 30000,
  memo: null,
);
