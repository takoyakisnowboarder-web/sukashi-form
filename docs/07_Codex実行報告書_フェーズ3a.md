# Codex実行報告書 — スカシフォーム フェーズ3a

実施日: 2026-07-17  
対象フォルダ: `C:\Users\flyin\develop\sukashi_form`

## 変更ファイルと差分の要点

- `pubspec.yaml` / `pubspec.lock`: 指示書で許可された`pigeon ^27.2.0`だけをdev dependencyへ追加。
- `pigeons/frame_extractor.dart`: `VideoInfo`、`probe`、`generateThumbnail`の共通Pigeonインターフェースを定義。両メソッドを直列バックグラウンドTaskQueueへ指定。
- `lib/native/frame_extractor.g.dart`: Pigeonが生成したDartクライアント。
- `android/app/src/main/kotlin/com/sukashiform/app/FrameExtractorApi.g.kt`: Pigeonが生成したKotlinインターフェースとバックグラウンドTaskQueue配線。
- `ios/Runner/FrameExtractorApi.g.swift`: Pigeonが生成した将来のiOS実装用共通インターフェース。
- `docs/06_Pigeon生成手順.md`: Pigeonの再生成コマンド、生成元、3言語の生成先を記録。
- `android/app/src/main/kotlin/com/sukashiform/app/FrameExtractorApiImpl.kt`: `MediaMetadataRetriever`によるprobeとサムネイル生成を実装。全経路で`release()`し、0バイト・不存在・尺不明・読取例外を無効結果へ変換。
- `android/app/src/main/kotlin/com/sukashiform/app/MainActivity.kt`: FlutterEngineへ`FrameExtractorApiImpl`を登録。
- `ios/Runner/FrameExtractorApiStub.swift`: iOSは共通インターフェースを実装する未実装エラーの空スタブだけを追加。
- `lib/models/clip.dart`: 後方互換のある`isBroken`と`validationError`を追加し、メタデータ更新メソッドを追加。
- `lib/data/video_metadata_service.dart`: Pigeonをラップし、絶対/相対パス変換、probe、`thumbnails/<clipId>.jpg`生成、永続化、同一IDの多重処理抑止、書き込み直列化を実装。
- `lib/providers/clip_providers.dart`: 新規撮影・取り込み後の共通メタデータ処理と、一覧表示後の非同期backfill・起動時再検証を追加。破損判定時は既存選択からも除外。
- `lib/screens/library_screen.dart`: 実サムネイル、プレースホルダ、破損オーバーレイを表示。破損クリップの比較選択を拒否して警告。画像パス解決をFutureProviderでキャッシュ。
- `test/video_metadata_service_test.dart`: 成功時の尺・相対パス永続化、破損時の非削除、再処理抑止、多重起動抑止、完成済みクリップの再検証を追加。
- `test/clip_repository_test.dart`: 新フィールドがない旧`clips.json`の後方互換テストを追加。
- `test/library_screen_test.dart`: サムネイルあり/なし/破損の表示と、破損クリップの比較選択禁止を追加。

## 完了の定義のチェック結果

- [一部達成] Pigeon生成物と生成コマンドは保存済み。対象フォルダがGitリポジトリではないため「コミット」だけは実行不可。
- [達成] Pixel 8で撮影すると、ライブラリに実動画フレームのサムネイルが表示された。
- [達成] Pixel 8でPhoto Pickerから動画を取り込むと、サムネイルが表示され、尺が`—`ではなく`4.9秒`になった。
- [達成] アプリ再起動後も、撮影・取り込み両クリップのサムネイルと`4.9秒`が保持された。
- [達成] JPEGは`app_flutter/thumbnails/<clipId>.jpg`へ保存され、`clips.json`には`thumbnails/<clipId>.jpg`の相対パスが保存された。
- [達成] 実機で0バイト化した動画が「この動画は読み込めません」と表示された。
- [達成] 破損クリップは`clips.json`に残り、自動削除されなかった。長押し削除は利用できた。
- [達成] 破損クリップをタップしても比較選択は`0/2`のままで、警告が表示された。
- [達成] `ClipListNotifier.build`は保存済み一覧を先に返し、backfillと再検証を次のイベントキューから実行する。UI層は処理完了を待たずプレースホルダを表示する。
- [達成] クリップを既存UIから削除すると、対応する動画とサムネイルも消え、両ディレクトリが空になった。
- [達成] 新フィールドのない旧`clips.json`を読み、`isBroken == false`として復元するテストが成功した。
- [達成] `flutter analyze`は`No issues found!`。
- [達成] 既存18件を含む全27テストが成功した。

## 実機での動作確認

- 機種: Google Pixel 8
- OS: Android 16
- APIレベル: 36
- 接続: USB。`adb devices`で認識を確認。
- ビルド・導入: `flutter build apk --debug`成功、`adb install -r build\app\outputs\flutter-apk\app-debug.apk`成功。
- 撮影試験:
  - 5秒設定で撮影し、録画中に「残り1秒」を確認。
  - 保存動画は約7,706,970バイト、ネイティブprobe結果は4,859ms。
  - サムネイルは約25,596バイトのJPEGとして生成され、ライブラリへ即時反映された。
- 取り込み試験:
  - 撮影した検証動画を端末Moviesへ複製し、システムPhoto Pickerから選択。
  - 新しいUUIDの動画とサムネイルがアプリ領域へ生成され、`durationMs: 4859`で保存された。
  - 画面では撮影・取り込みの両方が`4.9秒`表示となった。
- 永続化試験:
  - APK上書きとアプリ強制停止・再起動後も、2件のサムネイル、尺、相対パスが保持された。
- 0バイト破損試験:
  - 検証専用取り込み動画へ、指示書と同じ`run-as`＋`cat /dev/null`方式を実行し、`ls -l`でサイズ0を確認。
  - 再起動後、JSONは`durationMs: 0`、`isBroken: true`、`validationError: "empty_file"`へ更新された。
  - カードに「この動画は読み込めません」が表示され、もう1本の正常クリップは残った。
  - 破損カードをタップしても選択数は`0/2`のままで、「この動画は比較に使用できません。」が表示された。
  - 長押しメニューの「削除」からユーザー操作で削除できた。
- 視覚確認:
  - 実機スクリーンショットで正常サムネイルと破損オーバーレイを確認。
  - 初回確認で警告文の20pxオーバーフローを発見し、`FittedBox`で修正。再ビルド・再導入後はオーバーフローなし。
- 最終検証:
  - `flutter analyze`成功。
  - `flutter test --reporter expanded`は全27件成功。
  - Androidネイティブコードを含むデバッグAPKビルド成功。
- 後片付け:
  - フェーズ3aで作成した撮影・取り込み・0バイト破損の検証クリップだけをUIから削除。
  - 端末Moviesの検証動画、端末上の検証XML、ローカルbuild配下の検証動画・スクリーンショットを削除。
  - 最終的に`clips.json`は`[]`、`videos/`と`thumbnails/`は空。

## 実行できなかった項目とその理由

- Pigeon生成物のGitコミット: 対象フォルダに`.git`がなくGitリポジトリではないため実行できなかった。生成物自体と再生成手順は対象フォルダ内へ保存済み。
- iOSビルド検証: 指示書で不要・着手禁止とされているため実行していない。Swift生成物と未実装スタブだけを用意した。

## 設計上の判断

- メインスレッド回避は追加のコルーチン依存を入れず、Pigeonの`TaskQueueType.serialBackgroundThread`を各Host APIへ指定して実現した。
- サムネイルは動画先頭の同期フレームを取り、長辺512px以下、JPEG品質85でアトミックに確定する。
- `probe`はKotlin側で常に`VideoInfo`を成功応答として返し、ファイル異常やネイティブ例外は短い`errorReason`へ変換する。
- 完成済みクリップが後から0バイト化するケースも検出するため、起動時は一覧を先に表示した後、サムネイルを再生成せず軽量probeだけ再実行する。
- 破損後も既存サムネイルは残し、暗いオーバーレイを重ねた。ユーザーがどの動画だったか判断してから削除できるため。
- 同一IDの処理は`_inFlight`で共有し、異なるIDのJSON書き込みも直列化した。backfill同士による`clips.json`の上書き競合を避けるため。
- Pigeon APIは`FrameExtractorClient`で抽象化し、テストではフェイクへ差し替える。UIはPigeonを直接参照しない。
- iOS雛形自体が存在しなかったため、FlutterのiOSプロジェクト生成やAppDelegate変更はせず、生成Swiftと未実装スタブだけを`ios/Runner`へ置いた。

## 逸脱・迷った点

- `extractFrames`と`deleteCache`はPigeon定義にも追加していない。指示書では「先に定義してよい」と任意だったため、フェーズ3bの詳細確定前にAPIを固定しない判断をした。
- 0バイト化の最初のadbコマンドはリダイレクト記号が端末シェルへ渡らず、ファイルサイズが変化しなかった。サイズが7,706,970バイトのままであることを確認し、正しい端末側クォートへ直して0バイトを確認してから試験した。誤操作によるデータ破損はなかった。
- Widgetテストで実画像ファイルのデコード待ちが終了しない問題が発生した。実アプリは`Image.file`のまま、パス解決と画像Widget構築をProvider境界で差し替え可能にして安定した表示テストへ変更した。
- 実機初回確認で破損警告のオーバーフローを発見した。報告だけで済ませず修正し、全テスト・APKビルド・実機スクリーンショットをやり直した。
- Gitコミットのみ環境上未達成。その他に未解消の逸脱はない。
