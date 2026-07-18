import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';

import '../screens/capture_screen.dart';
import '../screens/compare_screen.dart';
import '../screens/comparison_range_screen.dart';
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
      path: '/comparison-range/:clipId',
      builder: (context, state) =>
          ComparisonRangeScreen(clipId: state.pathParameters['clipId']!),
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
        return CompareScreen(clipIds: ids);
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
