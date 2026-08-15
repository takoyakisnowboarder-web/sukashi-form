import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../pose/pose_analysis_service.dart';
import '../pose/pose_clip_exporter.dart';
import '../pose/pose_detector_client.dart';
import '../pose/pose_export_sharer.dart';
import 'clip_providers.dart';
import 'frame_extraction_providers.dart';

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

final poseExportSharerProvider = Provider<PoseExportSharer>((ref) {
  return const SharePlusPoseExportSharer();
});

final poseClipExporterProvider = Provider<PoseClipExporter>((ref) {
  final frames = ref.watch(frameCacheServiceProvider);
  return PoseClipExporter(
    extract: (clip) => frames.startExtraction(clip).result,
    poses: ref.watch(poseAnalysisServiceProvider),
    sharer: ref.watch(poseExportSharerProvider),
  );
});
