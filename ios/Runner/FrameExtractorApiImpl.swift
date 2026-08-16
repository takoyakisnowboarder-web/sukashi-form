import AVFoundation
import Flutter
import Photos
import UIKit
import Vision

/// iOS 版のフレーム展開ネイティブ実装。
///
/// Android の `FrameExtractorApiImpl.kt`(MediaMetadataRetriever ベース)を
/// AVFoundation へ移植したもの。段階的に実装している:
///   - フェーズ1(実装済み): probe(尺・破損検出)/ generateThumbnail(サムネイル)
///   - フェーズ2(実装済み): extractFrames(範囲指定でのフレーム一括展開)+ 進捗 + キャンセル
///   - フェーズ3: saveVideoToGallery(Photos) / 音量キー録画は未実装
///
/// probe / generateThumbnail / extractFrames は Pigeon 側でバックグラウンドの
/// TaskQueue にディスパッチされて呼ばれるため、ここで同期的にブロッキング処理をしてよい。
/// ただし Dart への進捗通知(FrameExtractionProgressApi)はメインスレッドから呼ぶ必要がある。
final class FrameExtractorApiImpl: FrameExtractorApi {
  /// 展開の上限。Android の MAX_EXTRACTION_DURATION_MS と同じ。
  private static let maxExtractionDurationMs: Int64 = 10_000
  /// 「動画全体のプレビュー帯」とみなす閾値。これに該当する要求だけ10秒上限を外す。
  private static let previewMaxFrames: Int64 = 24
  private static let previewMaxLongEdgePx: Int64 = 240
  /// 進捗通知の間引き。毎フレーム通知すると Dart 側への往復が多すぎる。
  private static let progressReportInterval = 8

  private let progressApi: FrameExtractionProgressApi?
  private let taskLock = NSLock()
  private var cancellationTokens: [String: CancellationToken] = [:]
  private var activeGenerators: [String: AVAssetImageGenerator] = [:]

  init(progressApi: FrameExtractionProgressApi? = nil) {
    self.progressApi = progressApi
  }

  // MARK: - probe

  func probe(
    absoluteVideoPath: String,
    completion: @escaping (Result<VideoInfo, Error>) -> Void
  ) {
    completion(.success(probeVideo(path: absoluteVideoPath)))
  }

  private func probeVideo(path: String) -> VideoInfo {
    guard fileSize(at: path) > 0 else {
      return invalidInfo(FileManager.default.fileExists(atPath: path) ? "empty_file" : "file_not_found")
    }

    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let durationSeconds = CMTimeGetSeconds(asset.duration)
    guard durationSeconds.isFinite, durationSeconds > 0 else {
      return invalidInfo("invalid_duration")
    }
    let durationMs = Int64((durationSeconds * 1000.0).rounded())
    guard durationMs > 0 else {
      return invalidInfo("invalid_duration")
    }
    guard let track = asset.tracks(withMediaType: .video).first else {
      return invalidInfo("metadata_unreadable")
    }

    // naturalSize は回転適用前の符号化サイズ。Android の
    // METADATA_KEY_VIDEO_WIDTH/HEIGHT(回転前の値)と意味を揃える。
    let naturalSize = track.naturalSize
    return VideoInfo(
      isValid: true,
      durationMs: durationMs,
      width: Int64(abs(naturalSize.width).rounded()),
      height: Int64(abs(naturalSize.height).rounded()),
      rotationDegrees: rotationDegrees(from: track.preferredTransform),
      errorReason: nil
    )
  }

  // MARK: - generateThumbnail

  func generateThumbnail(
    absoluteVideoPath: String,
    absoluteOutputPath: String,
    maxLongEdgePx: Int64,
    completion: @escaping (Result<String, Error>) -> Void
  ) {
    completion(
      Result {
        guard maxLongEdgePx > 0 else {
          throw makeError("maxLongEdgePx must be positive.")
        }
        return try createThumbnail(
          videoPath: absoluteVideoPath,
          outputPath: absoluteOutputPath,
          maxLongEdgePx: Int(min(maxLongEdgePx, Int64(Int.max)))
        )
      }
    )
  }

  private func createThumbnail(
    videoPath: String,
    outputPath: String,
    maxLongEdgePx: Int
  ) throws -> String {
    guard fileSize(at: videoPath) > 0 else {
      throw makeError("Video file is missing or empty.")
    }

    let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
    let generator = AVAssetImageGenerator(asset: asset)
    // MediaMetadataRetriever と同様に回転を適用し、縦動画が横に倒れないようにする。
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxLongEdgePx, height: maxLongEdgePx)
    // 先頭(0秒)以降の最初に取れるフレームを許容(厳密一致で失敗しないように)。
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .positiveInfinity

    let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
    let outputURL = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try writeJpegAtomically(
      cgImage,
      to: outputURL,
      maxLongEdgePx: maxLongEdgePx,
      jpegQuality: 85
    )
    return outputPath
  }

  // MARK: - extractFrames

  func extractFrames(
    taskId: String,
    request: ExtractRequest,
    completion: @escaping (Result<ExtractResult, Error>) -> Void
  ) {
    let token = registerTask(taskId)
    let result: ExtractResult
    do {
      result = try extractVideoFrames(taskId: taskId, request: request, token: token)
    } catch let error as ExtractionFailure {
      result = extractionError(error.reason)
    } catch {
      result = extractionError("extract_failed:\(type(of: error))")
    }
    unregisterTask(taskId)
    completion(.success(result))
  }

  func cancelExtraction(taskId: String) throws {
    taskLock.lock()
    let token = cancellationTokens[taskId] ?? CancellationToken()
    cancellationTokens[taskId] = token
    let generator = activeGenerators[taskId]
    taskLock.unlock()
    token.cancel()
    generator?.cancelAllCGImageGeneration()
  }

  private func extractVideoFrames(
    taskId: String,
    request: ExtractRequest,
    token: CancellationToken
  ) throws -> ExtractResult {
    guard request.maxLongEdgePx > 0 else { throw ExtractionFailure("invalid_max_long_edge") }
    guard request.maxFrames > 0 else { throw ExtractionFailure("invalid_max_frames") }
    guard (1...100).contains(request.jpegQuality) else {
      throw ExtractionFailure("invalid_jpeg_quality")
    }
    guard fileSize(at: request.absoluteVideoPath) > 0 else {
      throw ExtractionFailure("video_missing_or_empty")
    }

    let asset = AVURLAsset(url: URL(fileURLWithPath: request.absoluteVideoPath))
    guard let track = asset.tracks(withMediaType: .video).first else {
      throw ExtractionFailure("frame_count_unavailable")
    }
    // コンテナの尺は音声の余りで映像より長くなることがある。
    // 3.2秒は成功して 3.4秒だけ失敗、のような差はここで出やすい。
    let assetDurationSeconds = CMTimeGetSeconds(asset.duration)
    let trackDurationSeconds = CMTimeGetSeconds(track.timeRange.duration)
    let durationSeconds: Double
    if trackDurationSeconds.isFinite, trackDurationSeconds > 0 {
      durationSeconds = min(
        assetDurationSeconds.isFinite && assetDurationSeconds > 0
          ? assetDurationSeconds
          : trackDurationSeconds,
        trackDurationSeconds
      )
    } else {
      durationSeconds = assetDurationSeconds
    }
    guard durationSeconds.isFinite, durationSeconds > 0 else {
      throw ExtractionFailure("invalid_duration")
    }
    let durationMs = Int64((durationSeconds * 1000.0).rounded())
    guard durationMs > 0 else { throw ExtractionFailure("invalid_duration") }
    let trackStartSeconds = max(0, CMTimeGetSeconds(track.timeRange.start))

    // iOS には Android の METADATA_KEY_VIDEO_FRAME_COUNT に相当する API が無いため、
    // 公称フレームレートと尺から総フレーム数を見積もる。
    // 短い取り込み動画では nominalFrameRate が 0 になることがあるので 30fps で補う。
    let reportedFps = Double(track.nominalFrameRate)
    let nominalFps = reportedFps > 1 ? reportedFps : 30.0
    let sourceFrameCount = max(1, Int((durationSeconds * nominalFps).rounded()))
    let sourceFps = Double(sourceFrameCount) / (Double(durationMs) / 1000.0)

    // --- 展開する時間範囲を決める(Android と同じ規則) ---
    let rangeStartMs = request.rangeStartMs ?? 0
    var requestedRangeEndMs =
      request.rangeEndMs
      ?? min(durationMs, rangeStartMs + Self.maxExtractionDurationMs)
    if requestedRangeEndMs > durationMs {
      requestedRangeEndMs = durationMs
    }
    guard rangeStartMs >= 0, rangeStartMs < durationMs else {
      throw ExtractionFailure("invalid_range_start")
    }
    guard requestedRangeEndMs > rangeStartMs else {
      throw ExtractionFailure("invalid_range_end")
    }
    // 動画全体のプレビュー帯(少数・低解像度)のときだけ10秒上限を外す。
    let isWholeVideoPreview =
      request.maxFrames <= Self.previewMaxFrames
      && request.maxLongEdgePx <= Self.previewMaxLongEdgePx
    let effectiveRangeEndMs =
      isWholeVideoPreview
      ? requestedRangeEndMs
      : min(requestedRangeEndMs, rangeStartMs + Self.maxExtractionDurationMs)

    // --- 範囲内のどのフレームを取るか決める ---
    let firstSourceIndex = min(
      max(Int(Double(sourceFrameCount) * Double(rangeStartMs) / Double(durationMs)), 0),
      sourceFrameCount - 1
    )
    let endSourceIndexExclusive = min(
      max(
        Int(
          (Double(sourceFrameCount) * Double(effectiveRangeEndMs) / Double(durationMs)).rounded(.up)
        ),
        firstSourceIndex + 1
      ),
      sourceFrameCount
    )
    let framesInWindow = endSourceIndexExclusive - firstSourceIndex
    let targetFrameCount = min(Int(min(request.maxFrames, Int64(Int.max))), framesInWindow)
    guard targetFrameCount > 0 else { throw ExtractionFailure("no_frames_in_range") }

    let sourceIndices = evenlySpacedIndices(
      framesInWindow: framesInWindow,
      targetCount: targetFrameCount
    ).map { $0 + firstSourceIndex }

    let outputDirectory = URL(fileURLWithPath: request.absoluteOutputDir)
    try FileManager.default.createDirectory(
      at: outputDirectory,
      withIntermediateDirectories: true
    )

    if token.isCancelled {
      return cancelledResult(completedFrames: 0, durationMs: durationMs, sourceFps: sourceFps)
    }

    // --- フレーム時刻を作る ---
    // フレーム i は [i/fps, (i+1)/fps) を占めるので、中央を要求して
    // 丸め誤差で隣のフレームを掴まないようにする。
    let timescale: CMTimeScale = 1_000_000
    var indexByTimeValue: [Int64: Int] = [:]
    var times: [NSValue] = []
    times.reserveCapacity(sourceIndices.count)
    let lastMediaSeconds = max(
      trackStartSeconds,
      trackStartSeconds + durationSeconds - (0.25 / max(sourceFps, 1))
    )
    for (outputIndex, sourceIndex) in sourceIndices.enumerated() {
      let rawSeconds = trackStartSeconds + (Double(sourceIndex) + 0.5) / sourceFps
      let seconds = min(max(trackStartSeconds, rawSeconds), lastMediaSeconds)
      let time = CMTime(
        value: CMTimeValue((seconds * Double(timescale)).rounded()),
        timescale: timescale
      )
      indexByTimeValue[time.value] = outputIndex
      times.append(NSValue(time: time))
    }

    let generator = AVAssetImageGenerator(asset: asset)
    // 回転はここで適用される。Android 同様、この後で自前回転してはいけない。
    generator.appliesPreferredTrackTransform = true
    // デコード時点で縮小させ、メモリと時間を節約する。
    generator.maximumSize = CGSize(
      width: CGFloat(request.maxLongEdgePx),
      height: CGFloat(request.maxLongEdgePx)
    )
    // コマ送りの精度は保ちつつ、短い動画や可変フレームレートで
    // 厳密時刻が無いときに隣のフレームへ倒れるようにする。
    let oneFrame = CMTime(seconds: 1.0 / max(sourceFps, 1), preferredTimescale: timescale)
    generator.requestedTimeToleranceBefore = oneFrame
    generator.requestedTimeToleranceAfter = oneFrame
    setActiveGenerator(generator, for: taskId)
    defer { setActiveGenerator(nil, for: taskId) }

    let maxLongEdgePx = Int(min(request.maxLongEdgePx, Int64(Int.max)))
    let jpegQuality = Int(request.jpegQuality)
    let totalFrames = times.count
    let stateLock = NSLock()
    var completedCount = 0
    var writtenFrames = 0
    var failureReason: String?
    var pendingRetries: [(index: Int, time: CMTime)] = []
    let finished = DispatchSemaphore(value: 0)

    sendProgress(taskId: taskId, completed: 0, total: totalFrames)
    generator.generateCGImagesAsynchronously(forTimes: times) {
      [weak self] requestedTime, cgImage, _, result, _ in
      guard let self else { return }
      var shouldSignal = false
      var progressToReport: Int?

      stateLock.lock()
      if failureReason == nil, !token.isCancelled {
        let outputIndex = self.outputIndex(
          for: requestedTime,
          indexByTimeValue: indexByTimeValue,
          timescale: timescale
        )
        switch result {
        case .succeeded:
          if let cgImage, let outputIndex {
            do {
              try self.writeJpegAtomically(
                cgImage,
                to: outputDirectory.appendingPathComponent(
                  String(format: "frame_%06d.jpg", outputIndex)
                ),
                maxLongEdgePx: maxLongEdgePx,
                jpegQuality: jpegQuality
              )
              writtenFrames += 1
              if writtenFrames % Self.progressReportInterval == 0 {
                progressToReport = writtenFrames
              }
            } catch {
              failureReason = "frame_write_failed"
            }
          } else if let outputIndex {
            pendingRetries.append((outputIndex, requestedTime))
          } else {
            failureReason = "frame_decode_failed"
          }
        case .failed:
          if let outputIndex {
            pendingRetries.append((outputIndex, requestedTime))
          } else {
            failureReason = "frame_decode_failed"
          }
        case .cancelled:
          break
        @unknown default:
          failureReason = "frame_decode_failed"
        }
      }
      completedCount += 1
      shouldSignal = completedCount == totalFrames
      stateLock.unlock()

      if let progressToReport {
        self.sendProgress(taskId: taskId, completed: progressToReport, total: totalFrames)
      }
      if shouldSignal {
        finished.signal()
      }
    }
    finished.wait()

    stateLock.lock()
    let retries = pendingRetries
    let earlyFailure = failureReason
    stateLock.unlock()

    if !token.isCancelled, earlyFailure == nil, !retries.isEmpty {
      let recovered = recoverMissingFrames(
        generator: generator,
        retries: retries,
        outputDirectory: outputDirectory,
        maxLongEdgePx: maxLongEdgePx,
        jpegQuality: jpegQuality,
        token: token
      )
      stateLock.lock()
      writtenFrames += recovered.written
      failureReason = recovered.failureReason
      stateLock.unlock()
    }

    stateLock.lock()
    let finalWritten = writtenFrames
    let finalFailure = failureReason
    stateLock.unlock()

    if token.isCancelled {
      return cancelledResult(
        completedFrames: finalWritten,
        durationMs: durationMs,
        sourceFps: sourceFps
      )
    }
    if let finalFailure {
      return extractionError(
        finalFailure,
        durationMs: durationMs,
        sourceFps: sourceFps,
        completedFrames: finalWritten
      )
    }
    // Dart 側は frame_000000..N-1 が全て存在することを前提にキャッシュを確定するため、
    // 1枚でも欠けていたら失敗として扱う。
    guard finalWritten == totalFrames else {
      return extractionError(
        "frame_count_mismatch",
        durationMs: durationMs,
        sourceFps: sourceFps,
        completedFrames: finalWritten
      )
    }
    sendProgress(taskId: taskId, completed: finalWritten, total: totalFrames)

    let hasExplicitRange = request.rangeStartMs != nil || request.rangeEndMs != nil
    let isComplete: Bool
    if isWholeVideoPreview {
      isComplete = effectiveRangeEndMs == requestedRangeEndMs
    } else if hasExplicitRange {
      isComplete =
        effectiveRangeEndMs == requestedRangeEndMs
        && Int64(framesInWindow) <= request.maxFrames
    } else {
      isComplete =
        durationMs <= Self.maxExtractionDurationMs
        && Int64(sourceFrameCount) <= request.maxFrames
    }
    return ExtractResult(
      isComplete: isComplete,
      frameCount: Int64(finalWritten),
      sourceDurationMs: durationMs,
      sourceFps: sourceFps,
      errorReason: nil
    )
  }

  private func outputIndex(
    for requestedTime: CMTime,
    indexByTimeValue: [Int64: Int],
    timescale: CMTimeScale
  ) -> Int? {
    if let exact = indexByTimeValue[requestedTime.value] {
      return exact
    }
    let seconds = CMTimeGetSeconds(requestedTime)
    guard seconds.isFinite else { return nil }
    var bestIndex: Int?
    var bestDelta = Double.infinity
    for (value, index) in indexByTimeValue {
      let candidate = Double(value) / Double(timescale)
      let delta = abs(candidate - seconds)
      if delta < bestDelta {
        bestDelta = delta
        bestIndex = index
      }
    }
    return bestDelta < 0.08 ? bestIndex : nil
  }

  private func recoverMissingFrames(
    generator: AVAssetImageGenerator,
    retries: [(index: Int, time: CMTime)],
    outputDirectory: URL,
    maxLongEdgePx: Int,
    jpegQuality: Int,
    token: CancellationToken
  ) -> (written: Int, failureReason: String?) {
    let previousBefore = generator.requestedTimeToleranceBefore
    let previousAfter = generator.requestedTimeToleranceAfter
    generator.requestedTimeToleranceBefore = .positiveInfinity
    generator.requestedTimeToleranceAfter = .positiveInfinity
    defer {
      generator.requestedTimeToleranceBefore = previousBefore
      generator.requestedTimeToleranceAfter = previousAfter
    }
    var written = 0
    var lastImage: CGImage?
    let sorted = retries.sorted { $0.index < $1.index }
    for item in sorted {
      if token.isCancelled {
        return (written, nil)
      }
      let image =
        (try? generator.copyCGImage(at: item.time, actualTime: nil))
        ?? lastImage
        ?? (try? generator.copyCGImage(at: .zero, actualTime: nil))
      guard let image else {
        return (written, "frame_decode_failed")
      }
      do {
        try writeJpegAtomically(
          image,
          to: outputDirectory.appendingPathComponent(
            String(format: "frame_%06d.jpg", item.index)
          ),
          maxLongEdgePx: maxLongEdgePx,
          jpegQuality: jpegQuality
        )
        lastImage = image
        written += 1
      } catch {
        return (written, "frame_write_failed")
      }
    }
    return (written, nil)
  }

  /// framesInWindow 個のフレームから targetCount 個を等間隔で選ぶ(Android と同じ式)。
  private func evenlySpacedIndices(framesInWindow: Int, targetCount: Int) -> [Int] {
    if targetCount <= 1 {
      return [0]
    }
    return (0..<targetCount).map { outputIndex in
      Int(
        (Double(outputIndex) * Double(framesInWindow - 1) / Double(targetCount - 1)).rounded()
      )
    }
  }

  // MARK: - ギャラリー保存

  func isGallerySaveSupported() throws -> Bool {
    return true
  }

  func saveVideoToGallery(
    absoluteVideoPath: String,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    let url = URL(fileURLWithPath: absoluteVideoPath)
    guard fileSize(at: absoluteVideoPath) > 0 else {
      completion(.failure(makeError("Recorded video is unavailable.")))
      return
    }

    let finish: (Result<Void, Error>) -> Void = { result in
      DispatchQueue.main.async {
        completion(result)
      }
    }

    let save = {
      PHPhotoLibrary.shared().performChanges({
        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
      }) { success, error in
        if success {
          finish(.success(()))
        } else {
          finish(.failure(error ?? self.makeError("Gallery saving failed.")))
        }
      }
    }

    let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    switch status {
    case .authorized, .limited:
      save()
    case .notDetermined:
      PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
        if newStatus == .authorized || newStatus == .limited {
          save()
        } else {
          finish(.failure(self.makeError("Photo library permission denied.")))
        }
      }
    default:
      finish(.failure(makeError("Photo library permission denied.")))
    }
  }

  func setVolumeKeyCaptureEnabled(enabled: Bool) throws {
    // 音量キー録画はフェーズ3。iOS には dispatchKeyEvent 相当が無いため要調査。
  }

  func detectPose(
    absoluteImagePath: String,
    completion: @escaping (Result<NativePoseResult, Error>) -> Void
  ) {
    completion(.success(detectHumanPose(at: absoluteImagePath)))
  }

  private static let visionJoints: [VNHumanBodyPoseObservation.JointName: String] = [
    .nose: "nose",
    .leftShoulder: "leftShoulder",
    .rightShoulder: "rightShoulder",
    .leftElbow: "leftElbow",
    .rightElbow: "rightElbow",
    .leftWrist: "leftWrist",
    .rightWrist: "rightWrist",
    .leftHip: "leftHip",
    .rightHip: "rightHip",
    .leftKnee: "leftKnee",
    .rightKnee: "rightKnee",
    .leftAnkle: "leftAnkle",
    .rightAnkle: "rightAnkle",
  ]

  private func detectHumanPose(at path: String) -> NativePoseResult {
    guard fileSize(at: path) > 0 else {
      return emptyPose()
    }
    let request = VNDetectHumanBodyPoseRequest()
    let handler: VNImageRequestHandler
    let width: Double
    let height: Double
    if let image = UIImage(contentsOfFile: path), let cgImage = image.cgImage {
      handler = VNImageRequestHandler(
        cgImage: cgImage,
        orientation: cgImageOrientation(from: image.imageOrientation),
        options: [:]
      )
      let size = orientedPixelSize(of: cgImage, orientation: image.imageOrientation)
      width = size.width
      height = size.height
    } else {
      handler = VNImageRequestHandler(url: URL(fileURLWithPath: path), options: [:])
      width = 1
      height = 1
    }
    do {
      try handler.perform([request])
    } catch {
      return emptyPose()
    }
    guard let observation = request.results?.first else {
      return emptyPose()
    }
    var landmarks: [NativePoseLandmark] = []
    for (joint, name) in Self.visionJoints {
      guard let point = try? observation.recognizedPoint(joint),
        point.confidence > 0.05,
        point.location.x.isFinite,
        point.location.y.isFinite
      else {
        continue
      }
      landmarks.append(
        NativePoseLandmark(
          joint: name,
          x: min(max(point.location.x, 0), 1),
          y: min(max(1.0 - point.location.y, 0), 1),
          visibility: Double(point.confidence)
        )
      )
    }
    if landmarks.isEmpty {
      return emptyPose()
    }
    return NativePoseResult(
      found: true,
      imageWidth: width,
      imageHeight: height,
      landmarks: landmarks
    )
  }

  private func emptyPose() -> NativePoseResult {
    return NativePoseResult(found: false, imageWidth: 1, imageHeight: 1, landmarks: [])
  }

  private func orientedPixelSize(
    of image: CGImage,
    orientation: UIImage.Orientation
  ) -> (width: Double, height: Double) {
    switch orientation {
    case .left, .leftMirrored, .right, .rightMirrored:
      return (Double(image.height), Double(image.width))
    default:
      return (Double(image.width), Double(image.height))
    }
  }

  private func cgImageOrientation(from orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
    switch orientation {
    case .up: return .up
    case .down: return .down
    case .left: return .left
    case .right: return .right
    case .upMirrored: return .upMirrored
    case .downMirrored: return .downMirrored
    case .leftMirrored: return .leftMirrored
    case .rightMirrored: return .rightMirrored
    @unknown default: return .up
    }
  }

  // MARK: - タスク管理

  private func registerTask(_ taskId: String) -> CancellationToken {
    taskLock.lock()
    defer { taskLock.unlock() }
    if let existing = cancellationTokens[taskId] {
      return existing
    }
    let token = CancellationToken()
    cancellationTokens[taskId] = token
    return token
  }

  private func unregisterTask(_ taskId: String) {
    taskLock.lock()
    cancellationTokens.removeValue(forKey: taskId)
    activeGenerators.removeValue(forKey: taskId)
    taskLock.unlock()
  }

  private func setActiveGenerator(_ generator: AVAssetImageGenerator?, for taskId: String) {
    taskLock.lock()
    activeGenerators[taskId] = generator
    taskLock.unlock()
  }

  private func sendProgress(taskId: String, completed: Int, total: Int) {
    guard let progressApi else { return }
    // Flutter への呼び出しはプラットフォーム(メイン)スレッドから行う必要がある。
    DispatchQueue.main.async {
      progressApi.onProgress(
        taskId: taskId,
        completedFrames: Int64(completed),
        totalFrames: Int64(total)
      ) { _ in }
    }
  }

  // MARK: - ヘルパー

  private func fileSize(at path: String) -> Int64 {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      !isDirectory.boolValue,
      let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    else {
      return 0
    }
    return (attributes[.size] as? NSNumber)?.int64Value ?? 0
  }

  /// preferredTransform から回転角(0/90/180/270)を求める。
  private func rotationDegrees(from transform: CGAffineTransform) -> Int64 {
    let angle = atan2(transform.b, transform.a)
    var degrees = Int64((angle * 180.0 / .pi).rounded())
    degrees = ((degrees % 360) + 360) % 360
    return degrees
  }

  /// 長辺が maxLongEdge を超える場合のみ縮小する(拡大はしない)。Android と同じ挙動。
  private func scaleDown(_ image: CGImage, maxLongEdge: Int) -> CGImage {
    let width = image.width
    let height = image.height
    let longEdge = max(width, height)
    if longEdge <= maxLongEdge {
      return image
    }
    let scale = Double(maxLongEdge) / Double(longEdge)
    let newWidth = max(1, Int((Double(width) * scale).rounded()))
    let newHeight = max(1, Int((Double(height) * scale).rounded()))
    guard
      let context = CGContext(
        data: nil,
        width: newWidth,
        height: newHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      return image
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
    return context.makeImage() ?? image
  }

  /// 一時ファイルへ書いてから置き換える。中断時に壊れた JPEG が残らないようにする。
  private func writeJpegAtomically(
    _ image: CGImage,
    to output: URL,
    maxLongEdgePx: Int,
    jpegQuality: Int
  ) throws {
    let scaled = scaleDown(image, maxLongEdge: maxLongEdgePx)
    let quality = CGFloat(min(max(jpegQuality, 1), 100)) / 100.0
    guard let data = UIImage(cgImage: scaled).jpegData(compressionQuality: quality) else {
      throw makeError("JPEG compression failed.")
    }
    let fileManager = FileManager.default
    let temporary = URL(fileURLWithPath: output.path + ".tmp")
    try? fileManager.removeItem(at: temporary)
    try data.write(to: temporary, options: .atomic)
    if fileManager.fileExists(atPath: output.path) {
      try fileManager.removeItem(at: output)
    }
    try fileManager.moveItem(at: temporary, to: output)
  }

  private func invalidInfo(_ reason: String) -> VideoInfo {
    return VideoInfo(
      isValid: false,
      durationMs: 0,
      width: 0,
      height: 0,
      rotationDegrees: nil,
      errorReason: reason
    )
  }

  private func cancelledResult(
    completedFrames: Int,
    durationMs: Int64,
    sourceFps: Double
  ) -> ExtractResult {
    return ExtractResult(
      isComplete: false,
      frameCount: Int64(completedFrames),
      sourceDurationMs: durationMs,
      sourceFps: sourceFps,
      errorReason: "cancelled"
    )
  }

  private func extractionError(
    _ reason: String,
    durationMs: Int64 = 0,
    sourceFps: Double = 0.0,
    completedFrames: Int = 0
  ) -> ExtractResult {
    return ExtractResult(
      isComplete: false,
      frameCount: Int64(completedFrames),
      sourceDurationMs: durationMs,
      sourceFps: sourceFps,
      errorReason: reason
    )
  }

  private func makeError(_ message: String) -> NSError {
    return NSError(
      domain: "FrameExtractor",
      code: -1,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }
}

/// 展開処理の中断理由を errorReason としてそのまま Dart に返すためのエラー。
private struct ExtractionFailure: Error {
  let reason: String

  init(_ reason: String) {
    self.reason = reason
  }
}

/// スレッド間で共有するキャンセルフラグ。
private final class CancellationToken {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
}
