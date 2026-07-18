import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/frame_cache_service.dart';
import '../models/clip.dart';
import '../providers/clip_providers.dart';
import '../providers/frame_extraction_providers.dart';

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

  void _changeRange(RangeValues next) {
    final previous = _values;
    setState(() {
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
      appBar: AppBar(title: const Text('比較範囲を選択')),
      body: clip == null
          ? const Center(child: Text('クリップが見つかりません。'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                const Text('動画は切り取られません。比較に使う範囲を選ぶだけで、あとから何度でも変更できます。'),
                const SizedBox(height: 20),
                if (_preview == null && _error == null) ...<Widget>[
                  LinearProgressIndicator(value: _progress?.fraction),
                  const SizedBox(height: 8),
                  Text(
                    _progress == null
                        ? 'プレビューを準備しています…'
                        : 'プレビュー ${_progress!.completedFrames} / '
                              '${_progress!.totalFrames}',
                    textAlign: TextAlign.center,
                  ),
                ],
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (_preview case final preview?) ...<Widget>[
                  _HandlePreview(
                    paths: preview.absoluteFramePaths,
                    durationMs: clip.durationMs,
                    positionMs: _activeHandleMs ?? values?.start ?? 0,
                  ),
                  const SizedBox(height: 12),
                ],
                if (values != null) ...<Widget>[
                  SizedBox(
                    height: 88,
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
                const SizedBox(height: 16),
                if (values != null) ...<Widget>[
                  Text(
                    '選択中: ${_formatSeconds(values.end - values.start)}',
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
                const SizedBox(height: 20),
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
