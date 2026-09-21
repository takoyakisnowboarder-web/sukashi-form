import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/frame_cache_service.dart';
import '../models/clip.dart';
import '../pose/pose_motion_range.dart';
import '../providers/clip_providers.dart';
import '../providers/frame_extraction_providers.dart';
import '../providers/pose_providers.dart';

class ComparisonRangeScreen extends ConsumerStatefulWidget {
  const ComparisonRangeScreen({
    required this.clipId,
    this.skipPreviewForTesting = false,
    super.key,
  });

  final String clipId;
  final bool skipPreviewForTesting;

  @override
  ConsumerState<ComparisonRangeScreen> createState() =>
      _ComparisonRangeScreenState();
}

class _ComparisonRangeScreenState extends ConsumerState<ComparisonRangeScreen> {
  FrameExtractionSession? _previewSession;
  StreamSubscription<FrameExtractionProgress>? _progressSubscription;
  FrameExtractionProgress? _progress;
  FrameCacheResult? _preview;
  String? _error;
  RangeValues? _values;
  double? _activeHandleMs;
  bool _saving = false;
  bool _loadScheduled = false;
  bool _detecting = false;
  bool _userEditedRange = false;
  bool _autoCutAttempted = false;
  int _detectGeneration = 0;

  Clip? get _clip {
    final clips = ref.read(clipListProvider).value ?? <Clip>[];
    for (final clip in clips) {
      if (clip.id == widget.clipId) {
        return clip;
      }
    }
    return null;
  }

  @override
  void dispose() {
    _detectGeneration += 1;
    unawaited(_progressSubscription?.cancel());
    unawaited(_previewSession?.cancel());
    super.dispose();
  }

  Future<void> _loadPreview() async {
    if (!mounted) {
      return;
    }
    final clip = _clip;
    if (clip == null || clip.durationMs <= 0 || clip.isBroken) {
      setState(() => _error = 'この動画では比較範囲を選択できません。');
      return;
    }
    _values = RangeValues(
      (clip.trimStartMs ?? 0).toDouble(),
      (clip.trimEndMs ?? math.min(clip.durationMs, 10000)).toDouble(),
    );
    if (widget.skipPreviewForTesting) {
      setState(() {});
      return;
    }
    final session = ref
        .read(framePreviewServiceProvider)
        .startExtractionForRange(
          clip,
          rangeStartMs: 0,
          rangeEndMs: clip.durationMs,
        );
    setState(() {
      _previewSession = session;
      _progress = null;
      _preview = null;
      _error = null;
    });
    _progressSubscription = session.progress.listen((progress) {
      if (mounted) {
        setState(() => _progress = progress);
      }
    });
    try {
      final preview = await session.result;
      if (mounted) {
        setState(() => _preview = preview);
        if (clip.hasComparisonRange) {
          _autoCutAttempted = true;
        } else {
          unawaited(_cutMotionRange(fromUser: false));
        }
      }
    } on FrameExtractionCancelled {
      // Closing the screen intentionally cancels preview generation.
    } on Object {
      if (mounted) {
        setState(() => _error = 'プレビューを作成できませんでした。');
      }
    }
  }

  bool get _isValidRange {
    final values = _values;
    if (values == null) {
      return false;
    }
    final duration = values.end - values.start;
    return duration > 0 && duration <= 10000;
  }

  Future<void> _save() async {
    final values = _values;
    if (values == null || !_isValidRange || _saving) {
      return;
    }
    setState(() => _saving = true);
    await ref
        .read(clipListProvider.notifier)
        .updateComparisonRange(
          widget.clipId,
          startMs: values.start.round(),
          endMs: values.end.round(),
        );
    if (mounted) {
      Navigator.pop(context);
    }
  }

  Future<void> _reset() async {
    if (_saving) {
      return;
    }
    setState(() => _saving = true);
    await ref
        .read(clipListProvider.notifier)
        .updateComparisonRange(widget.clipId, startMs: null, endMs: null);
    if (mounted) {
      Navigator.pop(context);
    }
  }

  void _applyGuess(MotionRangeGuess guess) {
    setState(() {
      _values = RangeValues(
        guess.startMs.toDouble(),
        guess.endMs.toDouble(),
      );
      _activeHandleMs = guess.peakMs.toDouble();
    });
  }

  Future<void> _cutMotionRange({required bool fromUser}) async {
    final clip = _clip;
    if (clip == null || _saving || _detecting) {
      return;
    }
    if (!fromUser && (_autoCutAttempted || _userEditedRange)) {
      return;
    }
    _autoCutAttempted = true;
    final generation = ++_detectGeneration;
    setState(() => _detecting = true);
    try {
      final analysis = await ref
          .read(motionRangeAnalyzerProvider)
          .analyze(
            clipId: clip.id,
            framePaths: _preview?.absoluteFramePaths ?? const <String>[],
            durationMs: clip.durationMs,
          );
      if (!mounted || generation != _detectGeneration) {
        return;
      }
      final guess = analysis.guess;
      if (guess != null) {
        if (fromUser || !_userEditedRange) {
          _applyGuess(guess);
        }
        if (fromUser && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('山場の前後を選びました。スライダーで直せます。')),
          );
        }
        return;
      }
      if (!fromUser || !mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            analysis.unsupported
                ? 'この端末では自動切り取りできません。'
                : '動きが見つかりませんでした。手動で範囲を選んでください。',
          ),
        ),
      );
    } on Object {
      if (fromUser && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('動作区間を探せませんでした。')),
        );
      }
    } finally {
      if (mounted && generation == _detectGeneration) {
        setState(() => _detecting = false);
      }
    }
  }

  bool get _canAutoCut {
    if (_saving || _detecting || _values == null) {
      return false;
    }
    return widget.skipPreviewForTesting || _preview != null;
  }

  void _changeRange(RangeValues next) {
    final previous = _values;
    setState(() {
      _userEditedRange = true;
      _values = next;
      if (previous == null ||
          (next.start - previous.start).abs() >=
              (next.end - previous.end).abs()) {
        _activeHandleMs = next.start;
      } else {
        _activeHandleMs = next.end;
      }
    });
  }

  Future<void> _showHelp() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('比較範囲について'),
      content: const Text(
        '動画そのものは切り取られません。比較に使う範囲を選ぶだけなので、あとから何度でも変更できます。'
        '撮影は最大30秒です。「動作区間を自動で切る」は、その中で動きが大きいところを10秒以内で提案します。',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('閉じる'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final clips = ref.watch(clipListProvider).value ?? <Clip>[];
    Clip? clip;
    for (final candidate in clips) {
      if (candidate.id == widget.clipId) {
        clip = candidate;
        break;
      }
    }
    if (clip != null && _values == null && !_loadScheduled) {
      _loadScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadPreview());
    }
    final values = _values;
    return Scaffold(
      appBar: AppBar(
        title: const Text('比較範囲を選択'),
        actions: <Widget>[
          IconButton(
            key: const Key('comparison-range-help'),
            onPressed: _showHelp,
            icon: const Icon(Icons.help_outline),
            tooltip: '説明',
          ),
        ],
      ),
      body: clip == null
          ? const Center(child: Text('クリップが見つかりません。'))
          : Padding(
              padding: EdgeInsets.fromLTRB(
                14,
                4,
                14,
                8 + MediaQuery.viewPaddingOf(context).bottom,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: ColoredBox(
                        color: Colors.black,
                        child: switch (_preview) {
                          final preview? => _HandlePreview(
                            paths: preview.absoluteFramePaths,
                            durationMs: clip.durationMs,
                            positionMs: _activeHandleMs ?? values?.start ?? 0,
                          ),
                          null => Center(
                            child: _error != null
                                ? Padding(
                                    padding: const EdgeInsets.all(20),
                                    child: Text(
                                      _error!,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.errorContainer,
                                      ),
                                    ),
                                  )
                                : Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      CircularProgressIndicator(
                                        value: _progress?.fraction,
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        _progress == null
                                            ? 'プレビューを準備しています…'
                                            : 'プレビュー ${_progress!.completedFrames} / '
                                                  '${_progress!.totalFrames}',
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (values != null) ...<Widget>[
                    SizedBox(
                      height: 64,
                      child: Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          if (_preview case final preview?)
                            _PreviewStrip(paths: preview.absoluteFramePaths)
                          else
                            ColoredBox(
                              color: Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHighest,
                            ),
                          RangeSlider(
                            key: const Key('comparison-range-slider'),
                            values: values,
                            min: 0,
                            max: math.max(1, clip.durationMs).toDouble(),
                            divisions: math.max(1, clip.durationMs ~/ 100),
                            labels: RangeLabels(
                              _formatSeconds(values.start),
                              _formatSeconds(values.end),
                            ),
                            onChanged: _saving ? null : _changeRange,
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  if (values != null) ...<Widget>[
                    Text(
                      '選択中: ${_formatSeconds(values.end - values.start)} '
                      '/ 全体${_formatSeconds(clip.durationMs)}',
                      key: const Key('selected-range-duration'),
                      style: Theme.of(context).textTheme.titleMedium,
                      textAlign: TextAlign.center,
                    ),
                    if (!_isValidRange)
                      Text(
                        '比較範囲は10秒以内にしてください。',
                        key: const Key('range-validation-error'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                        textAlign: TextAlign.center,
                      ),
                  ],
                  const SizedBox(height: 8),
                  OutlinedButton(
                    key: const Key('auto-cut-motion-range'),
                    onPressed: _canAutoCut
                        ? () => unawaited(_cutMotionRange(fromUser: true))
                        : null,
                    child: Text(
                      _detecting ? '動きを探しています…' : '動作区間を自動で切る',
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton(
                    key: const Key('save-comparison-range'),
                    onPressed: _isValidRange && !_saving ? _save : null,
                    child: const Text('保存'),
                  ),
                  TextButton(
                    key: const Key('reset-comparison-range'),
                    onPressed: !_saving && clip.hasComparisonRange
                        ? _reset
                        : null,
                    child: const Text('リセット'),
                  ),
                ],
              ),
            ),
    );
  }
}

class _PreviewStrip extends StatelessWidget {
  const _PreviewStrip({required this.paths});

  final List<String> paths;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Row(
        children: <Widget>[
          for (final path in paths)
            Expanded(child: Image.file(File(path), fit: BoxFit.cover)),
        ],
      ),
    );
  }
}

class _HandlePreview extends StatelessWidget {
  const _HandlePreview({
    required this.paths,
    required this.durationMs,
    required this.positionMs,
  });

  final List<String> paths;
  final int durationMs;
  final double positionMs;

  @override
  Widget build(BuildContext context) {
    final fraction = durationMs <= 0 ? 0.0 : positionMs / durationMs;
    final index = (fraction * (paths.length - 1)).round().clamp(
      0,
      paths.length - 1,
    );
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Image.file(
        File(paths[index]),
        key: const Key('active-handle-preview'),
        fit: BoxFit.contain,
      ),
    );
  }
}

String _formatSeconds(num milliseconds) {
  return '${(milliseconds / 1000).toStringAsFixed(1)}秒';
}
