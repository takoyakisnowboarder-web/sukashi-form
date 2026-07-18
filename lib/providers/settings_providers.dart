import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/settings_repository.dart';
import '../models/app_settings.dart';

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  return SettingsRepository();
});

final appSettingsProvider =
    AsyncNotifierProvider<AppSettingsNotifier, AppSettings>(
      AppSettingsNotifier.new,
    );

class AppSettingsNotifier extends AsyncNotifier<AppSettings> {
  SettingsRepository get _repository => ref.read(settingsRepositoryProvider);

  @override
  Future<AppSettings> build() => _repository.load();

  Future<void> cycleGrid() async {
    final current = state.value ?? AppSettings.defaults;
    await _save(current.copyWith(gridType: current.gridType.next));
  }

  Future<void> cycleCountdown() async {
    final current = state.value ?? AppSettings.defaults;
    await _save(
      current.copyWith(countdownSeconds: current.nextCountdownSeconds),
    );
  }

  Future<void> cycleRecordingDuration() async {
    final current = state.value ?? AppSettings.defaults;
    await _save(
      current.copyWith(recordingSeconds: current.nextRecordingSeconds),
    );
  }

  Future<void> _save(AppSettings settings) async {
    state = const AsyncLoading<AppSettings>();
    state = await AsyncValue.guard(() async {
      await _repository.save(settings);
      return settings;
    });
  }
}
