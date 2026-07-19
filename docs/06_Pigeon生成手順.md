# Pigeon生成手順

フェーズ3aのFlutter・Android・iOS共通インターフェースは
`pigeons/frame_extractor.dart`を正として、次のコマンドで再生成する。

```powershell
C:\Users\flyin\develop\flutter\bin\cache\dart-sdk\bin\dart.exe run pigeon --input pigeons/frame_extractor.dart
```

生成先:

- Dart: `lib/native/frame_extractor.g.dart`
- Kotlin: `android/app/src/main/kotlin/com/sukashiform/app/FrameExtractorApi.g.kt`
- Swift: `ios/Runner/FrameExtractorApi.g.swift`

生成物は直接編集しない。インターフェースを変更する場合は
`pigeons/frame_extractor.dart`を修正して上記コマンドを再実行する。

## フェーズ3bでの拡張

2026-07-18に`ExtractRequest`、`ExtractResult`、`extractFrames`、
`cancelExtraction`、`FrameExtractionProgressApi`を追加し、上記と同じコマンドで
Dart・Kotlin・Swiftを再生成した。既存の`probe`と`generateThumbnail`の
シグネチャは変更していない。

## フェーズ3.5での拡張

2026-07-18に`ExtractRequest`へ`rangeStartMs`と`rangeEndMs`を追加し、
Dart・Kotlin・Swiftを再生成した。既存APIのシグネチャは変更していない。

## フェーズ6での拡張

2026-07-19にAndroidのMediaStore保存、音量キー捕捉の有効・無効、
音量キー通知を追加した。フレーム抽出系の既存シグネチャは変更していない。
