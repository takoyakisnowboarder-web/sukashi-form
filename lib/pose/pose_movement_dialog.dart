import 'package:flutter/material.dart';

import 'pose_export.dart';

Future<String?> askPoseMovement(
  BuildContext context, {
  String? initialValue,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => PoseMovementDialog(initialValue: initialValue),
  );
}

class PoseMovementDialog extends StatefulWidget {
  const PoseMovementDialog({this.initialValue, super.key});

  final String? initialValue;

  @override
  State<PoseMovementDialog> createState() => _PoseMovementDialogState();
}

class _PoseMovementDialogState extends State<PoseMovementDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('この動作は何ですか？'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              'AIが座標の意味を分かるように、種目と技を書いてください。空欄でも保存できます。',
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('pose-movement-field'),
              controller: _controller,
              autofocus: true,
              maxLength: 120,
              maxLines: 3,
              minLines: 2,
              decoration: const InputDecoration(
                hintText: '例: スノーボード 10mキッカー バックサイド720',
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          key: const Key('pose-movement-confirm'),
          onPressed: () =>
              Navigator.pop(context, normalizePoseMovement(_controller.text)),
          child: const Text('保存する'),
        ),
      ],
    );
  }
}
