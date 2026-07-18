import 'dart:math' as math;

class ComparisonFrame {
  const ComparisonFrame({required this.path, required this.timeMs});
  final String path;
  final double timeMs;
}

class ComparisonTrack {
  ComparisonTrack({
    required this.clipId,
    required this.rangeStartMs,
    required this.rangeEndMs,
    required List<ComparisonFrame> frames,
  }) : frames = List<ComparisonFrame>.unmodifiable(frames) {
    if (rangeStartMs < 0 || rangeEndMs <= rangeStartMs || frames.isEmpty) {
      throw ArgumentError('Invalid comparison track.');
    }
    var previous = double.negativeInfinity;
    for (final frame in frames) {
      if (frame.timeMs < rangeStartMs ||
          frame.timeMs > rangeEndMs ||
          frame.timeMs < previous) {
        throw ArgumentError('Frames must be sorted inside the track range.');
      }
      previous = frame.timeMs;
    }
  }

  factory ComparisonTrack.evenlySpaced({
    required String clipId,
    required double rangeStartMs,
    required double rangeEndMs,
    required List<String> paths,
  }) {
    if (paths.isEmpty) {
      throw ArgumentError.value(paths, 'paths', 'Must not be empty.');
    }
    final interval = (rangeEndMs - rangeStartMs) / paths.length;
    return ComparisonTrack(
      clipId: clipId,
      rangeStartMs: rangeStartMs,
      rangeEndMs: rangeEndMs,
      frames: List<ComparisonFrame>.generate(
        paths.length,
        (index) => ComparisonFrame(
          path: paths[index],
          timeMs: rangeStartMs + interval * index,
        ),
        growable: false,
      ),
    );
  }

  final String clipId;
  final double rangeStartMs;
  final double rangeEndMs;
  final List<ComparisonFrame> frames;
  double get nominalFrameIntervalMs =>
      (rangeEndMs - rangeStartMs) / frames.length;
}

class AlignmentTransform {
  const AlignmentTransform({
    this.dx = 0,
    this.dy = 0,
    this.scale = 1,
    this.rotation = 0,
  });
  final double dx;
  final double dy;
  final double scale;
  final double rotation;

  Map<String, Object> toJson() => <String, Object>{
    'dx': dx,
    'dy': dy,
    'scale': scale,
    'rotation': rotation,
  };

  factory AlignmentTransform.fromJson(Map<String, dynamic> json) {
    final value = AlignmentTransform(
      dx: (json['dx'] as num).toDouble(),
      dy: (json['dy'] as num).toDouble(),
      scale: (json['scale'] as num).toDouble(),
      rotation: (json['rotation'] as num).toDouble(),
    );
    if (!value.dx.isFinite ||
        !value.dy.isFinite ||
        !value.scale.isFinite ||
        value.scale <= 0 ||
        !value.rotation.isFinite) {
      throw const FormatException('Invalid alignment transform.');
    }
    return value;
  }

  @override
  bool operator ==(Object other) =>
      other is AlignmentTransform &&
      other.dx == dx &&
      other.dy == dy &&
      other.scale == scale &&
      other.rotation == rotation;
  @override
  int get hashCode => Object.hash(dx, dy, scale, rotation);
}

class ComparisonController {
  ComparisonController({
    required this.trackA,
    required this.trackB,
    Map<String, double>? referenceTimesMs,
    Map<String, AlignmentTransform>? transforms,
  }) : _transforms = <String, AlignmentTransform>{
         trackA.clipId:
             transforms?[trackA.clipId] ?? const AlignmentTransform(),
         trackB.clipId:
             transforms?[trackB.clipId] ?? const AlignmentTransform(),
       } {
    if (trackA.clipId == trackB.clipId) {
      throw ArgumentError('Comparison requires two different clips.');
    }
    final a = referenceTimesMs?[trackA.clipId];
    final b = referenceTimesMs?[trackB.clipId];
    if (a != null && b != null) {
      _references[trackA.clipId] = a;
      _references[trackB.clipId] = b;
      _hasSynchronizedReference = true;
    }
    _recalculateIntersection(resetPosition: true);
  }

  final ComparisonTrack trackA;
  final ComparisonTrack trackB;
  final Map<String, double> _references = <String, double>{};
  final Map<String, double> _pendingReferences = <String, double>{};
  final Map<String, AlignmentTransform> _transforms;
  double _positionMs = 0;
  double _speed = 1;
  bool _isPlaying = false;
  bool _loop = true;
  bool _hasSynchronizedReference = false;
  double _intersectionStartMs = 0;
  double _intersectionEndMs = 0;
  bool _hasIntersection = true;
  final List<double> _backwardUndoPositions = <double>[];
  final List<double> _forwardRedoPositions = <double>[];

  double get positionMs => _positionMs;
  double get speed => _speed;
  bool get isPlaying => _isPlaying;
  bool get loop => _loop;
  bool get hasSynchronizedReference => _hasSynchronizedReference;
  bool get hasIntersection => _hasIntersection;
  double get intersectionStartMs => _intersectionStartMs;
  double get intersectionEndMs => _intersectionEndMs;
  double get stepIntervalMs =>
      math.min(trackA.nominalFrameIntervalMs, trackB.nominalFrameIntervalMs);
  double referenceTimeMs(String clipId) =>
      _references[clipId] ?? _track(clipId).rangeStartMs;
  double? pendingReferenceTimeMs(String clipId) => _pendingReferences[clipId];
  AlignmentTransform transformFor(String clipId) => _transforms[clipId]!;
  Map<String, AlignmentTransform> get transforms =>
      Map<String, AlignmentTransform>.unmodifiable(_transforms);
  Map<String, double> get synchronizedReferences => _hasSynchronizedReference
      ? Map<String, double>.unmodifiable(_references)
      : const <String, double>{};

  void setTransform(String clipId, AlignmentTransform transform) {
    _track(clipId);
    _transforms[clipId] = transform;
  }

  void setReference(String clipId, double timeMs) {
    _track(clipId);
    if (!timeMs.isFinite) throw ArgumentError.value(timeMs, 'timeMs');
    _pendingReferences[clipId] = timeMs;
    if (_pendingReferences.containsKey(trackA.clipId) &&
        _pendingReferences.containsKey(trackB.clipId)) {
      _references
        ..clear()
        ..addAll(_pendingReferences);
      _pendingReferences.clear();
      _hasSynchronizedReference = true;
      _recalculateIntersection(resetPosition: true);
    }
  }

  void cancelPendingReferences() => _pendingReferences.clear();
  void resetReferences() {
    _references.clear();
    _pendingReferences.clear();
    _hasSynchronizedReference = false;
    _recalculateIntersection(resetPosition: true);
  }

  void setPlaying(bool value) => _isPlaying = value && _hasIntersection;
  void togglePlaying() => setPlaying(!_isPlaying);
  void setLoop(bool value) => _loop = value;
  void setSpeed(double value) {
    if (value != 0.25 && value != 0.5 && value != 1) {
      throw ArgumentError.value(value, 'value', 'Unsupported speed.');
    }
    _speed = value;
  }

  void seek(double valueMs) {
    _clearStepHistory();
    _seekWithoutHistory(valueMs);
  }

  void tick(Duration elapsed) {
    if (!_isPlaying || !_hasIntersection || elapsed <= Duration.zero) return;
    _clearStepHistory();
    final length = _intersectionEndMs - _intersectionStartMs;
    if (length <= 0) {
      _positionMs = _intersectionStartMs;
      _isPlaying = false;
      return;
    }
    final next = _positionMs + elapsed.inMicroseconds / 1000 * _speed;
    if (next <= _intersectionEndMs) {
      _positionMs = next;
    } else if (_loop) {
      _positionMs =
          _intersectionStartMs + ((next - _intersectionStartMs) % length);
    } else {
      _positionMs = _intersectionEndMs;
      _isPlaying = false;
    }
  }

  int frameIndexFor(String clipId) {
    final track = _track(clipId);
    return _nearestFrameIndex(
      track.frames,
      referenceTimeMs(clipId) + _positionMs,
    );
  }

  ComparisonFrame frameFor(String clipId) =>
      _track(clipId).frames[frameIndexFor(clipId)];
  void stepForward() {
    if (_forwardRedoPositions.isNotEmpty) {
      _backwardUndoPositions.add(_positionMs);
      _positionMs = _forwardRedoPositions.removeLast();
      return;
    }
    _step(forward: true);
  }

  void stepBackward() {
    if (_backwardUndoPositions.isNotEmpty) {
      _forwardRedoPositions.add(_positionMs);
      _positionMs = _backwardUndoPositions.removeLast();
      return;
    }
    _step(forward: false);
  }

  void _step({required bool forward}) {
    if (!_hasIntersection) return;
    _isPlaying = false;
    final old = _positionMs;
    _seekWithoutHistory(
      _positionMs + (forward ? stepIntervalMs : -stepIntervalMs),
    );
    if (_positionMs == old) return;
    if (forward) {
      _backwardUndoPositions.add(old);
      _forwardRedoPositions.clear();
    } else {
      _forwardRedoPositions.add(old);
      _backwardUndoPositions.clear();
    }
  }

  void _recalculateIntersection({required bool resetPosition}) {
    _intersectionStartMs = math.max(
      trackA.rangeStartMs - referenceTimeMs(trackA.clipId),
      trackB.rangeStartMs - referenceTimeMs(trackB.clipId),
    );
    _intersectionEndMs = math.min(
      trackA.rangeEndMs - referenceTimeMs(trackA.clipId),
      trackB.rangeEndMs - referenceTimeMs(trackB.clipId),
    );
    _hasIntersection = _intersectionStartMs <= _intersectionEndMs;
    _isPlaying = false;
    _clearStepHistory();
    if (!_hasIntersection) {
      _positionMs = 0;
    } else if (resetPosition) {
      _positionMs = 0.0.clamp(_intersectionStartMs, _intersectionEndMs);
    } else {
      _seekWithoutHistory(_positionMs);
    }
  }

  void _seekWithoutHistory(double valueMs) {
    if (_hasIntersection) {
      _positionMs = valueMs.clamp(_intersectionStartMs, _intersectionEndMs);
    }
  }

  void _clearStepHistory() {
    _backwardUndoPositions.clear();
    _forwardRedoPositions.clear();
  }

  ComparisonTrack _track(String clipId) {
    if (clipId == trackA.clipId) return trackA;
    if (clipId == trackB.clipId) return trackB;
    throw ArgumentError.value(clipId, 'clipId', 'Unknown clip.');
  }

  static int _nearestFrameIndex(List<ComparisonFrame> frames, double targetMs) {
    if (targetMs <= frames.first.timeMs) return 0;
    if (targetMs >= frames.last.timeMs) return frames.length - 1;
    var low = 0;
    var high = frames.length - 1;
    while (low + 1 < high) {
      final middle = (low + high) >> 1;
      if (frames[middle].timeMs <= targetMs) {
        low = middle;
      } else {
        high = middle;
      }
    }
    return (frames[high].timeMs - targetMs).abs() <=
            (targetMs - frames[low].timeMs).abs()
        ? high
        : low;
  }
}
