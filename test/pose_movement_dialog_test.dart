import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sukashi_form/pose/pose_export.dart';
import 'package:sukashi_form/pose/pose_movement_dialog.dart';

void main() {
  testWidgets('動作説明を書いて返す', (tester) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await askPoseMovement(context);
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('pose-movement-field')),
      '  スノーボード 10mキッカー バックサイド720  ',
    );
    await tester.tap(find.byKey(const Key('pose-movement-confirm')));
    await tester.pumpAndSettle();
    expect(result, 'スノーボード 10mキッカー バックサイド720');
  });

  testWidgets('空欄なら未記入、キャンセルなら保存しない', (tester) async {
    String? result = 'keep';
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Column(
            children: <Widget>[
              TextButton(
                onPressed: () async {
                  result = await askPoseMovement(context);
                },
                child: const Text('open'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pose-movement-confirm')));
    await tester.pumpAndSettle();
    expect(result, unlabeledPoseMovement);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}
