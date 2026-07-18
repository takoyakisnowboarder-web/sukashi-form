# Codex実行報告書 — フェーズ3.5

実施日: 2026-07-18

## 変更ファイルと差分の要点

- `pigeons/frame_extractor.dart`
- `lib/native/frame_extractor.g.dart`
- `android/app/src/main/kotlin/com/sukashiform/app/FrameExtractorApi.g.kt`
- `ios/Runner/FrameExtractorApi.g.swift`
  - `ExtractRequest` に任意の `rangeStartMs` / `rangeEndMs` を追加し、Pigeon 27.2.0でDart/Kotlin/Swift生成物を再生成した。
- `android/app/src/main/kotlin/com/sukashiform/app/FrameExtractorApiImpl.kt`
  - 指定範囲を元動画フレームindexへ変換し、その区間だけを展開するようにした。
  - 通常展開は従来どおり10秒/600枚上限を維持し、プレビュー設定（24枚、長辺240px）は動画全体を均等サンプリングする。
  - 実機検証で、全体プレビューの `isComplete` がfalseになる問題を発見し、全区間の間引き完了はtrueになるよう修正した。
- `lib/models/clip.dart`
  - `trimStartMs` / `trimEndMs`、範囲時間、更新API、JSON後方互換、0以上・開始より終了が後・動画長以内・10秒以内の検証を追加した。
- `lib/data/frame_cache_service.dart`
  - manifestをversion 2へ更新し、範囲をキャッシュキーと保存情報へ追加した。
  - `frames` と `frames_preview` を同じキャッシュ実装で分離管理できるようにした。
- `lib/data/clip_repository.dart`
  - 保存時の範囲検証、範囲変更時の比較キャッシュ削除、クリップ削除時の比較/プレビュー両キャッシュ削除を追加した。
- `lib/providers/clip_providers.dart`
  - 範囲保存/リセットと、保存直後の比較キャッシュ無効化を追加した。
- `lib/providers/frame_extraction_providers.dart`
  - 動画全体を最大24枚・長辺240px・JPEG品質75で作る独立プレビューサービスを追加した。
- `lib/screens/comparison_range_screen.dart`
  - 全体プレビュー帯、2ハンドルRangeSlider、操作中ハンドル付近の拡大プレビュー、選択時間、10秒超過時の保存無効化、保存、リセット、進捗、エラー、画面破棄時キャンセルを実装した。
  - クリップ一覧の非同期ロード完了を購読し、ロード前に画面を開いても再描画されるようにした。
- `lib/screens/library_screen.dart`
  - 正常クリップの長押しメニューへ「比較範囲を選択」を追加し、設定済みカードへ「選択秒数 / 全体秒数」を表示した。破損クリップには導線を出さない。
- `lib/router/app_router.dart`
  - 比較範囲選択画面のルートを追加した。
- `test/clip_comparison_range_test.dart`
  - 旧JSON、正常範囲、リセット、負値、逆転、10秒超、動画長超を検証した。
- `test/comparison_range_screen_test.dart`
  - 10秒超過時にエラー表示となり保存できないことを検証した。
- `test/frame_cache_service_test.dart`
  - 範囲一致時のキャッシュ再利用、範囲変更時の再展開、ネイティブ要求への範囲伝播、プレビュー設定と保存先分離を検証した。
- `test/clip_repository_test.dart`
  - クリップ削除で比較キャッシュとプレビューキャッシュの両方が消えることを検証した。
- `test/library_screen_test.dart`
  - 破損クリップに範囲導線がないことと、範囲設定済みカード表示を検証した。
- `docs/06_Pigeon生成手順.md`
  - フェーズ3.5のPigeon再生成内容を追記した。
- `docs/11_Codex実行報告書_フェーズ3.5.md`
  - 本報告書を追加した。

## 完了の定義のチェック結果

- 達成: `ExtractRequest` に範囲を追加し、Dart/Kotlin/Swift生成物を再生成した。
- 達成: Pixel 8で30秒クリップの任意範囲を2ハンドルで選び、保存できた。
- 達成: プレビュー帯は動画全体を24枚で表し、manifestは `rangeStartMs=0` / `rangeEndMs=29873` / `frameCount=24` / `isComplete=true` となった。
- 達成: 10秒を超える27.9秒範囲では警告が表示され、保存ボタンが無効になった。
- 達成: 範囲変更直後に旧比較キャッシュが消え、新範囲で再展開された。
- 達成: 範囲不変時はキャッシュから97msで読み込まれた。
- 達成: リセットで範囲フィールドがnullになり、カードの範囲表示が消え、従来の先頭10秒展開へ戻った。
- 達成: 範囲設定済みクリップの動画、サムネイル、比較キャッシュ、プレビューキャッシュが削除された。
- 達成: 範囲フィールドのない旧JSONを後方互換で読み込める。
- 達成: 破損クリップの長押しメニューに「比較範囲を選択」が表示されない。
- 達成: 保存、戻るキー、プレビュー生成中の戻るの全経路でクラッシュしなかった。
- 達成: `flutter analyze` は警告・エラー0件、全43テストが成功、デバッグAPKのビルドが成功した。
- 達成: フェーズ3.5の変更を1コミットにまとめた（コミットIDは本報告書作成後の最終コミット結果を参照）。

## 実機での動作確認

実機は Pixel 8、Android 16、API 36（端末ID `3C041FDJH0038Z`）。`build/app/outputs/flutter-apk/app-debug.apk` を `adb install -r` で上書きインストールした。

1. 30秒撮影と全体プレビュー
   - アプリで30秒設定として撮影し、実ファイルは29,873ms / 29.86fpsだった。
   - 「比較範囲を選択」を開き、0〜29,873msを24枚、長辺240pxで表すプレビュー帯が表示された。
   - 初回実機確認でmanifestの `isComplete=false` を発見したため判定を修正し、キャッシュを再生成して `isComplete=true` を確認した。
2. 後半5秒の保存と選択映像の展開
   - 後半24,861〜29,873ms（5,012ms、画面表示5.0秒）を選択して保存した。
   - 開発用画面で150枚を展開し、manifestが `rangeStartMs=24861` / `rangeEndMs=29873` / `isComplete=true` になった。
   - 展開先頭フレームを、全体プレビューの先頭フレームと後半フレームに並べて目視比較した。展開画像は後半プレビューと同じ赤い器具・金属フレームの位置関係で、先頭プレビューとは画角が異なり、先頭10秒ではなく選択した後半映像であることを確認した。
3. 範囲変更と即時キャッシュ無効化
   - 範囲を11,328〜16,340ms（5,012ms）へ変更して保存した。
   - 保存直後、`frames/<clipId>/` に旧ファイルが存在しないことを確認した。
   - 再展開後のmanifestは新しい開始・終了値となり、150枚が生成された。
4. 同一範囲のキャッシュ再利用
   - 範囲を変えずに開発用画面を再度開き、「キャッシュから読み込みました」、所要時間97msを確認した。
5. リセット
   - リセット後、`clips.json` の `trimStartMs` / `trimEndMs` はnull、カードの範囲表示は消えた。
   - 再展開manifestは範囲null、299枚、`isComplete=false` となり、従来どおり先頭10秒相当へ戻った。
6. 範囲設定済みクリップの削除
   - 0〜10,000msを設定した29,873msクリップについて、削除前に動画・サムネイル・比較キャッシュ・24枚のプレビューキャッシュの4パスが存在することを確認した。
   - UIから削除後、一覧は空になり、4パスすべてが `No such file or directory` になった。
7. 破損クリップの導線
   - 動画ファイルを一時退避して再起動し、カードが「この動画は読み込めません」になることを確認した。
   - 長押しメニューは「フレーム展開（開発用）」「メモを編集」「削除」のみで、「比較範囲を選択」は表示されなかった。確認後はファイルと実測メタデータを復元した。
8. 範囲選択画面の全終了経路
   - 保存、Android戻るキー、プレビュー生成開始700ms後の戻るを実行し、いずれもライブラリへ戻った。
   - 生成中キャンセル後のlogcatに `FATAL EXCEPTION` はなかった。
   - あわせて削除確認ダイアログは外側タップ、キャンセルボタン、削除ボタンの3経路を実行し、クラッシュがないことを確認した。

自動検証結果:

- `dart format`: 成功
- `flutter analyze`: No issues found
- `flutter test --reporter expanded --timeout 30s`: 43件すべて成功
- `flutter build apk --debug`: 成功
- `git diff --check`: 空白エラーなし

## 実行できなかった項目とその理由

なし。指示書4章の8シナリオ、閉じ方の各経路、静的解析、全テスト、APKビルドを実行した。

## 設計上の判断

- 論理トリミング値は元動画を変更せず `Clip` のミリ秒値として保存し、両端nullを未設定として旧JSONと互換にした。
- 範囲はモデル保存時と生成時の両方で検証する。UIは10秒超を操作可能にして理由を表示し、保存だけを無効にすることで、制約を理解しながらハンドルを戻せるようにした。
- 通常比較キャッシュのmanifestへ範囲を含め、範囲が1msでも変われば再利用しない。さらに保存時に旧比較キャッシュを即時削除し、不要データを残さない。
- プレビューは比較用JPEGと用途・解像度・寿命が異なるため、`frames_preview/<clipId>/` に分離した。最大24枚、長辺240pxで動画全体を均等サンプリングする。
- 通常展開の未設定時は従来の先頭10秒/600枚上限と `isComplete=false` を維持した。明示範囲はその範囲全体を処理できた場合に完了、全体プレビューは24枚へ間引いて全期間を処理した場合に完了とした。
- iOSはフェーズ対象外のため実装を追加せず、Pigeon生成物の更新のみ行った。
