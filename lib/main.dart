import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router/app_router.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  PaintingBinding.instance.imageCache
    ..maximumSize = 24
    ..maximumSizeBytes = 64 << 20;
  runApp(const ProviderScope(child: SukashiFormApp()));
}

class SukashiFormApp extends StatelessWidget {
  const SukashiFormApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'スカシフォーム',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2563EB)),
        useMaterial3: true,
      ),
      routerConfig: appRouter,
    );
  }
}
