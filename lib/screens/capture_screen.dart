import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../capture/capture_session_machine.dart';
import '../capture/grid_overlay.dart';
import '../models/app_settings.dart';
import '../native/capture_device_bridge.dart';
import '../providers/clip_providers.dart';
import '../providers/settings_providers.dart';

class CaptureScreen extends ConsumerStatefulWidget {
  const CaptureScreen({super.key});

  @override
  ConsumerState<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends ConsumerState<CaptureScreen>
    with WidgetsBindingObserver {
  final CaptureSessionMachine _session = CaptureSessionMachine();
  CameraController? _cameraController;
  Timer? _ticker;
  Stopwatch? _recordingStopwatch;
  String? _cameraErrorCode;
  bool _isInitializing = true;
  bool _isSaving = false;
  bool _gallerySaveSupported = false;
  late final CaptureDeviceBridge _deviceBridge;
  late final RecordedVideoSaver _recordedVideoSaver;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _deviceBridge = ref.read(captureDeviceBridgeProvider);
    _recordedVideoSaver = RecordedVideoSaver(_deviceBridge);
    unawaited(
      SystemChrome.setPreferredOrientations(<DeviceOrientation>[
        DeviceOrientation.portraitUp,
      ]),
    );
    unawaited(_initializeCamera());
    unawaited(_initializeDeviceFeatures());
  }

  Future<void> _initializeDeviceFeatures() async {
    try {
      final supported = await _deviceBridge.isGallerySaveSupported();
      if (mounted) {
        setState(() => _gallerySaveSupported = supported);
      }
      await _deviceBridge.enableVolumeKeyCapture(() {
        if (!mounted) return;
        final settings =
            ref.read(appSettingsProvider).value ?? AppSettings.defaults;
        _onRecordPressed(settings);
      });
    } on Object {
      // Camera controls remain usable if optional native integrations fail.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    unawaited(_deviceBridge.disableVolumeKeyCapture().catchError((_) {}));
    unawaited(_disposeCamera());
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (_cameraController == null && mounted && !_isInitializing) {
          unawaited(_initializeCamera());
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _ticker?.cancel();
        _session.reset();
        unawaited(_disposeCamera());
    }
  }

  Future<void> _initializeCamera() async {
    if (!mounted) {
      return;
    }
    setState(() {
      _isInitializing = true;
      _cameraErrorCode = null;
    });
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw CameraException('NoCamera', '利用できるカメラがありません。');
      }
      final selected = cameras.where(
        (camera) => camera.lensDirection == CameraLensDirection.back,
      );
      final description = selected.isEmpty ? cameras.first : selected.first;
      final controller = CameraController(
        description,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      final previous = _cameraController;
      _cameraController = controller;
      await previous?.dispose();
      setState(() => _isInitializing = false);
    } on CameraException catch (error) {
      if (mounted) {
        setState(() {
          _cameraErrorCode = error.code;
          _isInitializing = false;
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _cameraErrorCode = 'CameraUnavailable';
          _isInitializing = false;
        });
      }
    }
  }

  Future<void> _disposeCamera() async {
    final controller = _cameraController;
    _cameraController = null;
    await controller?.dispose();
    if (mounted) {
      setState(() {});
    }
  }

  void _onRecordPressed(AppSettings settings) {
    if (_isSaving || _cameraController?.value.isInitialized != true) {
      return;
    }
    switch (_session.phase) {
      case CapturePhase.idle:
        final event = _session.start(
          settings.countdownSeconds,
          settings.recordingSeconds,
        );
        setState(() {});
        if (event == CaptureEvent.recordingStarted) {
          unawaited(_startRecording());
        } else {
          _startTicker();
        }
      case CapturePhase.countingDown:
        _ticker?.cancel();
        _session.cancelCountdown();
        setState(() {});
      case CapturePhase.recording:
        unawaited(_stopRecording());
      case CapturePhase.stopping:
        return;
    }
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final event = _session.tick();
      setState(() {});
      if (event == CaptureEvent.recordingStarted) {
        unawaited(_startRecording());
      } else if (event == CaptureEvent.recordingAutoStopped) {
        timer.cancel();
        unawaited(_stopRecording());
      }
    });
  }

  Future<void> _startRecording() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      _resetSessionWithMessage('カメラを開始できませんでした。');
      return;
    }
    try {
      await controller.startVideoRecording();
      _recordingStopwatch = Stopwatch()..start();
      if (_ticker == null || !_ticker!.isActive) {
        _startTicker();
      }
    } on CameraException {
      _resetSessionWithMessage('録画を開始できませんでした。');
    }
  }

  Future<void> _stopRecording() async {
    if (_isSaving) {
      return;
    }
    final controller = _cameraController;
    if (controller == null || !controller.value.isRecordingVideo) {
      _resetSessionWithMessage('録画データを取得できませんでした。');
      return;
    }
    _ticker?.cancel();
    _session.markStopping();
    setState(() => _isSaving = true);
    try {
      final recordedFile = await controller.stopVideoRecording();
      _recordingStopwatch?.stop();
      final durationMs =
          _recordingStopwatch?.elapsedMilliseconds ??
          _session.recordingElapsedSeconds * 1000;
      final settings =
          ref.read(appSettingsProvider).value ?? AppSettings.defaults;
      final result = await _recordedVideoSaver.save(
        sourcePath: recordedFile.path,
        durationMs: durationMs,
        saveToGallery: settings.saveToGallery,
        gallerySaveSupported: _gallerySaveSupported,
        importIntoLibrary: (path, {required durationMs}) async {
          await ref
              .read(clipListProvider.notifier)
              .importVideoPath(path, durationMs: durationMs);
        },
      );
      _session.reset();
      if (mounted) {
        final messenger = ScaffoldMessenger.of(context);
        context.pop();
        if (result.gallerySaveFailed) {
          messenger.showSnackBar(
            const SnackBar(content: Text('動画は保存しましたが、ギャラリーへコピーできませんでした。')),
          );
        }
      }
    } on Object {
      _session.reset();
      if (mounted) {
        setState(() => _isSaving = false);
        _showMessage('動画を保存できませんでした。');
      }
    }
  }

  void _resetSessionWithMessage(String message) {
    _ticker?.cancel();
    _recordingStopwatch?.stop();
    _session.reset();
    if (mounted) {
      setState(() => _isSaving = false);
      _showMessage(message);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final settings =
        ref.watch(appSettingsProvider).value ?? AppSettings.defaults;
    if (_isInitializing) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_cameraController?.value.isInitialized != true) {
      return _CameraUnavailableView(
        permissionDenied: _cameraErrorCode?.contains('AccessDenied') ?? false,
        onRetry: _initializeCamera,
      );
    }
    return PopScope(
      canPop:
          _session.phase != CapturePhase.recording &&
          _session.phase != CapturePhase.stopping &&
          !_isSaving,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            CameraPreview(_cameraController!),
            GridOverlay(gridType: settings.gridType),
            SafeArea(
              child: Column(
                children: <Widget>[
                  _CaptureTopBar(
                    session: _session,
                    settings: settings,
                    gallerySaveSupported: _gallerySaveSupported,
                    onClose: () => context.pop(),
                    onCycleGrid: () =>
                        ref.read(appSettingsProvider.notifier).cycleGrid(),
                    onGalleryChanged: (enabled) => ref
                        .read(appSettingsProvider.notifier)
                        .setSaveToGallery(enabled),
                  ),
                  const Spacer(),
                  if (_session.phase == CapturePhase.countingDown)
                    Text(
                      '${_session.countdownRemaining}',
                      key: const Key('countdown-display'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 96,
                        fontWeight: FontWeight.bold,
                        shadows: <Shadow>[Shadow(blurRadius: 8)],
                      ),
                    ),
                  const Spacer(),
                  _CaptureControls(
                    settings: settings,
                    phase: _session.phase,
                    isSaving: _isSaving,
                    onCycleCountdown: () =>
                        ref.read(appSettingsProvider.notifier).cycleCountdown(),
                    onCycleRecordingDuration: () => ref
                        .read(appSettingsProvider.notifier)
                        .cycleRecordingDuration(),
                    onRecord: () => _onRecordPressed(settings),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CaptureTopBar extends StatelessWidget {
  const _CaptureTopBar({
    required this.session,
    required this.settings,
    required this.gallerySaveSupported,
    required this.onClose,
    required this.onCycleGrid,
    required this.onGalleryChanged,
  });

  final CaptureSessionMachine session;
  final AppSettings settings;
  final bool gallerySaveSupported;
  final VoidCallback onClose;
  final VoidCallback onCycleGrid;
  final ValueChanged<bool> onGalleryChanged;

  @override
  Widget build(BuildContext context) {
    final isRecording =
        session.phase == CapturePhase.recording ||
        session.phase == CapturePhase.stopping;
    final canChange = session.phase == CapturePhase.idle;
    return Padding(
      // 右側は端末端ぎりぎりだとチップのラベル末尾が切れるため広めに取る。
      padding: const EdgeInsets.fromLTRB(12, 12, 20, 12),
      child: Row(
        children: <Widget>[
          IconButton.filledTonal(
            onPressed: isRecording ? null : onClose,
            icon: const Icon(Icons.close),
          ),
          const SizedBox(width: 8),
          // Spacer(flex:1)を使うと、後続のFlexible(既定flex:1)と横幅を50:50で
          // 分け合ってしまい、右側のチップ列が画面残り幅の半分しか使えず
          // ラベルがフェード表示で切り詰められる。Expanded+右寄せAlignで
          // 残り幅を丸ごとチップ側に渡す。
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: isRecording
                  ? DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        child: Text(
                          '残り ${session.recordingRemainingSeconds}秒',
                          key: const Key('recording-remaining'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    )
                  : Wrap(
                      key: const Key('capture-top-settings'),
                      alignment: WrapAlignment.end,
                      spacing: 6,
                      runSpacing: 4,
                      children: <Widget>[
                        ActionChip(
                          key: const Key('grid-button'),
                          avatar: const Icon(Icons.grid_on, size: 18),
                          label: Text(settings.gridType.label),
                          onPressed: canChange ? onCycleGrid : null,
                        ),
                        if (gallerySaveSupported)
                          FilterChip(
                            key: const Key('gallery-save-toggle'),
                            avatar: const Icon(
                              Icons.video_library_outlined,
                              size: 18,
                            ),
                            // 「ギャラリー ON/OFF」だと幅が足りず末尾が切れるため、
                            // ラベルは短く固定し、ON/OFFはFilterChipの選択状態
                            // (チェックマーク)で示す。
                            label: const Text('ギャラリー'),
                            tooltip: settings.saveToGallery
                                ? 'ギャラリーへ自動保存: ON'
                                : 'ギャラリーへ自動保存: OFF',
                            selected: settings.saveToGallery,
                            onSelected: canChange ? onGalleryChanged : null,
                          ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CaptureControls extends StatelessWidget {
  const _CaptureControls({
    required this.settings,
    required this.phase,
    required this.isSaving,
    required this.onCycleCountdown,
    required this.onCycleRecordingDuration,
    required this.onRecord,
  });

  final AppSettings settings;
  final CapturePhase phase;
  final bool isSaving;
  final VoidCallback onCycleCountdown;
  final VoidCallback onCycleRecordingDuration;
  final VoidCallback onRecord;

  @override
  Widget build(BuildContext context) {
    final canChangeSettings = phase == CapturePhase.idle && !isSaving;
    final countdownLabel = settings.countdownSeconds == 0
        ? 'タイマーなし'
        : '${settings.countdownSeconds}秒';
    final icon = switch (phase) {
      CapturePhase.idle => Icons.fiber_manual_record,
      CapturePhase.countingDown => Icons.close,
      CapturePhase.recording => Icons.stop,
      CapturePhase.stopping => Icons.hourglass_top,
    };
    return ColoredBox(
      color: Colors.black54,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
        child: Row(
          children: <Widget>[
            Expanded(
              child: _SettingButton(
                key: const Key('countdown-button'),
                icon: Icons.timer_outlined,
                label: countdownLabel,
                onPressed: canChangeSettings ? onCycleCountdown : null,
              ),
            ),
            IconButton.filled(
              key: const Key('record-button'),
              onPressed: isSaving ? null : onRecord,
              iconSize: 42,
              style: IconButton.styleFrom(
                backgroundColor: phase == CapturePhase.recording
                    ? Colors.white
                    : Colors.red,
                foregroundColor: phase == CapturePhase.recording
                    ? Colors.red
                    : Colors.white,
              ),
              icon: Icon(icon),
            ),
            Expanded(
              child: _SettingButton(
                key: const Key('recording-duration-button'),
                icon: Icons.timelapse,
                label: '録画${settings.recordingSeconds}秒',
                onPressed: canChangeSettings ? onCycleRecordingDuration : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingButton extends StatelessWidget {
  const _SettingButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon),
          const SizedBox(height: 4),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _CameraUnavailableView extends StatelessWidget {
  const _CameraUnavailableView({
    required this.permissionDenied,
    required this.onRetry,
  });

  final bool permissionDenied;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('撮影')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.no_photography_outlined, size: 64),
              const SizedBox(height: 16),
              Text(
                permissionDenied ? '撮影にはカメラ権限が必要です。' : 'カメラを利用できません。',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              if (permissionDenied)
                const Text(
                  '権限を拒否した場合は、端末の「設定」→「アプリ」→'
                  '「スカシフォーム」→「権限」でカメラを許可し、戻って再試行してください。',
                  textAlign: TextAlign.center,
                ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('再試行'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
