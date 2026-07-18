import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sukashi_form/capture/grid_overlay.dart';
import 'package:sukashi_form/models/app_settings.dart';

void main() {
  test('グリッド種類ごとに描画パラメータが切り替わる', () {
    expect(CameraGridType.none.pattern.vertical, isEmpty);
    expect(CameraGridType.grid3x3.pattern.vertical, hasLength(2));
    expect(CameraGridType.grid4x4.pattern.vertical, hasLength(3));
    expect(CameraGridType.cross.pattern.vertical, <double>[0.5]);
    expect(CameraGridType.thirds.pattern.vertical, isEmpty);
    expect(CameraGridType.thirds.pattern.horizontal, hasLength(2));
  });

  testWidgets('GridOverlay更新時にpainterが再描画を要求する', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox.expand(
          child: GridOverlay(
            key: Key('overlay'),
            gridType: CameraGridType.grid3x3,
          ),
        ),
      ),
    );
    final first = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byKey(const Key('overlay')),
        matching: find.byType(CustomPaint),
      ),
    );
    final firstPainter = first.painter! as GridOverlayPainter;

    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox.expand(
          child: GridOverlay(
            key: Key('overlay'),
            gridType: CameraGridType.grid4x4,
          ),
        ),
      ),
    );
    final second = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byKey(const Key('overlay')),
        matching: find.byType(CustomPaint),
      ),
    );
    final secondPainter = second.painter! as GridOverlayPainter;

    expect(secondPainter.shouldRepaint(firstPainter), isTrue);
  });
}
