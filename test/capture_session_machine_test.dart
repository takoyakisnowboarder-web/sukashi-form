import 'package:flutter_test/flutter_test.dart';
import 'package:sukashi_form/capture/capture_session_machine.dart';
import 'package:sukashi_form/models/app_settings.dart';

void main() {
  test('3秒カウントダウン後に録画開始へ遷移する', () {
    final machine = CaptureSessionMachine();

    expect(machine.start(3, 10), isNull);
    expect(machine.phase, CapturePhase.countingDown);
    expect(machine.tick(), isNull);
    expect(machine.countdownRemaining, 2);
    expect(machine.tick(), isNull);
    expect(machine.countdownRemaining, 1);
    expect(machine.tick(), CaptureEvent.recordingStarted);
    expect(machine.phase, CapturePhase.recording);
  });

  test('録画開始から10秒で自動停止イベントを返す', () {
    final machine = CaptureSessionMachine();

    expect(machine.start(0, 10), CaptureEvent.recordingStarted);
    for (var second = 1; second < 10; second += 1) {
      expect(machine.tick(), isNull);
      expect(machine.recordingRemainingSeconds, 10 - second);
    }
    expect(machine.tick(), CaptureEvent.recordingAutoStopped);
    expect(machine.phase, CapturePhase.stopping);
    expect(machine.recordingRemainingSeconds, 0);
  });

  for (final duration in AppSettings.recordingOptions) {
    test('録画時間$duration秒で自動停止する', () {
      final machine = CaptureSessionMachine();

      expect(machine.start(0, duration), CaptureEvent.recordingStarted);
      for (var second = 1; second < duration; second += 1) {
        expect(machine.tick(), isNull);
      }
      expect(machine.tick(), CaptureEvent.recordingAutoStopped);
      expect(machine.recordingElapsedSeconds, duration);
    });
  }

  test('5秒カウントダウン後に20秒録画の組み合わせで動く', () {
    final machine = CaptureSessionMachine();

    expect(machine.start(5, 20), isNull);
    for (var second = 1; second < 5; second += 1) {
      expect(machine.tick(), isNull);
    }
    expect(machine.tick(), CaptureEvent.recordingStarted);
    expect(machine.recordingRemainingSeconds, 20);
  });
}
