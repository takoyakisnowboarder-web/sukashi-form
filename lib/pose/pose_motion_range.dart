import 'dart:math' as math;

import '../comparison/comparison_controller.dart';
import 'pose_analysis_service.dart';
import 'pose_model.dart';

/// In-app recording is 5/10/20/30s. Auto-cut is tuned for those source lengths.
const motionRangeSourceMaxDurationMs = 30000;
const motionRangeMaxDurationMs = 10000;
const motionRangeMinDurationMs = 2000;
const motionRangePaddingMs = 600;
const motionRangePreviewCacheSuffix = '__range_preview';

/// Normalized image units per second. Below this, treat the clip as idle.
const _minPeakSpeed = 0.12;
const _minThreshold = 0.08;
const _thresholdPeakRatio = 0.25;
const _leadInFraction = 0.75;

const _motionJoints = <PoseJoint>[
  PoseJoint.leftHip,
  PoseJoint.rightHip,
  PoseJoint.leftWrist,
  PoseJoint.rightWrist,
  PoseJoint.leftAnkle,
  PoseJoint.rightAnkle,
  PoseJoint.leftShoulder,
  PoseJoint.rightShoulder,
];

class MotionRangeGuess {
  const MotionRangeGuess({
    required this.startMs,
    required this.endMs,
    required this.peakMs,
  });

  final int startMs;
  final int endMs;
  final int peakMs;
}

class MotionRangeAnalysis {
  const MotionRangeAnalysis.found(this.guess) : unsupported = false;

  const MotionRangeAnalysis.notFound() : guess = null, unsupported = false;

  const MotionRangeAnalysis.unsupported() : guess = null, unsupported = true;

  final MotionRangeGuess? guess;
  final bool unsupported;
}

abstract interface class MotionRangeAnalyzer {
  Future<MotionRangeAnalysis> analyze({
    required String clipId,
    required List<String> framePaths,
    required int durationMs,
  });
}

class PoseMotionRangeAnalyzer implements MotionRangeAnalyzer {
  PoseMotionRangeAnalyzer(this._poses);

  final PoseAnalysisService _poses;

  @override
  Future<MotionRangeAnalysis> analyze({
    required String clipId,
    required List<String> framePaths,
    required int durationMs,
  }) async {
    if (!_poses.isSupported) {
      return const MotionRangeAnalysis.unsupported();
    }
    if (framePaths.length < 3 || durationMs <= 0) {
      return const MotionRangeAnalysis.notFound();
    }
    final track = ComparisonTrack.evenlySpaced(
      clipId: clipId,
      rangeStartMs: 0,
      rangeEndMs: durationMs.toDouble(),
      paths: framePaths,
    );
    final detected = await _poses
        .analyzeClip(
          clipId: '$clipId$motionRangePreviewCacheSuffix',
          framePaths: framePaths,
        )
        .result;
    final poses = <PoseFrame?>[
      for (final frame in track.frames)
        _usablePose(
          detected[frame.path] ??
              detected[PoseAnalysisService.keyForPath(frame.path)],
        ),
    ];
    final guess = guessMotionRange(
      timesMs: track.frames.map((frame) => frame.timeMs).toList(growable: false),
      poses: poses,
      clipDurationMs: durationMs,
    );
    if (guess == null) {
      return const MotionRangeAnalysis.notFound();
    }
    return MotionRangeAnalysis.found(guess);
  }
}

MotionRangeGuess? guessMotionRange({
  required List<double> timesMs,
  required List<PoseFrame?> poses,
  required int clipDurationMs,
  int maxDurationMs = motionRangeMaxDurationMs,
  int minDurationMs = motionRangeMinDurationMs,
  int paddingMs = motionRangePaddingMs,
}) {
  if (timesMs.length != poses.length ||
      timesMs.length < 3 ||
      clipDurationMs <= 0) {
    return null;
  }
  final speeds = motionSpeeds(timesMs: timesMs, poses: poses);
  var peakIndex = 0;
  var peakSpeed = 0.0;
  for (var i = 1; i < speeds.length; i++) {
    if (speeds[i] > peakSpeed) {
      peakSpeed = speeds[i];
      peakIndex = i;
    }
  }
  if (peakSpeed < _minPeakSpeed) {
    return null;
  }
  final highIndexes = <int>[
    for (var i = 1; i < speeds.length; i++)
      if (speeds[i] >= peakSpeed * 0.9) i,
  ];
  peakIndex = highIndexes[highIndexes.length ~/ 2];
  final threshold = math.max(_minThreshold, peakSpeed * _thresholdPeakRatio);
  var startIndex = peakIndex;
  var endIndex = peakIndex;
  while (startIndex > 1) {
    if (_isActive(speeds, startIndex - 1, threshold) ||
        _isActive(speeds, startIndex - 2, threshold)) {
      startIndex -= 1;
    } else {
      break;
    }
  }
  while (endIndex < speeds.length - 1) {
    if (_isActive(speeds, endIndex + 1, threshold) ||
        _isActive(speeds, endIndex + 2, threshold)) {
      endIndex += 1;
    } else {
      break;
    }
  }
  final peakMs = timesMs[peakIndex].round().clamp(0, clipDurationMs);
  var startMs = timesMs[startIndex].round() - paddingMs;
  var endMs = timesMs[endIndex].round() + paddingMs;
  final fitted = _fitDuration(
    startMs: startMs,
    endMs: endMs,
    peakMs: peakMs,
    clipDurationMs: clipDurationMs,
    maxDurationMs: math.min(maxDurationMs, clipDurationMs),
    minDurationMs: math.min(minDurationMs, clipDurationMs),
  );
  startMs = fitted.startMs;
  endMs = fitted.endMs;
  if (endMs <= startMs) {
    return null;
  }
  return MotionRangeGuess(startMs: startMs, endMs: endMs, peakMs: peakMs);
}

List<double> motionSpeeds({
  required List<double> timesMs,
  required List<PoseFrame?> poses,
}) {
  final speeds = List<double>.filled(poses.length, 0);
  for (var i = 1; i < poses.length; i++) {
    final dtSeconds = (timesMs[i] - timesMs[i - 1]) / 1000;
    speeds[i] = _pairSpeed(poses[i - 1], poses[i], dtSeconds) ?? 0;
  }
  return speeds;
}

bool _isActive(List<double> speeds, int index, double threshold) {
  return index >= 0 && index < speeds.length && speeds[index] >= threshold;
}

double? _pairSpeed(PoseFrame? previous, PoseFrame? current, double dtSeconds) {
  if (previous == null || current == null || dtSeconds <= 0) {
    return null;
  }
  var best = 0.0;
  var any = false;
  for (final joint in _motionJoints) {
    final speed = _pointSpeed(
      previous.visible(joint),
      current.visible(joint),
      dtSeconds,
    );
    if (speed == null) {
      continue;
    }
    any = true;
    if (speed > best) {
      best = speed;
    }
  }
  final previousHip = _hipMidpoint(previous);
  final currentHip = _hipMidpoint(current);
  if (previousHip != null && currentHip != null) {
    any = true;
    final dx = currentHip.x - previousHip.x;
    final dy = currentHip.y - previousHip.y;
    final speed = math.sqrt(dx * dx + dy * dy) / dtSeconds;
    if (speed > best) {
      best = speed;
    }
  }
  return any ? best : null;
}

double? _pointSpeed(PosePoint? previous, PosePoint? current, double dtSeconds) {
  if (previous == null || current == null) {
    return null;
  }
  final dx = current.x - previous.x;
  final dy = current.y - previous.y;
  return math.sqrt(dx * dx + dy * dy) / dtSeconds;
}

({double x, double y})? _hipMidpoint(PoseFrame pose) {
  final left = pose.visible(PoseJoint.leftHip);
  final right = pose.visible(PoseJoint.rightHip);
  if (left != null && right != null) {
    return (x: (left.x + right.x) / 2, y: (left.y + right.y) / 2);
  }
  if (left != null) {
    return (x: left.x, y: left.y);
  }
  if (right != null) {
    return (x: right.x, y: right.y);
  }
  return null;
}

PoseFrame? _usablePose(PoseFrame? pose) {
  if (pose == null || pose.landmarks.isEmpty) {
    return null;
  }
  return pose;
}

({int startMs, int endMs}) _fitDuration({
  required int startMs,
  required int endMs,
  required int peakMs,
  required int clipDurationMs,
  required int maxDurationMs,
  required int minDurationMs,
}) {
  var start = startMs.clamp(0, clipDurationMs);
  var end = endMs.clamp(0, clipDurationMs);
  if (end - start > maxDurationMs) {
    final after = (maxDurationMs * (1 - _leadInFraction)).round();
    end = math.min(clipDurationMs, peakMs + after);
    start = end - maxDurationMs;
    if (start < 0) {
      start = 0;
      end = math.min(clipDurationMs, maxDurationMs);
    }
  }
  if (end - start < minDurationMs && clipDurationMs >= minDurationMs) {
    final extra = minDurationMs - (end - start);
    start = math.max(0, start - extra ~/ 2);
    end = math.min(clipDurationMs, start + minDurationMs);
    if (end - start < minDurationMs) {
      start = math.max(0, end - minDurationMs);
    }
  }
  if (peakMs < start) {
    start = math.max(0, peakMs);
    end = math.min(clipDurationMs, math.max(end, start + minDurationMs));
    if (end - start > maxDurationMs) {
      end = start + maxDurationMs;
    }
  }
  if (peakMs > end) {
    end = math.min(clipDurationMs, peakMs);
    start = math.max(0, math.min(start, end - minDurationMs));
    if (end - start > maxDurationMs) {
      start = end - maxDurationMs;
    }
  }
  return (startMs: start, endMs: end);
}
