import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../pose/pose_analysis_service.dart';
import '../pose/pose_detector_client.dart';
import 'clip_providers.dart';

final poseDetectorClientProvider = Provider<PoseDetectorClient>((ref) {
  final client = createDefaultPoseDetectorClient();
  ref.onDispose(client.close);
  return client;
});

final poseCacheRepositoryProvider = Provider<PoseCacheRepository>((ref) {
  return PoseCacheRepository(ref.watch(clipRepositoryProvider));
});

final poseAnalysisServiceProvider = Provider<PoseAnalysisService>((ref) {
  return PoseAnalysisService(
    ref.watch(poseDetectorClientProvider),
    ref.watch(poseCacheRepositoryProvider),
  );
});
