import 'package:flutter_test/flutter_test.dart';
import 'package:sukashi_form/capture/camera_zoom.dart';

void main() {
  test('ピンチ倍率は最小・最大の範囲に収める', () {
    expect(
      zoomAfterPinch(startZoom: 1, scale: 2.4, min: 1, max: 5),
      2.4,
    );
    expect(
      zoomAfterPinch(startZoom: 1, scale: 0.2, min: 1, max: 5),
      1,
    );
    expect(
      zoomAfterPinch(startZoom: 3, scale: 3, min: 1, max: 5),
      5,
    );
  });

  test('最大が最小より小さい場合は最小へ戻す', () {
    expect(
      zoomAfterPinch(startZoom: 2, scale: 1.5, min: 1, max: 0.5),
      1,
    );
  });

  test('ズーム可能かどうかはレンジ幅で判定する', () {
    expect(const CameraZoom(min: 1, max: 1, current: 1).canZoom, isFalse);
    expect(const CameraZoom(min: 1, max: 4, current: 1).canZoom, isTrue);
    expect(const CameraZoom(min: 1, max: 4, current: 2.3).label, '2.3x');
  });
}
