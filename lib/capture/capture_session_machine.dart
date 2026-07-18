enum CapturePhase { idle, countingDown, recording, stopping }

enum CaptureEvent { recordingStarted, recordingAutoStopped }

class CaptureSessionMachine {
  CapturePhase phase = CapturePhase.idle;
  int countdownRemaining = 0;
  int recordingElapsedSeconds = 0;
  int recordingDurationSeconds = 10;

  int get recordingRemainingSeconds =>
      recordingDurationSeconds - recordingElapsedSeconds;

  CaptureEvent? start(int countdownSeconds, int durationSeconds) {
    if (phase != CapturePhase.idle) {
      return null;
    }
    if (durationSeconds <= 0) {
      throw ArgumentError.value(durationSeconds, 'durationSeconds');
    }
    recordingElapsedSeconds = 0;
    recordingDurationSeconds = durationSeconds;
    countdownRemaining = countdownSeconds;
    if (countdownSeconds == 0) {
      phase = CapturePhase.recording;
      return CaptureEvent.recordingStarted;
    }
    phase = CapturePhase.countingDown;
    return null;
  }

  CaptureEvent? tick() {
    switch (phase) {
      case CapturePhase.countingDown:
        countdownRemaining -= 1;
        if (countdownRemaining <= 0) {
          countdownRemaining = 0;
          phase = CapturePhase.recording;
          return CaptureEvent.recordingStarted;
        }
      case CapturePhase.recording:
        recordingElapsedSeconds += 1;
        if (recordingElapsedSeconds >= recordingDurationSeconds) {
          recordingElapsedSeconds = recordingDurationSeconds;
          phase = CapturePhase.stopping;
          return CaptureEvent.recordingAutoStopped;
        }
      case CapturePhase.idle:
      case CapturePhase.stopping:
        return null;
    }
    return null;
  }

  void cancelCountdown() {
    if (phase == CapturePhase.countingDown) {
      reset();
    }
  }

  void markStopping() {
    if (phase == CapturePhase.recording) {
      phase = CapturePhase.stopping;
    }
  }

  void reset() {
    phase = CapturePhase.idle;
    countdownRemaining = 0;
    recordingElapsedSeconds = 0;
  }
}
