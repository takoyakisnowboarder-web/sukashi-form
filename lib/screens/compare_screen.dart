import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../comparison/comparison_controller.dart';
import '../data/frame_cache_service.dart';
import '../models/clip.dart';
import '../models/comparison_pair.dart';
import '../providers/clip_providers.dart';
import '../providers/frame_extraction_providers.dart';
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
  bool _alignmentMode = false;
  String? _alignmentTargetClipId;
  AlignmentTransform? _gestureStartTransform;
  Offset? _gestureStartFocalPoint;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
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
        _results.add(await session.result);
        unawaited(_progressSubscription?.cancel());
        _progressSubscription = null;
        _activeSession = null;
      }

      final tracks = <ComparisonTrack>[
        for (var index = 0; index < 2; index++)
          ComparisonTrack.evenlySpaced(
            clipId: selected[index].id,
            rangeStartMs: (selected[index].trimStartMs ?? 0).toDouble(),
            rangeEndMs:
                (selected[index].trimEndMs ??
                        selected[index].durationMs.clamp(0, 10000))
                    .toDouble(),
            paths: _results[index].absoluteFramePaths,
          ),
      ];
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
      appBar: AppBar(title: const Text('比較')),
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
      top: false,
      bottom: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          12,
          8,
          12,
          8 + MediaQuery.viewPaddingOf(context).bottom,
        ),
        child: Column(
          children: <Widget>[
            SegmentedButton<ComparisonDisplayMode>(
              key: const Key('display-mode-selector'),
              segments: const <ButtonSegment<ComparisonDisplayMode>>[
                ButtonSegment(
                  value: ComparisonDisplayMode.overlay,
                  label: Text('透過'),
                  icon: Icon(Icons.layers),
                ),
                ButtonSegment(
                  value: ComparisonDisplayMode.split,
                  label: Text('分割'),
                  icon: Icon(Icons.splitscreen),
                ),
              ],
              selected: <ComparisonDisplayMode>{_displayMode},
              onSelectionChanged: (selection) => setState(() {
                _displayMode = selection.single;
              }),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: GestureDetector(
                key: const Key('alignment-gesture-area'),
                behavior: HitTestBehavior.opaque,
                onScaleStart: _alignmentMode
                    ? (details) => _onAlignmentStart(controller, details)
                    : null,
                onScaleUpdate: _alignmentMode
                    ? (details) => _onAlignmentUpdate(controller, details)
                    : null,
                onScaleEnd: _alignmentMode
                    ? (_) => unawaited(_savePair(controller))
                    : null,
                child: _videoArea(controller, frameA, frameB),
              ),
            ),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight:
                    _alignmentMode || _referenceStep != _ReferenceStep.none
                    ? 190
                    : 310,
              ),
              child: SingleChildScrollView(
                key: const Key('comparison-scroll'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _alignmentMode
                      ? _alignmentControls(controller)
                      : _referenceStep == _ReferenceStep.none
                      ? _normalControls(controller)
                      : _referenceControls(controller),
                ),
              ),
            ),
          ],
        ),
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
      return ColoredBox(
        key: const Key('overlay-view'),
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            a,
            Opacity(
              key: const Key('overlay-b-opacity'),
              opacity: _overlayOpacity,
              child: b,
            ),
          ],
        ),
      );
    }
    final panels = <Widget>[
      Expanded(
        child: ColoredBox(color: Colors.black, child: a),
      ),
      const SizedBox(width: 2, height: 2),
      Expanded(
        child: ColoredBox(color: Colors.black, child: b),
      ),
    ];
    return KeyedSubtree(
      key: Key('split-view-${_splitAxis.name}'),
      child: _splitAxis == ComparisonSplitAxis.vertical
          ? Column(children: panels)
          : Row(children: panels),
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
  ) {
    final target = _alignmentTargetClipId ?? controller.trackB.clipId;
    _gestureStartTransform = controller.transformFor(target);
    _gestureStartFocalPoint = details.localFocalPoint;
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

  List<Widget> _alignmentControls(ComparisonController controller) => <Widget>[
    Row(
      children: <Widget>[
        const Expanded(child: Text('位置合わせ対象')),
        SegmentedButton<String>(
          key: const Key('alignment-target-selector'),
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
            _alignmentTargetClipId ?? controller.trackB.clipId,
          },
          onSelectionChanged: (selection) => setState(() {
            _alignmentTargetClipId = selection.single;
          }),
        ),
      ],
    ),
    const SizedBox(height: 6),
    Row(
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
    ),
    const Text('ドラッグ: 移動  ピンチ: 拡大縮小  2本指: 回転', textAlign: TextAlign.center),
  ];

  List<Widget> _normalControls(ComparisonController controller) => <Widget>[
    Row(
      children: <Widget>[
        FilterChip(
          key: const Key('alignment-mode-toggle'),
          avatar: const Icon(Icons.open_with),
          label: const Text('位置合わせ'),
          selected: false,
          onSelected: (_) => setState(() {
            controller.setPlaying(false);
            _alignmentTargetClipId ??= controller.trackB.clipId;
            _alignmentMode = true;
          }),
        ),
        const Spacer(),
        Text(controller.hasSynchronizedReference ? '同期済み' : '先頭を基準に同期'),
        TextButton(
          key: const Key('start-reference'),
          onPressed: () => setState(() {
            controller.setPlaying(false);
            _draftReferenceA = controller
                .frameFor(controller.trackA.clipId)
                .timeMs;
            _draftReferenceB = controller
                .frameFor(controller.trackB.clipId)
                .timeMs;
            _referenceStep = _ReferenceStep.clipA;
          }),
          child: Text(controller.hasSynchronizedReference ? '取り直す' : '基準を合わせる'),
        ),
      ],
    ),
    Slider(
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
    Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        IconButton(
          key: const Key('step-backward'),
          onPressed: () => setState(controller.stepBackward),
          icon: const Icon(Icons.skip_previous),
          tooltip: '1コマ戻る',
        ),
        IconButton(
          key: const Key('play-pause'),
          onPressed: () => setState(controller.togglePlaying),
          icon: Icon(controller.isPlaying ? Icons.pause : Icons.play_arrow),
        ),
        IconButton(
          key: const Key('step-forward'),
          onPressed: () => setState(controller.stepForward),
          icon: const Icon(Icons.skip_next),
          tooltip: '1コマ進む',
        ),
        const SizedBox(width: 12),
        FilterChip(
          label: const Text('ループ'),
          selected: controller.loop,
          onSelected: (value) => setState(() => controller.setLoop(value)),
        ),
      ],
    ),
    Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      children: <Widget>[
        for (final speed in <double>[0.25, 0.5, 1])
          ChoiceChip(
            label: Text('${speed}x'),
            selected: controller.speed == speed,
            onSelected: (_) => setState(() => controller.setSpeed(speed)),
          ),
      ],
    ),
    if (_displayMode == ComparisonDisplayMode.overlay)
      Row(
        children: <Widget>[
          const Text('B 透過'),
          Expanded(
            child: Slider(
              key: const Key('overlay-opacity-slider'),
              value: _overlayOpacity,
              divisions: 20,
              label: '${(_overlayOpacity * 100).round()}%',
              onChanged: (value) => setState(() => _overlayOpacity = value),
              onChangeEnd: (_) => unawaited(_savePair(controller)),
            ),
          ),
          SizedBox(
            width: 44,
            child: Text('${(_overlayOpacity * 100).round()}%'),
          ),
        ],
      ),
    if (_displayMode == ComparisonDisplayMode.split)
      SegmentedButton<ComparisonSplitAxis>(
        key: const Key('split-axis-selector'),
        segments: const <ButtonSegment<ComparisonSplitAxis>>[
          ButtonSegment(value: ComparisonSplitAxis.vertical, label: Text('上下')),
          ButtonSegment(
            value: ComparisonSplitAxis.horizontal,
            label: Text('左右'),
          ),
        ],
        selected: <ComparisonSplitAxis>{_splitAxis},
        onSelectionChanged: (selection) {
          setState(() => _splitAxis = selection.single);
          unawaited(_savePair(controller));
        },
      ),
  ];

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
