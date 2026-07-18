import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/frame_cache_service.dart';
import 'clip_providers.dart';

final frameExtractionClientProvider = Provider<FrameExtractionClient>((ref) {
  final client = PigeonFrameExtractionClient();
  ref.onDispose(client.dispose);
  return client;
});

final frameCacheRepositoryProvider = Provider<FrameCacheRepository>((ref) {
  return FrameCacheRepository(ref.watch(clipRepositoryProvider));
});

final frameCacheServiceProvider = Provider<FrameCacheService>((ref) {
  return FrameCacheService(
    ref.watch(clipRepositoryProvider),
    ref.watch(frameCacheRepositoryProvider),
    ref.watch(frameExtractionClientProvider),
  );
});
