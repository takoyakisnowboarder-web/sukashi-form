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

final comparisonExtractionStarterProvider =
    Provider<FrameExtractionSession Function(Clip)>((ref) {
      final service = ref.watch(frameCacheServiceProvider);
      return service.startExtraction;
    });

enum _ReferenceStep { none, clipA, clipB }

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
        referenceTimesMs: saved?.referenceTimesMs,
        transforms: saved?.transforms,
      );
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
              precacheImage(FileImage(file), context).catchError((_) {}),
            );
          }
        }
      }
    }
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
    final indexA = controller.trackA.frames.indexOf(frameA);
    final indexB = controller.trackB.frames.indexOf(frameB);
    return ListView(
      key: const Key('comparison-scroll'),
      // 下端はシステムのナビゲーションバー/ジェスチャー領域を避ける。
      // これがないと最下部の「基準を合わせる」ボタンがナビバーと重なり、
      // タップがナビバーに吸われて誤ってホームに戻る。
      padding: EdgeInsets.fromLTRB(
        12,
        12,
        12,
        12 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      children: <Widget>[
        _framePanel('A', frameA, indexA, controller.trackA.frames.length),
        const SizedBox(height: 8),
        _framePanel('B', frameB, indexB, controller.trackB.frames.length),
        const SizedBox(height: 8),
        if (_referenceStep == _ReferenceStep.none)
          ..._normalControls(controller)
        else
          ..._referenceControls(controller),
      ],
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

  Widget _framePanel(
    String label,
    ComparisonFrame frame,
    int index,
    int total,
  ) {
    return Column(
      children: <Widget>[
        AspectRatio(
          aspectRatio: 16 / 9,
          child: ColoredBox(
            color: Colors.black,
            child: Image.file(
              File(frame.path),
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const Center(
                child: Icon(Icons.broken_image, color: Colors.white),
              ),
            ),
          ),
        ),
        Text('$label: ${index + 1}/$total', key: Key('frame-number-$label')),
      ],
    );
  }

  List<Widget> _normalControls(ComparisonController controller) => <Widget>[
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
    const SizedBox(height: 8),
    Text(
      controller.hasSynchronizedReference ? '同期済み' : '先頭を基準に同期',
      textAlign: TextAlign.center,
    ),
    OutlinedButton(
      key: const Key('start-reference'),
      onPressed: () => setState(() {
        controller.setPlaying(false);
        _draftReferenceA = controller.frameFor(controller.trackA.clipId).timeMs;
        _draftReferenceB = controller.frameFor(controller.trackB.clipId).timeMs;
        _referenceStep = _ReferenceStep.clipA;
      }),
      child: Text(controller.hasSynchronizedReference ? '基準を取り直す' : '基準を合わせる'),
    ),
  ];

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
          await ref
              .read(comparisonPairRepositoryProvider)
              .savePair(
                ComparisonPairSettings(
                  firstClipId: controller.trackA.clipId,
                  secondClipId: controller.trackB.clipId,
                  referenceTimesMs: controller.synchronizedReferences,
                  transforms: controller.transforms,
                ),
              );
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
