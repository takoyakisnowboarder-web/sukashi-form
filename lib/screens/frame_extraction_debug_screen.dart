import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/frame_cache_service.dart';
import '../models/clip.dart';
import '../providers/clip_providers.dart';
import '../providers/frame_extraction_providers.dart';

class FrameExtractionDebugScreen extends ConsumerStatefulWidget {
  const FrameExtractionDebugScreen({required this.clipId, super.key});

  final String clipId;

  @override
  ConsumerState<FrameExtractionDebugScreen> createState() =>
      _FrameExtractionDebugScreenState();
}

class _FrameExtractionDebugScreenState
    extends ConsumerState<FrameExtractionDebugScreen> {
  FrameExtractionSession? _session;
  StreamSubscription<FrameExtractionProgress>? _progressSubscription;
  FrameExtractionProgress? _progress;
  FrameCacheResult? _result;
  String? _error;
  bool _isRunning = false;
  Duration? _elapsed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    unawaited(_progressSubscription?.cancel());
    unawaited(_session?.cancel());
    super.dispose();
  }

  Future<void> _start() async {
    final clip = _findClip();
    if (clip == null) {
      setState(() => _error = 'クリップが見つかりません。');
      return;
    }
    await _progressSubscription?.cancel();
    final session = ref.read(frameCacheServiceProvider).startExtraction(clip);
    final stopwatch = Stopwatch()..start();
    setState(() {
      _session = session;
      _progress = null;
      _result = null;
      _error = null;
      _elapsed = null;
      _isRunning = true;
    });
    _progressSubscription = session.progress.listen((progress) {
      if (mounted) {
        setState(() => _progress = progress);
      }
    });
    try {
      final result = await session.result;
      stopwatch.stop();
      if (mounted) {
        setState(() {
          _result = result;
          _elapsed = stopwatch.elapsed;
          _isRunning = false;
        });
      }
    } on FrameExtractionCancelled {
      if (mounted) {
        setState(() {
          _error = '展開をキャンセルしました。';
          _isRunning = false;
        });
      }
    } on FrameExtractionException catch (error) {
      if (mounted) {
        setState(() {
          _error = _messageFor(error.reason);
          _isRunning = false;
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _error = 'フレームを展開できませんでした。';
          _isRunning = false;
        });
      }
    }
  }

  Clip? _findClip() {
    final clips = ref.read(clipListProvider).value ?? <Clip>[];
    return clips.where((clip) => clip.id == widget.clipId).firstOrNull;
  }

  String _messageFor(String reason) {
    return switch (reason) {
      'broken_clip' => '破損した動画は展開できません。',
      'cancelled' => '展開をキャンセルしました。',
      _ => 'フレームを展開できませんでした（$reason）。',
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('フレーム展開（開発用）')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          if (_isRunning) ...<Widget>[
            LinearProgressIndicator(value: _progress?.fraction),
            const SizedBox(height: 12),
            Text(
              _progress == null
                  ? '展開を準備しています…'
                  : '${_progress!.completedFrames} / '
                        '${_progress!.totalFrames} フレーム',
              key: const Key('frame-extraction-progress'),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _session?.cancel(),
              icon: const Icon(Icons.close),
              label: const Text('キャンセル'),
            ),
          ],
          if (_error != null) ...<Widget>[
            Text(
              _error!,
              key: const Key('frame-extraction-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _start,
              icon: const Icon(Icons.refresh),
              label: const Text('再試行'),
            ),
          ],
          if (_result case final result?) ...<Widget>[
            Text(
              '${result.frameCount}枚展開しました',
              key: const Key('frame-extraction-result'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            Text(result.fromCache ? 'キャッシュから読み込みました' : '新しく展開しました'),
            Text('所要時間: ${_elapsed?.inMilliseconds ?? 0}ms'),
            Text(result.isComplete ? '動画全体を展開しました' : '10秒／600枚の上限で打ち切りました'),
            Text(
              '元動画: ${result.sourceDurationMs}ms / '
              '${result.sourceFps.toStringAsFixed(2)}fps',
            ),
            const SizedBox(height: 16),
            _FrameSamples(paths: result.absoluteFramePaths),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _start,
              icon: const Icon(Icons.cached),
              label: const Text('もう一度開く'),
            ),
          ],
        ],
      ),
    );
  }
}

class _FrameSamples extends StatelessWidget {
  const _FrameSamples({required this.paths});

  final List<String> paths;

  @override
  Widget build(BuildContext context) {
    final indexes = <int>{0, paths.length ~/ 2, paths.length - 1}.toList()
      ..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final index in indexes) ...<Widget>[
          Text(
            index == 0
                ? '最初のフレーム'
                : index == paths.length - 1
                ? '最後のフレーム'
                : '中間のフレーム',
          ),
          const SizedBox(height: 6),
          AspectRatio(
            aspectRatio: 9 / 16,
            child: Image.file(
              File(paths[index]),
              key: ValueKey<String>('sample-frame-$index'),
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) =>
                  const Center(child: Text('画像を表示できません')),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
