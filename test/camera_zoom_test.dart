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

  test('端末の最大倍率が高くても5倍で打ち切る', () {
    expect(cameraZoomCap(deviceMax: 12, min: 1), 5);
    expect(cameraZoomCap(deviceMax: 3.5, min: 1), 3.5);
    final zoom = CameraZoom.fromDevice(min: 1, max: 10);
    expect(zoom.max, 5);
    expect(zoom.current, 1);
    expect(zoom.availablePresets, <double>[1, 2, 3, 4, 5]);
  });

  test('端末が届かない倍率は選択肢から外す', () {
    expect(
      availableZoomPresets(min: 1, max: 3.2),
      <double>[1, 2, 3],
    );
  });

  test('ズーム可能かどうかはレンジ幅で判定する', () {
    expect(const CameraZoom(min: 1, max: 1, current: 1).canZoom, isFalse);
    expect(const CameraZoom(min: 1, max: 4, current: 1).canZoom, isTrue);
    expect(const CameraZoom(min: 1, max: 4, current: 2).label, '2x');
    expect(const CameraZoom(min: 1, max: 4, current: 2.3).label, '2.3x');
  });
}
