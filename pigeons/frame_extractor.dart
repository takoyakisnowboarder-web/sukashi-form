import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/native/frame_extractor.g.dart',
    dartOptions: DartOptions(),
    kotlinOut:
        'android/app/src/main/kotlin/com/sukashiform/app/FrameExtractorApi.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.sukashiform.app'),
    swiftOut: 'ios/Runner/FrameExtractorApi.g.swift',
    swiftOptions: SwiftOptions(),
    dartPackageName: 'sukashi_form',
  ),
)
class VideoInfo {
  VideoInfo({
    required this.isValid,
    required this.durationMs,
    required this.width,
    required this.height,
    this.rotationDegrees,
    this.errorReason,
  });

  bool isValid;
  int durationMs;
  int width;
  int height;
  int? rotationDegrees;
  String? errorReason;
}

class ExtractRequest {
  ExtractRequest({
    required this.absoluteVideoPath,
    required this.absoluteOutputDir,
    required this.maxLongEdgePx,
    required this.maxFrames,
    required this.jpegQuality,
    this.rangeStartMs,
    this.rangeEndMs,
  });

  String absoluteVideoPath;
  String absoluteOutputDir;
  int maxLongEdgePx;
  int maxFrames;
  int jpegQuality;
  int? rangeStartMs;
  int? rangeEndMs;
}

class ExtractResult {
  ExtractResult({
    required this.isComplete,
    required this.frameCount,
    required this.sourceDurationMs,
    required this.sourceFps,
    this.errorReason,
  });

  bool isComplete;
  int frameCount;
  int sourceDurationMs;
  double sourceFps;
  String? errorReason;
}

@HostApi()
abstract class FrameExtractorApi {
  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  VideoInfo probe(String absoluteVideoPath);

  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  String generateThumbnail(
    String absoluteVideoPath,
    String absoluteOutputPath,
    int maxLongEdgePx,
  );

  @async
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  ExtractResult extractFrames(String taskId, ExtractRequest request);

  void cancelExtraction(String taskId);
}

@FlutterApi()
abstract class FrameExtractionProgressApi {
  void onProgress(String taskId, int completedFrames, int totalFrames);
}
