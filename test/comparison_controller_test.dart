import 'package:flutter_test/flutter_test.dart';
import 'package:sukashi_form/comparison/comparison_controller.dart';

void main() {
  test('異なるfps相当の2本で基準と交差範囲を時間msで計算する', () {
    final c = _controller();
    c.setReference('a', 1000);
    expect(c.pendingReferenceTimeMs('a'), 1000);
    expect(c.hasSynchronizedReference, isFalse);
    c.setReference('b', 2000);
    expect(c.hasSynchronizedReference, isTrue);
    expect(c.intersectionStartMs, -1000);
    expect(c.intersectionEndMs, 2000);
  });

  test('基準未設定は先頭揃え、片側だけでは同期を変えない', () {
    final c = _controller();
    expect(c.referenceTimeMs('a'), 0);
    expect(c.referenceTimeMs('b'), 0);
    expect(c.intersectionEndMs, 4000);
    c.setReference('a', 1200);
    expect(c.referenceTimeMs('a'), 0);
    c.cancelPendingReferences();
    expect(c.pendingReferenceTimeMs('a'), isNull);
  });

  test('nearest-frameは中点で後側を選び、時間増加に対して単調', () {
    final c = _controller();
    var previousA = -1;
    var previousB = -1;
    for (var time = 0; time <= 4000; time += 10) {
      c.seek(time.toDouble());
      expect(c.frameIndexFor('a'), greaterThanOrEqualTo(previousA));
      expect(c.frameIndexFor('b'), greaterThanOrEqualTo(previousB));
      previousA = c.frameIndexFor('a');
      previousB = c.frameIndexFor('b');
    }
    c.seek((5000 / 114) / 2);
    expect(c.frameIndexFor('a'), 1);
  });

  test('コマ送りは片方以上を変え、往復で同じフレームへ戻る', () {
    final c = _controller()..seek(1000);
    expect(c.stepIntervalMs, closeTo(4000 / 150, 0.001));
    final beforeA = c.frameIndexFor('a');
    final beforeB = c.frameIndexFor('b');
    c.stepForward();
    expect(
      c.frameIndexFor('a') != beforeA || c.frameIndexFor('b') != beforeB,
      isTrue,
    );
    c.stepBackward();
    expect(c.frameIndexFor('a'), beforeA);
    expect(c.frameIndexFor('b'), beforeB);
  });

  test('コマ送りは交差端で停止する', () {
    final c = _controller()..seek(4000);
    c.stepForward();
    expect(c.positionMs, 4000);
    c.seek(0);
    c.stepBackward();
    expect(c.positionMs, 0);
  });

  for (final speed in <double>[0.25, 0.5, 1]) {
    test('tickは${speed}xを反映する', () {
      final c = _controller()
        ..setSpeed(speed)
        ..setPlaying(true);
      c.tick(const Duration(seconds: 1));
      expect(c.positionMs, closeTo(1000 * speed, 0.001));
    });
  }

  test('ループONは先頭へ戻り、OFFは終端で停止', () {
    final looped = _controller()
      ..seek(3900)
      ..setPlaying(true);
    looped.tick(const Duration(milliseconds: 200));
    expect(looped.positionMs, closeTo(100, 0.001));
    final stopped = _controller()
      ..setLoop(false)
      ..seek(3900)
      ..setPlaying(true);
    stopped.tick(const Duration(milliseconds: 200));
    expect(stopped.positionMs, 4000);
    expect(stopped.isPlaying, isFalse);
  });

  test('交差が空でも例外にせず検出する', () {
    final c = _controller();
    c.setReference('a', -10000);
    c.setReference('b', 10000);
    expect(c.hasIntersection, isFalse);
    c.tick(const Duration(seconds: 1));
  });

  test('位置合わせ変換をクリップごとに保持する', () {
    final c = _controller();
    const value = AlignmentTransform(dx: 2, dy: -3, scale: 1.2, rotation: 0.1);
    c.setTransform('b', value);
    expect(c.transformFor('a'), const AlignmentTransform());
    expect(c.transformFor('b'), value);
  });

  test('取り込み直後の短い動画は展開した尺で範囲を決める', () {
    final imported = comparisonPlaybackRange(
      trimStartMs: null,
      trimEndMs: null,
      clipDurationMs: 0,
      extractedDurationMs: 3000,
    );
    expect(imported.startMs, 0);
    expect(imported.endMs, 3000);

    final trimmed = comparisonPlaybackRange(
      trimStartMs: 200,
      trimEndMs: 2800,
      clipDurationMs: 3000,
      extractedDurationMs: 3000,
    );
    expect(trimmed.startMs, 200);
    expect(trimmed.endMs, 2800);

    final empty = comparisonPlaybackRange(
      trimStartMs: null,
      trimEndMs: null,
      clipDurationMs: 0,
      extractedDurationMs: 0,
    );
    expect(empty.endMs, greaterThan(empty.startMs));
  });
}

ComparisonController _controller() => ComparisonController(
  trackA: ComparisonTrack.evenlySpaced(
    clipId: 'a',
    rangeStartMs: 0,
    rangeEndMs: 5000,
    paths: List<String>.generate(114, (i) => 'a/$i.jpg'),
  ),
  trackB: ComparisonTrack.evenlySpaced(
    clipId: 'b',
    rangeStartMs: 0,
    rangeEndMs: 4000,
    paths: List<String>.generate(150, (i) => 'b/$i.jpg'),
  ),
);
