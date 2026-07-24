import AVFoundation
import Flutter
import UIKit

/// iOS 版のフレーム展開ネイティブ実装。
///
/// Android の `FrameExtractorApiImpl.kt`(MediaMetadataRetriever ベース)を
/// AVFoundation へ移植したもの。段階的に実装している:
///   - フェーズ1(実装済み): probe(尺・破損検出)/ generateThumbnail(サムネイル)
///   - フェーズ2(未実装): extractFrames(範囲指定でのフレーム一括展開)
///   - フェーズ3(未実装): saveVideoToGallery / 音量キー録画
///
/// probe / generateThumbnail / extractFrames は Pigeon 側でバックグラウンドの
/// TaskQueue にディスパッチされて呼ばれるため、ここで同期的にブロッキング処理をしてよい。
final class FrameExtractorApiImpl: FrameExtractorApi {
  // MARK: - probe

  func probe(
    absoluteVideoPath: String,
    completion: @escaping (Result<VideoInfo, Error>) -> Void
  ) {
    completion(.success(probeVideo(path: absoluteVideoPath)))
  }

  private func probeVideo(path: String) -> VideoInfo {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      return invalidInfo("file_not_found")
    }
    let attributes = try? fileManager.attributesOfItem(atPath: path)
    let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    if fileSize == 0 {
      return invalidInfo("empty_file")
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
    let width = Int64(abs(naturalSize.width).rounded())
    let height = Int64(abs(naturalSize.height).rounded())
    return VideoInfo(
      isValid: true,
      durationMs: durationMs,
      width: width,
      height: height,
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
        let clamped = Int(min(maxLongEdgePx, Int64(Int.max)))
        return try createThumbnail(
          videoPath: absoluteVideoPath,
          outputPath: absoluteOutputPath,
          maxLongEdgePx: clamped
        )
      }
    )
  }

  private func createThumbnail(
    videoPath: String,
    outputPath: String,
    maxLongEdgePx: Int
  ) throws -> String {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: videoPath, isDirectory: &isDirectory),
      !isDirectory.boolValue,
      let attributes = try? fileManager.attributesOfItem(atPath: videoPath),
      ((attributes[.size] as? NSNumber)?.int64Value ?? 0) > 0
    else {
      throw makeError("Video file is missing or empty.")
    }

    let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
    let generator = AVAssetImageGenerator(asset: asset)
    // MediaMetadataRetriever と同様に回転を適用し、縦動画が横に倒れないようにする。
    generator.appliesPreferredTrackTransform = true
    // 先頭(0秒)以降の最初に取れるフレームを許容(厳密一致で失敗しないように)。
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .positiveInfinity

    let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
    let scaled = scaleDown(cgImage, maxLongEdge: maxLongEdgePx)
    guard let jpegData = UIImage(cgImage: scaled).jpegData(compressionQuality: 0.85) else {
      throw makeError("JPEG compression failed.")
    }

    let outputURL = URL(fileURLWithPath: outputPath)
    try fileManager.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let temporaryURL = URL(fileURLWithPath: outputPath + ".tmp")
    try? fileManager.removeItem(at: temporaryURL)
    try jpegData.write(to: temporaryURL, options: .atomic)
    if fileManager.fileExists(atPath: outputPath) {
      try fileManager.removeItem(at: outputURL)
    }
    try fileManager.moveItem(at: temporaryURL, to: outputURL)
    return outputPath
  }

  // MARK: - フェーズ2/3(未実装)

  func extractFrames(
    taskId: String,
    request: ExtractRequest,
    completion: @escaping (Result<ExtractResult, Error>) -> Void
  ) {
    // フェーズ2で AVAssetImageGenerator によるバッチ展開を実装する。
    completion(
      .success(
        ExtractResult(
          isComplete: false,
          frameCount: 0,
          sourceDurationMs: 0,
          sourceFps: 0.0,
          errorReason: "unimplemented_ios"
        )
      )
    )
  }

  func cancelExtraction(taskId: String) throws {
    // フェーズ2の extractFrames 実装と合わせてキャンセルを実装する。
  }

  func isGallerySaveSupported() throws -> Bool {
    // ギャラリー自動保存はフェーズ3。現状は非対応として設定自体を出さない。
    return false
  }

  func saveVideoToGallery(
    absoluteVideoPath: String,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    completion(.failure(makeError("Gallery saving is not implemented on iOS yet.")))
  }

  func setVolumeKeyCaptureEnabled(enabled: Bool) throws {
    // 音量キー録画はフェーズ3。iOS には dispatchKeyEvent 相当が無いため要調査。
  }

  // MARK: - ヘルパー

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
    let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil,
        width: newWidth,
        height: newHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      return image
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
    return context.makeImage() ?? image
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

  private func makeError(_ message: String) -> NSError {
    return NSError(
      domain: "FrameExtractor",
      code: -1,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }
}
