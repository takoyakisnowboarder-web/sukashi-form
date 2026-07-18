# Codex実行報告書 — フェーズ3b

実施日: 2026-07-18

## 変更ファイルと差分の要点

- `pigeons/frame_extractor.dart`
  - `ExtractRequest` / `ExtractResult`、非同期 `extractFrames`、即時 `cancelExtraction`、Flutter向け進捗APIを追加した。既存の `probe` / `generateThumbnail` シグネチャは変更していない。
- `lib/native/frame_extractor.g.dart`
- `android/app/src/main/kotlin/com/sukashiform/app/FrameExtractorApi.g.kt`
- `ios/Runner/FrameExtractorApi.g.swift`
  - Pigeon 27.2.0でDart/Kotlin/Swift生成物を再生成した。
- `android/app/src/main/kotlin/com/sukashiform/app/FrameExtractorApiImpl.kt`
  - `MediaMetadataRetriever#getFramesAtIndex` によるバックグラウンド展開、8枚バッチ、JPEG連番・一時ファイルからのrename、進捗通知、キャンセル、10秒/600枚上限、`finally`での `release()` とBitmapの `recycle()` を実装した。
  - 実機確認で手動回転との二重回転を発見した。AOSPの `MediaMetadataRetriever` は返却Bitmap生成時に動画メタデータの回転を適用するため、二重回転を除去し、縦長フレームになることを再確認した。
- `android/app/src/main/kotlin/com/sukashiform/app/MainActivity.kt`
  - ネイティブ実装へ進捗Flutter APIを注入した。
- `ios/Runner/FrameExtractorApiStub.swift`
  - Pigeon生成後もiOSがコンパイル可能なよう、フェーズ対象外の未実装スタブを追加した。
- `lib/data/frame_cache_service.dart`
  - `frames/<clipId>/` と `manifest.json` を管理するキャッシュ層、Pigeonラッパー、タスク別進捗、キャンセル、部分キャッシュ掃除、完全性検査を実装した。永続化データに絶対パスは保存していない。
- `lib/data/clip_repository.dart`
  - クリップ削除時に対応するフレームキャッシュも再帰削除するよう変更した。
- `lib/providers/frame_extraction_providers.dart`
  - フレーム展開クライアント、キャッシュ、サービスのRiverpod Providerを追加した。
- `lib/screens/frame_extraction_debug_screen.dart`
  - 進捗、キャンセル、上限打ち切り、キャッシュ判定、先頭・中間・末尾フレームを表示する開発用画面を追加した。
- `lib/screens/library_screen.dart`
  - `kDebugMode` の長押しメニューに「フレーム展開（開発用）」を追加した。
- `lib/router/app_router.dart`
  - `kDebugMode` のときだけ開発用フレーム展開ルートを登録した。
- `lib/main.dart`
  - 画像キャッシュを24枚/64MiBに制限し、確認画面で大量画像を保持しないようにした。
- `test/frame_cache_service_test.dart`
  - キャッシュ再利用、破損拒否、`isComplete=false`、タスク別進捗、キャンセル競合と部分キャッシュ削除の5件を追加した。
- `test/clip_repository_test.dart`
  - クリップ削除時のフレームキャッシュ削除確認を既存テストへ追加した。
- `docs/06_Pigeon生成手順.md`
  - フェーズ3bのPigeon再生成内容を追記した。

## 完了の定義のチェック結果

- 達成: Pigeonに `extractFrames` / キャンセル / 進捗を追加し、3プラットフォームの生成物を再生成した。
- 一部未達成: 生成物のGitコミット。プロジェクトに `.git` がなく、コミット操作は実行できなかった。生成・ビルド確認自体は達成した。
- 達成: Pixel 8で短尺動画を146枚に展開し、進捗とフレーム画像を表示した。
- 達成: `frames/<clipId>/frame_000000.jpg` 形式の連番JPEGと `manifest.json` を保存した。
- 達成: 縦持ち撮影フレームが縦長・正しい向きで表示された。二重回転修正後に再確認した。
- 達成: 同じ短尺クリップを再度開くとネイティブ再展開せず、251msでキャッシュ表示された。
- 達成: 29.561秒動画をOOMなしで298枚に展開し、10秒相当で `isComplete=false` になった。
- 達成: クリップ削除後、動画・サムネイル・`frames/<clipId>/` の3パスがすべて存在しないことを実機確認した。
- 達成: 0バイト化した破損クリップは「破損した動画は展開できません。」として拒否され、クラッシュしなかった。
- 達成: 長尺展開開始後に画面を閉じてもライブラリへ安全に戻り、部分キャッシュが残らなかった。
- 達成: `MediaMetadataRetriever.release()` を `finally` で実行している。
- 達成: 開発用導線とルートを `kDebugMode` で限定した。
- 達成: `flutter analyze` は警告・エラー0件。
- 達成: 既存27件と追加5件の全32テストが成功した。
- 達成: `dumpsys meminfo` で長尺展開中のメモリを実測した。

## 実機での動作確認

実機は Pixel 8、Android 16、API 36（端末ID `3C041FDJH0038Z`）。`app-debug.apk` を `adb install -r` で上書きインストールした。

1. 数秒クリップ
   - アプリで縦持ち5秒設定として撮影し、実ファイルは4,852ms / 30.09fpsだった。
   - 146枚を16,471msで展開した。進捗バーと `N / 146 フレーム` が更新され、先頭・中間・末尾画像が表示された。
2. 縦持ち回転
   - 初回実装では `MediaMetadataRetriever` の自動回転後にさらに90度回す二重回転を実機で発見した。
   - 手動回転を除去して再ビルドし、縦長フレームが横倒しにならないことを画面で確認した。
   - 証跡: `C:\Users\flyin\OneDrive\デスクトップ\sukashi_phase3b_rotation_fixed.png`
3. キャッシュ再利用
   - 同じ短尺クリップを再度開き、「キャッシュから読み込みました」、所要時間251msを確認した。
4. 20〜30秒の長尺
   - アプリで30秒設定として縦持ち撮影し、実ファイルは29,561ms / 29.80fpsだった。
   - 先頭10秒相当の298枚を7,405ms（再測定7,704ms）で展開し、`isComplete=false` と「10秒／600枚の上限で打ち切りました」を確認した。OOM、ANR、クラッシュはいずれもなかった。
5. クリップ削除
   - 展開済み短尺クリップをUIから削除した。クリップ一覧から消え、動画、サムネイル、`frames/<clipId>/` はすべて `No such file or directory` になった。
6. 破損クリップ
   - 長尺テスト動画をアプリ領域内でバックアップしてから一時的に0バイト化し、アプリ再起動で破損表示になることを確認した。
   - 開発用展開画面では「破損した動画は展開できません。」と表示され、ネイティブ展開やクラッシュは発生しなかった。確認後は動画とクリップメタデータを正常値へ復元した。
7. 画面クローズ/キャンセル
   - 長尺展開開始約1秒後に戻る操作を実行した。ライブラリは動作を継続し、対象の部分キャッシュディレクトリは残らなかった。

進捗表示の実機証跡は `C:\Users\flyin\OneDrive\デスクトップ\sukashi_phase3b_progress.png`（`16 / 298 フレーム`）。

`adb shell dumpsys meminfo com.sukashiform.app` を長尺展開中に8回連続取得した。最終実装の観測ピークは次の通り。

- TOTAL PSS: 413,737 KB
- TOTAL RSS: 531,240 KB
- TOTAL SWAP PSS: 44 KB
- 測定中も展開は完走し、OOMなし。

自動検証結果:

- `dart format lib pigeons test`: 28ファイル、変更なし
- `flutter analyze`: No issues found
- `flutter test`: 32件すべて成功
- `flutter build apk --debug`: 成功（`build/app/outputs/flutter-apk/app-debug.apk`）

## 実行できなかった項目とその理由

- Gitコミット: `C:\Users\flyin\develop\sukashi_form` に `.git` ディレクトリが存在しないため実行できなかった。
- iOS実機でのフレーム展開: フェーズ3bの指示対象がAndroid実機であり、iOS側は未実装スタブまでとした。
- 上記以外の指示書4章の実機シナリオ、メモリ計測、静的解析、全テスト、APKビルドは実行済み。

## 設計上の判断

- サンプリングは `min(動画全フレーム×対象10秒/動画長, maxFrames)` 枚とし、対象区間の元フレームindexを先頭から末尾まで均等配置した。29.80fpsの実機動画では10秒相当が298枚となった。
- 連続indexは `getFramesAtIndex` で8枚ずつ取得し、間引きが必要な場合は `getFrameAtIndex` を1枚ずつ呼ぶ。各JPEG書き出し後にBitmapを `recycle()` し、同時生存数を抑えた。
- Android 16のAOSP実装では `MediaMetadataRetriever` がBitmap生成時に `METADATA_KEY_VIDEO_ROTATION` を適用するため、追加のMatrix回転は行わない。実機で縦長画像を確認した。
- 完全キャッシュは、manifestのバージョン・設定値・枚数と、期待する全連番JPEGの存在および非0バイトを確認して判定する。`isComplete=false` は「有効な上限打ち切り結果」として再利用する。
- manifestは相対的なキャッシュ情報だけを保持し、絶対パスは実行時に解決する。manifest自体も一時ファイルからrenameして確定する。
- キャンセル要求は展開用バックグラウンドTaskQueueに並べず即時チャネルで受け、`AtomicBoolean` をバッチ間・フレーム間で確認する。
