import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../capture/grid_overlay.dart';
import '../comparison/comparison_controller.dart';
import '../data/frame_cache_service.dart';
import '../models/app_settings.dart';
import '../models/clip.dart';
import '../models/comparison_pair.dart';
import '../pose/pose_analysis_service.dart';
import '../pose/pose_export.dart';
import '../pose/pose_export_sharer.dart';
import '../pose/pose_movement_dialog.dart';
import '../pose/pose_model.dart';
import '../pose/pose_skeleton_painter.dart';
import '../providers/clip_providers.dart';
import '../providers/frame_extraction_providers.dart';
import '../providers/pose_providers.dart';
import '../widgets/comparison_frame_view.dart';

final comparisonExtractionStarterProvider =
    Provider<FrameExtractionSession Function(Clip)>((ref) {
      final service = ref.watch(frameCacheServiceProvider);
      return service.startExtraction;
    });

enum _ReferenceStep { none, clipA, clipB }

enum ComparisonDisplayMode { overlay, split }

class CompareScreen extends ConsumerStatefulWidget {
  const CompareScreen({required this.clipIds, super.key});
  final List<String> clipIds;

  @override
  ConsumerState<CompareScreen> createState() => _CompareScreenState();
}

class _CompareScreenState extends ConsumerState<CompareScreen>
    with SingleTickerProviderStateMixin {
  final List<FrameCacheResult> _results = <FrameCacheResult>[];
  FrameExtractionSession? _activeSession;
  StreamSubscription<FrameExtractionProgress>? _progressSubscription;
  FrameExtractionProgress? _progress;
  ComparisonController? _controller;
  String? _error;
  bool _preparing = false;
  bool _prepareScheduled = false;
  int _preparingClipIndex = 0;
  late final Ticker _ticker;
  Duration? _lastTick;
  int _lastPrecachingA = -1;
  int _lastPrecachingB = -1;
  _ReferenceStep _referenceStep = _ReferenceStep.none;
  double? _draftReferenceA;
  double? _draftReferenceB;
  ComparisonDisplayMode _displayMode = ComparisonDisplayMode.overlay;
  ComparisonSplitAxis _splitAxis = ComparisonSplitAxis.vertical;
  double _overlayOpacity = 0.5;
  CameraGridType _gridType = CameraGridType.none;
  bool _alignmentMode = false;
  String? _alignmentTargetClipId;
  AlignmentTransform? _gestureStartTransform;
  Offset? _gestureStartFocalPoint;
  bool _poseEnabled = false;
  bool _poseAnalyzing = false;
  int _poseSession = 0;
  String _poseProgressLabel = '';
  final Map<String, PoseFrame> _poses = <String, PoseFrame>{};

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _poseSession += 1;
    unawaited(_progressSubscription?.cancel());
    unawaited(_activeSession?.cancel());
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final controller = _controller;
    final previous = _lastTick;
    _lastTick = elapsed;
    if (!mounted ||
        controller == null ||
        !controller.isPlaying ||
        previous == null) {
      return;
    }
    controller.tick(elapsed - previous);
    _precacheUpcoming(controller);
    setState(() {});
  }

  Future<void> _prepare(List<Clip> clips) async {
    if (_preparing || _controller != null || !mounted) return;
    _preparing = true;
    try {
      if (widget.clipIds.length != 2 ||
          widget.clipIds[0] == widget.clipIds[1]) {
        throw const FormatException('比較する2本のクリップを選択してください。');
      }
      final selected = <Clip>[];
      for (final id in widget.clipIds) {
        final matches = clips.where((clip) => clip.id == id);
        if (matches.isEmpty || matches.first.isBroken) {
          throw const FormatException('比較できないクリップが含まれています。');
        }
        selected.add(matches.first);
      }

      for (final clip in selected) {
        if (clip.durationMs > 10000 && !clip.hasComparisonRange) {
          final choose = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('比較範囲が必要です'),
              content: const Text('このクリップは10秒を超えています。比較範囲を選択してください。'),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('戻る'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('範囲を選択'),
                ),
              ],
            ),
          );
          if (!mounted) return;
          if (choose != true) {
            context.pop();
            return;
          }
          await context.push('/comparison-range/${clip.id}');
          if (mounted) {
            _preparing = false;
            _prepareScheduled = false;
            setState(() {});
          }
          return;
        }
      }

      _results.clear();
      for (var index = 0; index < selected.length; index++) {
        _preparingClipIndex = index;
        _progress = null;
        if (mounted) setState(() {});
        final session = ref.read(comparisonExtractionStarterProvider)(
          selected[index],
        );
        _activeSession = session;
        _progressSubscription = session.progress.listen((value) {
          if (mounted) setState(() => _progress = value);
        });
        try {
          _results.add(await session.result);
        } on FrameExtractionException catch (error) {
          throw FrameExtractionException(
            framePreparationLabel(
              clipIndex: index,
              memo: selected[index].memo,
              reason: error.reason,
            ),
          );
        }
        unawaited(_progressSubscription?.cancel());
        _progressSubscription = null;
        _activeSession = null;
      }

      final tracks = List<ComparisonTrack>.generate(2, (index) {
        final range = comparisonPlaybackRange(
          trimStartMs: selected[index].trimStartMs,
          trimEndMs: selected[index].trimEndMs,
          clipDurationMs: selected[index].durationMs,
          extractedDurationMs: _results[index].sourceDurationMs,
        );
        return ComparisonTrack.evenlySpaced(
          clipId: selected[index].id,
          rangeStartMs: range.startMs,
          rangeEndMs: range.endMs,
          paths: _results[index].absoluteFramePaths,
        );
      });
      final ranges = <String, ComparisonClipRange>{
        for (final track in tracks)
          track.clipId: ComparisonClipRange(
            startMs: track.rangeStartMs,
            endMs: track.rangeEndMs,
          ),
      };
      final saved = await ref
          .read(comparisonPairRepositoryProvider)
          .loadPair(selected[0].id, selected[1].id, currentRanges: ranges);
      if (!mounted) return;
      _controller = ComparisonController(
        trackA: tracks[0],
        trackB: tracks[1],
        referenceTimesMs: saved?.hasSynchronizedReference == true
            ? saved!.referenceTimesMs
            : null,
        transforms: saved?.transforms,
      );
      _splitAxis = saved?.splitAxis ?? ComparisonSplitAxis.vertical;
      _overlayOpacity = saved?.overlayOpacity ?? 0.5;
      _gridType = saved?.gridType ?? CameraGridType.none;
      _alignmentTargetClipId = tracks[1].clipId;
      _precacheUpcoming(_controller!);
      setState(() {});
    } on FrameExtractionCancelled {
      // Leaving the screen intentionally cancels preparation.
    } on Object catch (error) {
      if (mounted) setState(() => _error = _messageFor(error));
    } finally {
      _preparing = false;
      if (mounted) setState(() {});
    }
  }

  String _messageFor(Object error) {
    if (error is FormatException) return error.message;
    if (error is FrameExtractionException) {
      return 'フレームを準備できませんでした（${error.reason}）。';
    }
    return '比較画面を準備できませんでした。';
  }

  static const _poseColorA = Color(0xFF38BDF8);
  static const _poseColorB = Color(0xFFFBBF24);

  PoseFrame? _poseFor(String path) {
    if (!_poseEnabled) {
      return null;
    }
    return _poses[path];
  }

  Future<void> _setPoseEnabled(
    bool enabled,
    ComparisonController controller,
  ) async {
    if (!enabled) {
      _poseSession += 1;
      setState(() {
        _poseEnabled = false;
        _poseAnalyzing = false;
        _poseProgressLabel = '';
      });
      return;
    }
    final detector = ref.read(poseDetectorClientProvider);
    if (!detector.isSupported) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('この端末では骨格解析を実行できません。')));
      }
      return;
    }
    setState(() => _poseEnabled = true);
    await _analyzePoses(controller);
  }

  Future<void> _analyzePoses(ComparisonController controller) async {
    final sessionId = ++_poseSession;
    setState(() {
      _poseAnalyzing = true;
      _poseProgressLabel = '骨格解析を準備しています…';
    });
    try {
      var clipIndex = 0;
      for (final track in <ComparisonTrack>[
        controller.trackA,
        controller.trackB,
      ]) {
        if (!mounted || sessionId != _poseSession || !_poseEnabled) {
          return;
        }
        clipIndex += 1;
        await _analyzeTrack(
          track,
          sessionId: sessionId,
          progressLabel: '骨格解析 $clipIndex/2',
        );
      }
    } on Object {
      if (mounted && sessionId == _poseSession) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('骨格解析に失敗しました。')));
      }
    } finally {
      if (mounted && sessionId == _poseSession) {
        final detected = _poses.values
            .where((pose) => pose.landmarks.isNotEmpty)
            .length;
        setState(() {
          _poseAnalyzing = false;
          _poseProgressLabel = detected == 0
              ? '骨格を検出できませんでした'
              : '骨格 $detected コマ検出';
        });
      }
    }
  }

  Future<void> _analyzeTrack(
    ComparisonTrack track, {
    required int sessionId,
    required String progressLabel,
  }) async {
    final service = ref.read(poseAnalysisServiceProvider);
    final session = service.analyzeClip(
      clipId: track.clipId,
      framePaths: track.frames.map((frame) => frame.path).toList(),
    );
    final subscription = session.progress.listen((progress) {
      if (!mounted || sessionId != _poseSession) {
        return;
      }
      setState(() {
        _poseProgressLabel =
            '$progressLabel: ${progress.completed}/${progress.total}';
      });
    });
    final result = await session.result;
    await subscription.cancel();
    if (!mounted || sessionId != _poseSession) {
      return;
    }
    setState(() {
      for (final frame in track.frames) {
        final pose =
            result[frame.path] ??
            result[PoseAnalysisService.keyForPath(frame.path)];
        if (pose != null) {
          _poses[frame.path] = pose;
        }
      }
    });
  }

  Clip? _clipById(String clipId) {
    final clips = ref.read(clipListProvider).value;
    if (clips == null) {
      return null;
    }
    for (final clip in clips) {
      if (clip.id == clipId) {
        return clip;
      }
    }
    return null;
  }

  Future<void> _exportPoseTrack(
    ComparisonTrack track, {
    required Rect? sharePositionOrigin,
  }) async {
    final clip = _clipById(track.clipId);
    if (clip == null) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('クリップ情報を取得できませんでした。')));
      }
      return;
    }
    final movement = await askPoseMovement(context);
    if (!mounted || movement == null) {
      return;
    }
    final sessionId = ++_poseSession;
    setState(() {
      _poseAnalyzing = true;
      _poseProgressLabel = '座標データを準備しています…';
    });
    try {
      await _analyzeTrack(track, sessionId: sessionId, progressLabel: '座標書き出し');
      if (!mounted || sessionId != _poseSession) {
        return;
      }
      await ref
          .read(poseExportSharerProvider)
          .shareJsonFile(
            fileName: poseExportFileName(clip),
            contents: encodePoseMotionDocument(
              buildPoseMotionDocument(
                clip: clip,
                track: track,
                posesByPath: _poses,
                movement: movement,
              ),
            ),
            sharePositionOrigin: sharePositionOrigin,
          );
    } on Object {
      if (mounted && sessionId == _poseSession) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('座標データの書き出しに失敗しました。')));
      }
    } finally {
      if (mounted && sessionId == _poseSession) {
        final detected = _poses.values
            .where((pose) => pose.landmarks.isNotEmpty)
            .length;
        setState(() {
          _poseAnalyzing = false;
          if (_poseEnabled) {
            _poseProgressLabel = detected == 0
                ? '骨格を検出できませんでした'
                : '骨格 $detected コマ検出';
          } else {
            _poseProgressLabel = '';
          }
        });
      }
    }
  }

  void _precacheUpcoming(ComparisonController controller) {
    if (!mounted) return;
    final indexA = controller.frameIndexFor(controller.trackA.clipId);
    final indexB = controller.frameIndexFor(controller.trackB.clipId);
    if (indexA == _lastPrecachingA && indexB == _lastPrecachingB) return;
    _lastPrecachingA = indexA;
    _lastPrecachingB = indexB;
    for (final entry in <(ComparisonTrack, int)>[
      (controller.trackA, indexA),
      (controller.trackB, indexB),
    ]) {
      for (var offset = 1; offset <= 6; offset++) {
        final next = entry.$2 + offset;
        if (next < entry.$1.frames.length) {
          final file = File(entry.$1.frames[next].path);
          if (file.existsSync()) {
            unawaited(
              precacheImage(
                ResizeImage.resizeIfNeeded(_decodeWidth, null, FileImage(file)),
                context,
              ).catchError((_) {}),
            );
          }
        }
      }
    }
  }

  int get _decodeWidth {
    if (!mounted) return 720;
    final media = MediaQuery.of(context);
    return (media.size.width * media.devicePixelRatio).round().clamp(1, 1280);
  }

  @override
  Widget build(BuildContext context) {
    final clipsValue = ref.watch(clipListProvider);
    final clips = clipsValue.value;
    if (clips != null &&
        !_prepareScheduled &&
        _controller == null &&
        !_preparing &&
        _error == null) {
      _prepareScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _prepare(clips));
    }
    return Scaffold(
      appBar: _controller == null ? AppBar(title: const Text('比較')) : null,
      body: _body(clipsValue),
    );
  }

  Widget _body(AsyncValue<List<Clip>> clipsValue) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    final controller = _controller;
    if (controller == null) {
      final progress = _progress;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                progress == null
                    ? '比較を準備しています…'
                    : '${_preparingClipIndex + 1}/2本目: ${progress.completedFrames}/${progress.totalFrames} フレーム',
                key: const Key('comparison-preparation-progress'),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    if (!controller.hasIntersection) {
      return const Center(child: Text('重なる区間がありません。基準を取り直してください。'));
    }
    return _comparisonBody(controller);
  }

  Widget _comparisonBody(ComparisonController controller) {
    final frameA = _displayFrame(
      controller.trackA,
      _draftReferenceA,
      _referenceStep == _ReferenceStep.clipA,
      controller,
    );
    final frameB = _displayFrame(
      controller.trackB,
      _draftReferenceB,
      _referenceStep == _ReferenceStep.clipB,
      controller,
    );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
        child: Column(
          children: <Widget>[
            _comparisonTopBar(controller),
            const SizedBox(height: 6),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    GestureDetector(
                      key: const Key('alignment-gesture-area'),
                      behavior: HitTestBehavior.opaque,
                      onScaleStart: _alignmentMode
                          ? (details) => _onAlignmentStart(
                              controller,
                              details,
                              constraints.biggest,
                            )
                          : null,
                      onScaleUpdate: _alignmentMode
                          ? (details) => _onAlignmentUpdate(controller, details)
                          : null,
                      onScaleEnd: _alignmentMode
                          ? (_) => unawaited(_savePair(controller))
                          : null,
                      child: _videoArea(controller, frameA, frameB),
                    ),
                    if (_alignmentMode)
                      Positioned(
                        top: 8,
                        left: 12,
                        right: 12,
                        child: IgnorePointer(
                          child: Center(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.72),
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 7,
                                ),
                                child: Text(
                                  _alignmentHint(controller),
                                  style: TextStyle(color: Colors.white),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            if (_referenceStep != _ReferenceStep.none)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 190),
                child: SingleChildScrollView(
                  key: const Key('comparison-scroll'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _referenceControls(controller),
                  ),
                ),
              )
            else if (_alignmentMode)
              _alignmentBottomBar(controller)
            else ...<Widget>[
              _seekBar(controller),
              _transportControls(controller),
            ],
          ],
        ),
      ),
    );
  }

  Widget _comparisonTopBar(ComparisonController controller) {
    return Row(
      children: <Widget>[
        IconButton.filledTonal(
          key: const Key('comparison-back'),
          onPressed: () => context.pop(),
          icon: const Icon(Icons.arrow_back),
          tooltip: '戻る',
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Center(
            child: SegmentedButton<ComparisonDisplayMode>(
              key: const Key('display-mode-selector'),
              // softWrap:false で「透過」が縦に割れるのを防ぐ。
              segments: const <ButtonSegment<ComparisonDisplayMode>>[
                ButtonSegment(
                  value: ComparisonDisplayMode.overlay,
                  label: Text('透過', softWrap: false),
                ),
                ButtonSegment(
                  value: ComparisonDisplayMode.split,
                  label: Text('分割', softWrap: false),
                ),
              ],
              selected: <ComparisonDisplayMode>{_displayMode},
              onSelectionChanged: _alignmentMode
                  ? null
                  : (selection) => setState(() {
                      _displayMode = selection.single;
                      _alignmentTargetClipId = controller.trackB.clipId;
                    }),
            ),
          ),
        ),
        const SizedBox(width: 6),
        IconButton.filledTonal(
          key: const Key('comparison-help'),
          onPressed: _showComparisonHelp,
          icon: const Icon(Icons.help_outline),
          tooltip: '説明',
        ),
        const SizedBox(width: 4),
        IconButton.filledTonal(
          key: const Key('comparison-settings'),
          // 位置合わせ中も、操作対象と比較グリッドを切り替えられるようにする。
          onPressed: _referenceStep != _ReferenceStep.none
              ? null
              : () => _showSettingsSheet(controller),
          icon: const Icon(Icons.tune),
          tooltip: '設定',
        ),
      ],
    );
  }

  Widget _seekBar(ComparisonController controller) {
    final elapsed = (controller.positionMs - controller.intersectionStartMs)
        .clamp(0, double.infinity);
    final total = controller.intersectionEndMs - controller.intersectionStartMs;
    return Row(
      children: <Widget>[
        Expanded(
          child: Slider(
            key: const Key('comparison-seek'),
            value: controller.positionMs,
            min: controller.intersectionStartMs,
            max: controller.intersectionEndMs == controller.intersectionStartMs
                ? controller.intersectionStartMs + 1
                : controller.intersectionEndMs,
            onChanged: (value) => setState(() {
              controller.seek(value);
              _precacheUpcoming(controller);
            }),
          ),
        ),
        SizedBox(
          width: 92,
          child: Text(
            '${(elapsed / 1000).toStringAsFixed(1)} / '
            '${(total / 1000).toStringAsFixed(1)}秒',
            key: const Key('comparison-time'),
            textAlign: TextAlign.end,
            style: const TextStyle(
              fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }

  Widget _transportControls(ComparisonController controller) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: <Widget>[
          SizedBox.square(
            dimension: 66,
            child: IconButton.filledTonal(
              key: const Key('step-backward'),
              onPressed: () => setState(controller.stepBackward),
              icon: const Icon(Icons.skip_previous, size: 30),
              tooltip: '1コマ戻る',
            ),
          ),
          SizedBox.square(
            dimension: 80,
            child: IconButton.filled(
              key: const Key('play-pause'),
              onPressed: () => setState(controller.togglePlaying),
              icon: Icon(
                controller.isPlaying ? Icons.pause : Icons.play_arrow,
                size: 38,
              ),
            ),
          ),
          SizedBox.square(
            dimension: 66,
            child: IconButton.filledTonal(
              key: const Key('step-forward'),
              onPressed: () => setState(controller.stepForward),
              icon: const Icon(Icons.skip_next, size: 30),
              tooltip: '1コマ進む',
            ),
          ),
        ],
      ),
    );
  }

  ComparisonFrame _displayFrame(
    ComparisonTrack track,
    double? draft,
    bool editing,
    ComparisonController controller,
  ) {
    if (!editing || draft == null) return controller.frameFor(track.clipId);
    return track.frames[_nearestIndex(track.frames, draft)];
  }

  Widget _videoArea(
    ComparisonController controller,
    ComparisonFrame frameA,
    ComparisonFrame frameB,
  ) {
    final a = _frameLayer('A', controller.trackA.clipId, frameA, controller);
    final b = _frameLayer('B', controller.trackB.clipId, frameB, controller);
    if (_displayMode == ComparisonDisplayMode.overlay) {
      return DecoratedBox(
        key: const Key('overlay-view'),
        decoration: BoxDecoration(
          color: Colors.black,
          border: _alignmentMode
              ? Border.all(
                  color: Theme.of(context).colorScheme.primary,
                  width: 3,
                )
              : null,
        ),
        child: ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              a,
              Opacity(
                key: const Key('overlay-b-opacity'),
                opacity: _overlayOpacity,
                child: b,
              ),
              if (_alignmentMode && _gridType != CameraGridType.none)
                GridOverlay(gridType: _gridType),
              if (_alignmentMode)
                _alignmentTargetBadge(
                  (_alignmentTargetClipId ?? controller.trackB.clipId) ==
                          controller.trackA.clipId
                      ? 'A'
                      : 'B',
                ),
              if (_poseEnabled) _poseHud(frameA, frameB),
            ],
          ),
        ),
      );
    }
    final panels = <Widget>[
      Expanded(
        child: _alignmentPanel(
          key: const Key('alignment-panel-A'),
          clipId: controller.trackA.clipId,
          child: a,
        ),
      ),
      const SizedBox(width: 2, height: 2),
      Expanded(
        child: _alignmentPanel(
          key: const Key('alignment-panel-B'),
          clipId: controller.trackB.clipId,
          child: b,
        ),
      ),
    ];
    return KeyedSubtree(
      key: Key('split-view-${_splitAxis.name}'),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          _splitAxis == ComparisonSplitAxis.vertical
              ? Column(children: panels)
              : Row(children: panels),
          if (_poseEnabled) _poseHud(frameA, frameB),
        ],
      ),
    );
  }

  Widget _poseHud(ComparisonFrame frameA, ComparisonFrame frameB) {
    return Positioned(
      left: 8,
      right: 8,
      bottom: 8,
      child: IgnorePointer(
        child: Column(
          key: const Key('pose-angle-hud'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (_poseProgressLabel.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  _poseProgressLabel,
                  key: const Key('pose-analysis-progress'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            PoseAngleHud(
              label: 'A',
              pose: _poseFor(frameA.path),
              color: _poseColorA,
            ),
            const SizedBox(height: 4),
            PoseAngleHud(
              label: 'B',
              pose: _poseFor(frameB.path),
              color: _poseColorB,
            ),
          ],
        ),
      ),
    );
  }

  Widget _alignmentPanel({
    required Key key,
    required String clipId,
    required Widget child,
  }) {
    final active = _alignmentMode && _alignmentTargetClipId == clipId;
    return DecoratedBox(
      key: key,
      decoration: BoxDecoration(
        color: Colors.black,
        border: active
            ? Border.all(color: Theme.of(context).colorScheme.primary, width: 3)
            : null,
      ),
      child: ClipRect(
        child: !_alignmentMode || _gridType == CameraGridType.none
            ? child
            : Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  child,
                  GridOverlay(gridType: _gridType),
                ],
              ),
      ),
    );
  }

  Widget _frameLayer(
    String label,
    String clipId,
    ComparisonFrame frame,
    ComparisonController controller,
  ) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ComparisonFrameView(
          clipId: clipId,
          path: frame.path,
          transform: controller.transformFor(clipId),
          cacheWidth: _decodeWidth,
          pose: _poseFor(frame.path),
          skeletonColor: label == 'A' ? _poseColorA : _poseColorB,
        ),
        Positioned(
          left: 8,
          top: 8,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              child: Text(label, style: const TextStyle(color: Colors.white)),
            ),
          ),
        ),
      ],
    );
  }

  void _onAlignmentStart(
    ComparisonController controller,
    ScaleStartDetails details,
    Size areaSize,
  ) {
    final target = switch (_displayMode) {
      ComparisonDisplayMode.overlay =>
        _alignmentTargetClipId ?? controller.trackB.clipId,
      ComparisonDisplayMode.split =>
        _splitAxis == ComparisonSplitAxis.vertical
            ? (details.localFocalPoint.dy < areaSize.height / 2
                  ? controller.trackA.clipId
                  : controller.trackB.clipId)
            : (details.localFocalPoint.dx < areaSize.width / 2
                  ? controller.trackA.clipId
                  : controller.trackB.clipId),
    };
    _alignmentTargetClipId = target;
    _gestureStartTransform = controller.transformFor(target);
    _gestureStartFocalPoint = details.localFocalPoint;
    setState(() {});
  }

  void _onAlignmentUpdate(
    ComparisonController controller,
    ScaleUpdateDetails details,
  ) {
    final target = _alignmentTargetClipId ?? controller.trackB.clipId;
    final original = _gestureStartTransform;
    final focal = _gestureStartFocalPoint;
    if (original == null || focal == null) return;
    final delta = details.localFocalPoint - focal;
    controller.setTransform(
      target,
      AlignmentTransform(
        dx: original.dx + delta.dx,
        dy: original.dy + delta.dy,
        scale: (original.scale * details.scale).clamp(0.25, 4),
        rotation: original.rotation + details.rotation,
      ),
    );
    setState(() {});
  }

  String _alignmentHint(ComparisonController controller) {
    if (_displayMode == ComparisonDisplayMode.split) {
      return '触った映像を操作（ドラッグ／ピンチ／2本指回転）';
    }
    final target = _alignmentTargetClipId ?? controller.trackB.clipId;
    final label = target == controller.trackA.clipId ? 'A' : 'B';
    return '$labelを操作中（設定からA/Bを変更できます）';
  }

  Widget _alignmentTargetBadge(String label) {
    return Positioned(
      right: 10,
      bottom: 10,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          child: Text(label, style: const TextStyle(color: Colors.white)),
        ),
      ),
    );
  }

  Widget _alignmentBottomBar(ComparisonController controller) {
    return Row(
      children: <Widget>[
        Expanded(
          child: OutlinedButton.icon(
            key: const Key('reset-alignment'),
            onPressed: () async {
              final target = _alignmentTargetClipId ?? controller.trackB.clipId;
              controller.setTransform(target, const AlignmentTransform());
              setState(() {});
              await _savePair(controller);
            },
            icon: const Icon(Icons.restart_alt),
            label: const Text('リセット'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton.icon(
            key: const Key('finish-alignment'),
            onPressed: () => setState(() => _alignmentMode = false),
            icon: const Icon(Icons.check),
            label: const Text('完了'),
          ),
        ),
      ],
    );
  }

  Future<void> _showComparisonHelp() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('比較画面の使い方'),
      content: const Text(
        '透過は2本を重ね、分割は上下または左右に並べます。\n\n'
        '基準同期では、AとBそれぞれの同じ瞬間を選んで再生位置を揃えます。\n\n'
        '位置合わせでは、ドラッグで移動、ピンチで拡大縮小、2本指で回転できます。\n'
        '透過の操作対象と比較グリッドは、設定から選べます。\n\n'
        '骨格表示をオンにすると、端末内だけで頭・肩・腰・膝・足元の点を推定し、'
        '関節角度を表示します。映像は外部へ送信されません。\n\n'
        '座標の保存は1本ずつです。保存の前に「この動作は何ですか？」と聞きます。'
        '種目と技を書くと、AIが座標の意味を読みやすくなります。',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('閉じる'),
        ),
      ],
    ),
  );

  void _beginReference(ComparisonController controller) {
    setState(() {
      controller.setPlaying(false);
      _draftReferenceA = controller.frameFor(controller.trackA.clipId).timeMs;
      _draftReferenceB = controller.frameFor(controller.trackB.clipId).timeMs;
      _referenceStep = _ReferenceStep.clipA;
    });
  }

  Future<void> _showSettingsSheet(ComparisonController controller) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      enableDrag: true,
      builder: (sheetContext) {
        // 透過は項目が多く、高さ制限がないとシートが全画面になって
        // 比較画面の戻るボタンが隠れる。分割と同じく下からのシャッターにする。
        final maxHeight = MediaQuery.sizeOf(sheetContext).height * 0.72;
        return StatefulBuilder(
          builder: (context, setSheetState) {
            void refresh(VoidCallback change) {
              setState(change);
              setSheetState(() {});
            }

            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxHeight),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  child: Column(
                    key: const Key('comparison-settings-sheet'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Text(
                        '比較設定',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      _settingsRow(
                        label: '再生',
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: FilterChip(
                            key: const Key('loop-toggle'),
                            label: const Text('ループ'),
                            selected: controller.loop,
                            onSelected: (value) =>
                                refresh(() => controller.setLoop(value)),
                          ),
                        ),
                      ),
                      _settingsRow(
                        label: '速度',
                        child: SegmentedButton<double>(
                          key: const Key('speed-selector'),
                          // 選択中はチェックアイコンが入る分だけ幅が減るため、
                          // ラベルを短く保たないと末尾が切れる(「1.0x」→「1.0」)。
                          // softWrap:false は折り返しも防ぐ。
                          showSelectedIcon: false,
                          segments: const <ButtonSegment<double>>[
                            ButtonSegment(
                              value: 0.25,
                              label: Text('0.25x', softWrap: false),
                            ),
                            ButtonSegment(
                              value: 0.5,
                              label: Text('0.5x', softWrap: false),
                            ),
                            ButtonSegment(
                              value: 1,
                              label: Text('1.0x', softWrap: false),
                            ),
                          ],
                          selected: <double>{controller.speed},
                          onSelectionChanged: (selection) => refresh(
                            () => controller.setSpeed(selection.single),
                          ),
                        ),
                      ),
                      if (_displayMode == ComparisonDisplayMode.overlay)
                        _settingsRow(
                          label: 'B 透過',
                          child: Row(
                            children: <Widget>[
                              Expanded(
                                child: Slider(
                                  key: const Key('overlay-opacity-slider'),
                                  value: _overlayOpacity,
                                  divisions: 20,
                                  onChanged: (value) =>
                                      refresh(() => _overlayOpacity = value),
                                  onChangeEnd: (_) =>
                                      unawaited(_savePair(controller)),
                                ),
                              ),
                              SizedBox(
                                width: 44,
                                child: Text(
                                  '${(_overlayOpacity * 100).round()}%',
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (_displayMode == ComparisonDisplayMode.split)
                        _settingsRow(
                          label: '分割方向',
                          child: SegmentedButton<ComparisonSplitAxis>(
                            key: const Key('split-axis-selector'),
                            segments:
                                const <ButtonSegment<ComparisonSplitAxis>>[
                                  ButtonSegment(
                                    value: ComparisonSplitAxis.vertical,
                                    label: Text('上下'),
                                  ),
                                  ButtonSegment(
                                    value: ComparisonSplitAxis.horizontal,
                                    label: Text('左右'),
                                  ),
                                ],
                            selected: <ComparisonSplitAxis>{_splitAxis},
                            onSelectionChanged: (selection) {
                              refresh(() => _splitAxis = selection.single);
                              unawaited(_savePair(controller));
                            },
                          ),
                        ),
                      _settingsRow(
                        label: '比較グリッド',
                        child: Switch(
                          key: const Key('comparison-grid-toggle'),
                          value: _gridType != CameraGridType.none,
                          onChanged: (enabled) {
                            refresh(
                              () => _gridType = enabled
                                  ? CameraGridType.grid3x3
                                  : CameraGridType.none,
                            );
                            unawaited(_savePair(controller));
                          },
                        ),
                      ),
                      if (_gridType != CameraGridType.none)
                        _settingsRow(
                          label: 'グリッド種類',
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: CameraGridType.values
                                .where((type) => type != CameraGridType.none)
                                .map(
                                  (type) => ChoiceChip(
                                    key: Key(
                                      'comparison-grid-type-${type.name}',
                                    ),
                                    label: Text(type.label),
                                    selected: _gridType == type,
                                    onSelected: (_) {
                                      refresh(() => _gridType = type);
                                      unawaited(_savePair(controller));
                                    },
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                      if (_displayMode == ComparisonDisplayMode.overlay)
                        _settingsRow(
                          label: '操作対象',
                          child: SegmentedButton<String>(
                            key: const Key('alignment-target-settings'),
                            showSelectedIcon: false,
                            segments: <ButtonSegment<String>>[
                              ButtonSegment(
                                value: controller.trackA.clipId,
                                label: const Text('A'),
                              ),
                              ButtonSegment(
                                value: controller.trackB.clipId,
                                label: const Text('B'),
                              ),
                            ],
                            selected: <String>{
                              _alignmentTargetClipId ??
                                  controller.trackB.clipId,
                            },
                            onSelectionChanged: (selection) => refresh(
                              () => _alignmentTargetClipId = selection.single,
                            ),
                          ),
                        ),
                      _settingsRow(
                        label: '骨格表示',
                        child: Switch(
                          key: const Key('pose-overlay-toggle'),
                          value: _poseEnabled,
                          onChanged: (enabled) =>
                              unawaited(_setPoseEnabled(enabled, controller)),
                        ),
                      ),
                      _settingsRow(
                        label: '座標保存',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            const Text(
                              '1本ずつJSONを保存します。保存前に動作の説明を書けます。',
                              style: TextStyle(fontSize: 12),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: <Widget>[
                                FilledButton.tonal(
                                  key: const Key('pose-export-a'),
                                  onPressed: _poseAnalyzing
                                      ? null
                                      : () {
                                          final box =
                                              sheetContext.findRenderObject()
                                                  as RenderBox?;
                                          unawaited(
                                            _exportPoseTrack(
                                              controller.trackA,
                                              sharePositionOrigin: box == null
                                                  ? null
                                                  : box.localToGlobal(
                                                          Offset.zero,
                                                        ) &
                                                        box.size,
                                            ),
                                          );
                                        },
                                  child: const Text('Aを保存'),
                                ),
                                FilledButton.tonal(
                                  key: const Key('pose-export-b'),
                                  onPressed: _poseAnalyzing
                                      ? null
                                      : () {
                                          final box =
                                              sheetContext.findRenderObject()
                                                  as RenderBox?;
                                          unawaited(
                                            _exportPoseTrack(
                                              controller.trackB,
                                              sharePositionOrigin: box == null
                                                  ? null
                                                  : box.localToGlobal(
                                                          Offset.zero,
                                                        ) &
                                                        box.size,
                                            ),
                                          );
                                        },
                                  child: const Text('Bを保存'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      _settingsRow(
                        label: '位置合わせ',
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: FilledButton.tonalIcon(
                            key: const Key('alignment-mode-toggle'),
                            onPressed: _alignmentMode
                                ? null
                                : () {
                                    Navigator.pop(sheetContext);
                                    setState(() {
                                      controller.setPlaying(false);
                                      _alignmentTargetClipId ??=
                                          controller.trackB.clipId;
                                      _alignmentMode = true;
                                    });
                                  },
                            icon: const Icon(Icons.open_with),
                            label: Text(_alignmentMode ? '位置合わせ中' : '位置合わせを開始'),
                          ),
                        ),
                      ),
                      _settingsRow(
                        label: '同期',
                        child: Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 8,
                          children: <Widget>[
                            Text(
                              controller.hasSynchronizedReference
                                  ? '✓ 同期済み'
                                  : '先頭を基準に同期',
                            ),
                            TextButton(
                              key: const Key('start-reference'),
                              onPressed: () {
                                Navigator.pop(sheetContext);
                                _beginReference(controller);
                              },
                              child: Text(
                                controller.hasSynchronizedReference
                                    ? '基準を取り直す'
                                    : '基準を合わせる',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _settingsRow({required String label, required Widget child}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          // 「位置合わせ」(5文字)が折り返さない幅を確保する。
          SizedBox(width: 96, child: Text(label, softWrap: false)),
          const SizedBox(width: 8),
          Expanded(child: child),
        ],
      ),
    );
  }

  Future<void> _savePair(ComparisonController controller) async {
    await ref
        .read(comparisonPairRepositoryProvider)
        .savePair(
          ComparisonPairSettings(
            firstClipId: controller.trackA.clipId,
            secondClipId: controller.trackB.clipId,
            referenceTimesMs: controller.synchronizedReferences,
            transforms: controller.transforms,
            hasSynchronizedReference: controller.hasSynchronizedReference,
            splitAxis: _splitAxis,
            overlayOpacity: _overlayOpacity,
            gridType: _gridType,
          ),
        );
  }

  List<Widget> _referenceControls(ComparisonController controller) {
    final isA = _referenceStep == _ReferenceStep.clipA;
    final track = isA ? controller.trackA : controller.trackB;
    final value = (isA ? _draftReferenceA : _draftReferenceB)!;
    return <Widget>[
      Text(
        isA ? 'ステップ1: Aの基準を選択' : 'ステップ2: Bの基準を選択',
        textAlign: TextAlign.center,
      ),
      Slider(
        key: Key(isA ? 'reference-slider-A' : 'reference-slider-B'),
        value: value,
        min: track.rangeStartMs,
        max: track.rangeEndMs,
        onChanged: (next) => setState(() {
          if (isA) {
            _draftReferenceA = next;
          } else {
            _draftReferenceB = next;
          }
        }),
      ),
      FilledButton(
        key: const Key('confirm-reference'),
        onPressed: () async {
          if (isA) {
            setState(() => _referenceStep = _ReferenceStep.clipB);
            return;
          }
          controller.setReference(controller.trackA.clipId, _draftReferenceA!);
          controller.setReference(controller.trackB.clipId, _draftReferenceB!);
          await _savePair(controller);
          if (mounted) setState(() => _referenceStep = _ReferenceStep.none);
        },
        child: const Text('ここを基準にする'),
      ),
      TextButton(
        key: const Key('cancel-reference'),
        onPressed: () => setState(() {
          controller.cancelPendingReferences();
          _referenceStep = _ReferenceStep.none;
          _draftReferenceA = null;
          _draftReferenceB = null;
        }),
        child: const Text('キャンセル'),
      ),
    ];
  }
}

int _nearestIndex(List<ComparisonFrame> frames, double target) {
  var best = 0;
  var distance = double.infinity;
  for (var index = 0; index < frames.length; index++) {
    final next = (frames[index].timeMs - target).abs();
    if (next <= distance) {
      best = index;
      distance = next;
    } else {
      break;
    }
  }
  return best;
}
