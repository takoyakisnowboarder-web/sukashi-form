import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';

import '../data/clip_gallery_saver.dart';
import '../models/clip.dart' as model;
import '../providers/clip_providers.dart';
import '../pose/pose_movement_dialog.dart';
import '../providers/pose_providers.dart';

enum _ClipAction {
  selectRange,
  exportPose,
  saveToPhotos,
  extractFrames,
  editMemo,
  delete,
}

typedef ThumbnailWidgetBuilder = Widget Function(String path, Key key);

final thumbnailWidgetBuilderProvider = Provider<ThumbnailWidgetBuilder>((ref) {
  return (path, key) => Image.file(
    File(path),
    key: key,
    fit: BoxFit.cover,
    errorBuilder: (context, error, stackTrace) {
      return const _ThumbnailPlaceholder();
    },
  );
});

final thumbnailAbsolutePathProvider = FutureProvider.family<String, String>((
  ref,
  relativePath,
) {
  return ref.watch(clipRepositoryProvider).resolveAbsolutePath(relativePath);
});

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clips = ref.watch(clipListProvider);
    final selectedIds = ref.watch(clipSelectionProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('オフトレカイセキ')),
      body: clips.when(
        data: (items) => items.isEmpty
            ? const _EmptyLibrary()
            : _ClipGrid(clips: items, selectedIds: selectedIds),
        error: (error, stackTrace) =>
            _LoadError(onRetry: () => ref.invalidate(clipListProvider)),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          FloatingActionButton.extended(
            heroTag: 'import-video',
            onPressed: () => _importVideo(context, ref),
            icon: const Icon(Icons.video_library_outlined),
            label: const Text('動画を取り込む'),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'capture-video',
            onPressed: () => context.push('/capture'),
            icon: const Icon(Icons.videocam_outlined),
            label: const Text('撮影'),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: FilledButton.icon(
          onPressed: selectedIds.length == 2
              ? () {
                  final ids = Uri.encodeQueryComponent(selectedIds.join(','));
                  context.push('/compare?ids=$ids');
                }
              : null,
          icon: const Icon(Icons.compare),
          label: Text(
            selectedIds.length == 2
                ? '比較する'
                : '比較するクリップを2本選択 (${selectedIds.length}/2)',
          ),
        ),
      ),
    );
  }

  Future<void> _importVideo(BuildContext context, WidgetRef ref) async {
    try {
      final picked = await ImagePicker().pickVideo(source: ImageSource.gallery);
      if (picked == null) {
        return;
      }
      await ref
          .read(clipListProvider.notifier)
          .importVideoPath(picked.path, durationMs: 0);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('動画を取り込みました。')));
      }
    } on Object {
      ref.invalidate(clipListProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('動画を取り込めませんでした。')));
      }
    }
  }
}

class _ClipGrid extends ConsumerWidget {
  const _ClipGrid({required this.clips, required this.selectedIds});

  final List<model.Clip> clips;
  final List<String> selectedIds;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 240,
        childAspectRatio: 0.78,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: clips.length,
      itemBuilder: (context, index) {
        final clip = clips[index];
        final selectionIndex = selectedIds.indexOf(clip.id);
        return _ClipCard(
          clip: clip,
          selectionNumber: selectionIndex < 0 ? null : selectionIndex + 1,
          onTap: () {
            if (clip.isBroken) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('この動画は比較に使用できません。')));
              return;
            }
            ref.read(clipSelectionProvider.notifier).toggle(clip.id);
          },
          onLongPress: () => _showClipActions(context, ref, clip),
        );
      },
    );
  }

  Future<void> _showClipActions(
    BuildContext context,
    WidgetRef ref,
    model.Clip clip,
  ) async {
    final action = await showModalBottomSheet<_ClipAction>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: <Widget>[
            if (!clip.isBroken)
              ListTile(
                leading: const Icon(Icons.content_cut),
                title: const Text('比較範囲を選択'),
                onTap: () => Navigator.pop(context, _ClipAction.selectRange),
              ),
            if (!clip.isBroken)
              ListTile(
                key: Key('export-pose-${clip.id}'),
                leading: const Icon(Icons.download_outlined),
                title: const Text('座標を保存'),
                subtitle: const Text('この1本だけをJSONで書き出します'),
                onTap: () => Navigator.pop(context, _ClipAction.exportPose),
              ),
            if (!clip.isBroken)
              ListTile(
                key: Key('save-to-photos-${clip.id}'),
                leading: const Icon(Icons.photo_outlined),
                title: const Text('写真に保存'),
                subtitle: const Text('端末の写真アプリへコピーします'),
                onTap: () => Navigator.pop(context, _ClipAction.saveToPhotos),
              ),
            if (kDebugMode)
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('フレーム展開（開発用）'),
                onTap: () => Navigator.pop(context, _ClipAction.extractFrames),
              ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('メモを編集'),
              onTap: () => Navigator.pop(context, _ClipAction.editMemo),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('削除'),
              onTap: () => Navigator.pop(context, _ClipAction.delete),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted || action == null) {
      return;
    }
    switch (action) {
      case _ClipAction.selectRange:
        await context.push('/comparison-range/${clip.id}');
      case _ClipAction.exportPose:
        await _exportPose(context, ref, clip);
      case _ClipAction.saveToPhotos:
        await _saveToPhotos(context, ref, clip);
      case _ClipAction.extractFrames:
        await context.push('/debug/frame-extraction/${clip.id}');
      case _ClipAction.editMemo:
        await _editMemo(context, ref, clip);
      case _ClipAction.delete:
        await _confirmDelete(context, ref, clip);
    }
  }

  Future<void> _saveToPhotos(
    BuildContext context,
    WidgetRef ref,
    model.Clip clip,
  ) async {
    try {
      await ref.read(clipGallerySaverProvider).save(clip);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('写真に保存しました。')));
      }
    } on Object {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('写真に保存できませんでした。')));
      }
    }
  }

  Future<void> _exportPose(
    BuildContext context,
    WidgetRef ref,
    model.Clip clip,
  ) async {
    if (clip.durationMs > 10000 && !clip.hasComparisonRange) {
      final choose = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('比較範囲が必要です'),
          content: const Text('10秒を超えるクリップは、切り取った範囲の座標だけを1本分保存します。'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('範囲を選択'),
            ),
          ],
        ),
      );
      if (choose == true && context.mounted) {
        await context.push('/comparison-range/${clip.id}');
      }
      return;
    }

    final movement = await askPoseMovement(context);
    if (!context.mounted || movement == null) {
      return;
    }

    final dialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return const AlertDialog(
          content: Row(
            children: <Widget>[
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Expanded(
                child: Text(
                  'この1本の座標を準備しています…',
                  key: Key('pose-export-progress'),
                ),
              ),
            ],
          ),
        );
      },
    );

    try {
      final box = context.findRenderObject() as RenderBox?;
      await ref
          .read(poseClipExporterProvider)
          .exportClip(
            clip,
            movement: movement,
            sharePositionOrigin: box == null
                ? null
                : box.localToGlobal(Offset.zero) & box.size,
          );
    } on Object catch (error) {
      if (context.mounted) {
        final message = error is FormatException
            ? error.message
            : '座標データの保存に失敗しました。';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
    await dialog;
  }

  Future<void> _editMemo(
    BuildContext context,
    WidgetRef ref,
    model.Clip clip,
  ) async {
    // TextEditingControllerの寿命はダイアログ自身に持たせる。
    // showDialogの完了直後にdisposeすると、退場アニメーション中のTextFieldが
    // 破棄済みcontrollerを参照し、要素ツリーの破棄順序が壊れてクラッシュする。
    final memo = await showDialog<String>(
      context: context,
      builder: (context) => _MemoEditDialog(initialMemo: clip.memo),
    );
    if (memo != null) {
      await ref.read(clipListProvider.notifier).updateMemo(clip.id, memo);
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    model.Clip clip,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('クリップを削除しますか？'),
        content: const Text('動画、サムネイル、フレームキャッシュが端末から削除されます。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    ref.read(clipSelectionProvider.notifier).remove(clip.id);
    await ref.read(clipListProvider.notifier).delete(clip.id);
  }
}

class _ClipCard extends StatelessWidget {
  const _ClipCard({
    required this.clip,
    required this.selectionNumber,
    required this.onTap,
    required this.onLongPress,
  });

  final model.Clip clip;
  final int? selectionNumber;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final selected = selectionNumber != null;
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected
              ? Theme.of(context).colorScheme.primary
              : Colors.transparent,
          width: 3,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  _ClipThumbnail(clip: clip),
                  if (clip.isBroken)
                    const ColoredBox(
                      color: Color(0x99000000),
                      child: Center(
                        child: Padding(
                          padding: EdgeInsets.all(12),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Icon(
                                  Icons.broken_image_outlined,
                                  color: Colors.white,
                                  size: 40,
                                ),
                                SizedBox(height: 8),
                                Text(
                                  'この動画は読み込めません',
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (selected)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: CircleAvatar(
                        radius: 16,
                        child: Text('$selectionNumber'),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    DateFormat('yyyy/MM/dd HH:mm').format(clip.recordedAt),
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(_formatDuration(clip.durationMs)),
                  if (clip.hasComparisonRange) ...<Widget>[
                    const SizedBox(height: 4),
                    Row(
                      key: ValueKey<String>('comparison-range-${clip.id}'),
                      children: <Widget>[
                        const Icon(Icons.content_cut, size: 15),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            '${_formatDuration(clip.comparisonRangeDurationMs!)}'
                            ' / 全体${_formatDuration(clip.durationMs)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    clip.memo ?? 'メモなし',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: clip.memo == null ? Colors.black45 : null,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(int durationMs) {
    if (durationMs == 0) {
      return '—';
    }
    final totalSeconds = durationMs / 1000;
    return '${totalSeconds.toStringAsFixed(1)}秒';
  }
}

class _ClipThumbnail extends ConsumerWidget {
  const _ClipThumbnail({required this.clip});

  final model.Clip clip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final relativePath = clip.thumbnailPath;
    if (relativePath == null) {
      return const _ThumbnailPlaceholder();
    }
    return ref
        .watch(thumbnailAbsolutePathProvider(relativePath))
        .when(
          data: (path) => ref.watch(thumbnailWidgetBuilderProvider)(
            path,
            ValueKey<String>('thumbnail-${clip.id}'),
          ),
          error: (error, stackTrace) => const _ThumbnailPlaceholder(),
          loading: () => const _ThumbnailPlaceholder(),
        );
  }
}

class _ThumbnailPlaceholder extends StatelessWidget {
  const _ThumbnailPlaceholder();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.grey.shade300,
      child: const Center(
        child: Icon(Icons.sports_gymnastics, size: 52, color: Colors.black45),
      ),
    );
  }
}

class _MemoEditDialog extends StatefulWidget {
  const _MemoEditDialog({this.initialMemo});

  final String? initialMemo;

  @override
  State<_MemoEditDialog> createState() => _MemoEditDialogState();
}

class _MemoEditDialogState extends State<_MemoEditDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialMemo ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('メモを編集'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 80,
        decoration: const InputDecoration(hintText: '例: 調子○'),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.video_library_outlined, size: 64),
            SizedBox(height: 16),
            Text('まだクリップがありません'),
            SizedBox(height: 8),
            Text('右下の「撮影」または「動画を取り込む」から追加しましょう'),
          ],
        ),
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text('クリップを読み込めませんでした'),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('再試行')),
        ],
      ),
    );
  }
}
