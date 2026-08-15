import 'dart:ui';

import '../comparison/comparison_controller.dart';
import '../data/frame_cache_service.dart';
import '../models/clip.dart';
import 'pose_analysis_service.dart';
import 'pose_export.dart';
import 'pose_export_sharer.dart';
import 'pose_model.dart';

typedef PoseFrameExtractor = Future<FrameCacheResult> Function(Clip clip);

class PoseClipExporter {
  const PoseClipExporter({
    required PoseFrameExtractor extract,
    required PoseAnalysisService poses,
    required PoseExportSharer sharer,
  }) : _extract = extract,
       _poses = poses,
       _sharer = sharer;

  final PoseFrameExtractor _extract;
  final PoseAnalysisService _poses;
  final PoseExportSharer _sharer;

  Future<void> exportClip(
    Clip clip, {
    required String movement,
    Rect? sharePositionOrigin,
    void Function(String message)? onProgress,
  }) async {
    if (clip.isBroken) {
      throw const FormatException('この動画は書き出せません。');
    }
    if (clip.durationMs <= 0) {
      throw const FormatException('動画の長さがまだ分かっていません。');
    }
    onProgress?.call('フレームを準備しています…');
    final extracted = await _extract(clip);
    final range = comparisonPlaybackRange(
      trimStartMs: clip.trimStartMs,
      trimEndMs: clip.trimEndMs,
      clipDurationMs: clip.durationMs,
      extractedDurationMs: extracted.sourceDurationMs,
    );
    final track = ComparisonTrack.evenlySpaced(
      clipId: clip.id,
      rangeStartMs: range.startMs,
      rangeEndMs: range.endMs,
      paths: extracted.absoluteFramePaths,
    );
    onProgress?.call('座標を書き出しています…');
    final analysis = _poses.analyzeClip(
      clipId: clip.id,
      framePaths: track.frames.map((frame) => frame.path).toList(),
    );
    final detected = await analysis.result;
    final posesByPath = <String, PoseFrame>{
      for (final frame in track.frames)
        if (detected[frame.path] != null ||
            detected[PoseAnalysisService.keyForPath(frame.path)] != null)
          frame.path:
              detected[frame.path] ??
              detected[PoseAnalysisService.keyForPath(frame.path)]!,
    };
    await _sharer.shareJsonFile(
      fileName: poseExportFileName(clip),
      contents: encodePoseMotionDocument(
        buildPoseMotionDocument(
          clip: clip,
          track: track,
          posesByPath: posesByPath,
          movement: movement,
        ),
      ),
      sharePositionOrigin: sharePositionOrigin,
    );
  }
}
