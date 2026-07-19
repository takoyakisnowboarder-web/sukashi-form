import Flutter

/// Android先行フェーズのため、iOS側は共通Pigeonインターフェースの空実装のみ。
/// 将来AVAssetImageGenerator実装へ差し替える。
final class FrameExtractorApiStub: FrameExtractorApi {
  func probe(
    absoluteVideoPath: String,
    completion: @escaping (Result<VideoInfo, Error>) -> Void
  ) {
    completion(.failure(PigeonError(
      code: "unimplemented",
      message: "Video probing is not implemented on iOS.",
      details: nil
    )))
  }

  func generateThumbnail(
    absoluteVideoPath: String,
    absoluteOutputPath: String,
    maxLongEdgePx: Int64,
    completion: @escaping (Result<String, Error>) -> Void
  ) {
    completion(.failure(PigeonError(
      code: "unimplemented",
      message: "Thumbnail generation is not implemented on iOS.",
      details: nil
    )))
  }

  func extractFrames(
    taskId: String,
    request: ExtractRequest,
    completion: @escaping (Result<ExtractResult, Error>) -> Void
  ) {
    completion(.failure(PigeonError(
      code: "unimplemented",
      message: "Frame extraction is not implemented on iOS.",
      details: nil
    )))
  }

  func cancelExtraction(taskId: String) throws {
    // Android先行フェーズの空スタブ。実行中処理は存在しない。
  }

  func isGallerySaveSupported() throws -> Bool {
    // フェーズ6もAndroid先行。iOSでは設定自体を表示しない。
    false
  }

  func saveVideoToGallery(
    absoluteVideoPath: String,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    completion(.failure(PigeonError(
      code: "unimplemented",
      message: "Gallery saving is not implemented on iOS.",
      details: nil
    )))
  }

  func setVolumeKeyCaptureEnabled(enabled: Bool) throws {
    // Android先行フェーズの空スタブ。
  }
}
