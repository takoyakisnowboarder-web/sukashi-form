import 'package:flutter/material.dart';

class CompareStubScreen extends StatelessWidget {
  const CompareStubScreen({required this.clipIds, super.key});

  final List<String> clipIds;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('比較')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text('フェーズ4で実装'),
            const SizedBox(height: 12),
            Text('受け取ったクリップID: ${clipIds.join(', ')}'),
          ],
        ),
      ),
    );
  }
}
