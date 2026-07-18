import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';

import '../screens/capture_screen.dart';
import '../screens/compare_stub_screen.dart';
import '../screens/frame_extraction_debug_screen.dart';
import '../screens/library_screen.dart';

final appRouter = GoRouter(
  routes: <RouteBase>[
    GoRoute(path: '/', builder: (context, state) => const LibraryScreen()),
    GoRoute(
      path: '/capture',
      builder: (context, state) => const CaptureScreen(),
    ),
    GoRoute(
      path: '/compare',
      builder: (context, state) {
        final ids =
            state.uri.queryParameters['ids']
                ?.split(',')
                .where((id) => id.isNotEmpty)
                .toList(growable: false) ??
            <String>[];
        return CompareStubScreen(clipIds: ids);
      },
    ),
    if (kDebugMode)
      GoRoute(
        path: '/debug/frame-extraction/:clipId',
        builder: (context, state) =>
            FrameExtractionDebugScreen(clipId: state.pathParameters['clipId']!),
      ),
  ],
);
