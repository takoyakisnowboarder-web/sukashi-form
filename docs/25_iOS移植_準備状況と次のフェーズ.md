# iOS移植 — 準備状況と次のフェーズ

作成: 2026-07-24 (claude)。iOS版着手のための現状整理と、次に着手すべき作業の切り分け。

## 背景

Android版(v1.0.0)はPlay Storeに審査提出済み・審査待ちの段階。オーナーの判断で、
Mac/クラウドビルド環境の選定を待たずに**iOS移植の下準備**を先行させることになった。
このドキュメントは「今できること(Windows上で完結)」と「Mac/Xcodeが無いとできないこと」を分離する。

## 今回やったこと(このセッション)

1. **アプリ表示名の変更を完了**: 「スカシフォーム」→「**オフトレカイセキ**」
   - 対象: `lib/main.dart`(タイトル)、`capture_screen.dart`・`library_screen.dart`(表示文言)、
     `AndroidManifest.xml`(`android:label`)、Kotlin側のギャラリー保存先フォルダ名
     (`Movies/オフトレカイセキ`)、`docs/18_プライバシーポリシー案.md`、`docs/19_ストア掲載情報案.md`
   - **`applicationId`(`com.sukashiform.app`)は変更していない**。公開後は変更不可のため、
     表示名(ブランディング)とアプリID(内部識別子)を明確に分離した
   - 過去のフェーズ指示書・報告書(`docs/01〜17`, `20〜24`)は当時の記録のため**あえて改名していない**
   - ⚠️ **Play Storeの審査提出は旧名「スカシフォーム」のまま**。表示名の変更を反映するには、
     versionCodeを上げて新しいAABを作り直し、再提出する必要がある(オーナー作業)
   - ⚠️ **Play Consoleの「ストアの掲載情報」欄(タイトル・説明文)も別途手動更新が必要**
     (アプリ内の表示名を変えても、ストア掲載情報は自動連動しない)

2. **iOSプラットフォームを`flutter create --platforms=ios`で生成**
   - これまで`.metadata`に`ios`のエントリがなく、Pigeon生成のSwiftスタブ2ファイルしか存在しなかった
     (`.xcodeproj`・`Info.plist`・`AppDelegate.swift`が無い状態)
   - `flutter create`が同時に生成した`test/widget_test.dart`(デフォルトのカウンターアプリテスト、
     存在しない`MyApp`を参照)は本アプリと無関係なので削除済み

3. **`ios/Runner/Info.plist`を設定**
   - `CFBundleDisplayName` を「オフトレカイセキ」に変更(`CFBundleName`は内部識別子として未変更のまま)
   - `NSCameraUsageDescription` を追加(カメラ権限、Apple審査で必須)
   - `NSPhotoLibraryAddUsageDescription` を追加(ギャラリー保存機能の実装に備えて先行追加。
     `image_picker`のインポート機能自体はPHPickerViewController経由のため権限文言は不要)
   - マイク権限(`NSMicrophoneUsageDescription`)は**意図的に追加していない**。
     Android版がRECORD_AUDIOを完全に除去しているのと同じ方針を踏襲する。
     iOS版の`camera`プラグイン実装時も音声トラックを含めないこと

4. **`ios/Runner/AppDelegate.swift`にPigeon配線を追加**
   - Android`MainActivity.kt`の`FrameExtractorApi.setUp(...)`と同じ配線を追加し、
     現状の`FrameExtractorApiStub`(全メソッドunimplemented)を登録
   - 実装パターンはFlutter SDK本体のサンプル
     (`dev/integration_tests/ios_add2app_uiscene/native/AppDelegate-FlutterImplicitEngineDelegate.swift`)
     の`engineBridge.applicationRegistrar.messenger()`を参照して書いた
   - 🔴 **Windows環境にはSwiftコンパイラが無いため、この変更はコンパイル未検証。**
     Xcodeが使える環境で最初にビルドが通ることを確認する必要がある

5. `flutter analyze`クリーン・既存79テストすべてパスを確認(Dartレイヤーへの影響なし)

## 今はできないこと(Mac/Xcodeが必須)

- **`AVAssetImageGenerator`によるネイティブ実装**(`probe`/`generateThumbnail`/`extractFrames`/
  `cancelExtraction`)。Android版のKotlin実装(`FrameExtractorApiImpl.kt`, 494行)を移植する規模の作業
- **音量キー録画のiOS版実装**。Androidの`dispatchKeyEvent`に相当するAPIがiOSには存在しない。
  iOSで物理音量ボタンを検知する標準的な方法は`AVAudioSession`の`outputVolume`をKVO監視する方式だが、
  Appleのシステム音量UIが割り込む・アプリがバックグラウンドだと拾えない等の制約があり、
  **移植というより追加調査が要る**。Android版と同じ体験になるかは未検証
- **ギャラリー自動保存**(`PHPhotoLibrary`によるMediaStore相当の実装)
- 実機・シミュレータでの起動確認、`flutter analyze`のiOS向けビルドエラー検出
- IPAビルド・TestFlight配布・App Store審査提出

## 2026-07-24 追記: Codemagic で iOS ビルドが通ることを実証

**環境決定**: オーナーが Apple Developer Program(年99ドル)に加入。
Mac は購入せず、**Codemagic(クラウドビルド)+ 手持ちの iPhone/iPad** で進める方針に確定。
GitHub リポジトリ `github.com/takoyakisnowboarder-web/sukashi-form` を新規作成し、
Codemagic と連携。App Store Connect API キー(.p8)で署名設定済み。

**ビルド成功までに潰したエラー2件**(いずれも「Swift未検証」として警告していた箇所):

1. `Cannot find 'FrameExtractorApi'/'FrameExtractorApiStub' in scope`
   - 原因: `flutter create` が `project.pbxproj` を作り直した際、それ以前から存在した
     Pigeonの2ファイル(`FrameExtractorApi.g.swift`・`FrameExtractorApiStub.swift`)が
     ビルド対象(PBXFileReference/PBXBuildFile/PBXGroup/PBXSourcesBuildPhase)に
     登録されなかった。Xcodeがこの2ファイルをコンパイルしていなかった
   - 修正: Xcodeが無いので `project.pbxproj` を手動編集し、AppDelegate.swift と同じ扱いで
     Runnerターゲットの4セクションに2ファイルを登録(コミット `2cede71`)
   - ⚠️ **今後 Pigeon で新しいネイティブファイルを追加したら、同様に手動登録が要る**
     (Windows/Xcode無しの制約。ファイルを置くだけではXcodeのビルド対象にならない)

2. `Type 'any FrameExtractorApi' has no member 'setUp'`
   - 原因: Pigeon v27 では `setUp` 静的メソッドがプロトコルではなく別クラス
     `FrameExtractorApiSetup` に置かれる(旧バージョンと異なる)
   - 修正: AppDelegate.swift を `FrameExtractorApiSetup.setUp(...)` に変更(コミット `6c1dbe4`)

**結果**: `flutter build ios --debug --no-codesign` が Codemagic(macOS M2)で成功。
Info.plist(表示名・カメラ/写真権限)・AppDelegate.swift のPigeon配線が実機ビルドで通ることを実証。
**これで「Windows から iOS をビルドできる」パイプラインが確立した。**

> **重要な学び**: `flutter create` は既存のネイティブ手書きファイルを Xcode プロジェクトに
> 登録しない。Android(Gradle)はディレクトリを走査するので気づかないが、iOS(Xcode)は
> pbxproj への明示登録が必須。Windows環境ではこれを手作業でやる必要がある。

## 次のアクション(優先順)

1. ✅ ~~Apple Developer Program 加入~~(完了)
2. ✅ ~~Codemagic + GitHub のビルドパイプライン確立、iOSビルド成功~~(完了)
3. **iPhone/iPad へインストールして起動確認**(次はここ)
   - 現状はスタブ実装なので、**撮影・ライブラリ・比較画面のUIは表示されるが、
     フレーム展開(サムネイル生成・比較準備)はネイティブ未実装のため動かない**
   - まず「アプリが起動して画面遷移できる」ことだけ確認する
   - 署名付きビルド(`--no-codesign`を外す)で iPhone に入れる。TestFlight 経由が確実
4. ネイティブ実装(`AVAssetImageGenerator`)のフェーズ指示書をClaudeが作成し、Codexが実装
   (Android版フェーズ3a/3bと同じ分割: 配線+probe+サムネイル → extractFrames本体)
   - 🔴 **Codexが新規Swiftファイルを追加したら、pbxproj登録も忘れずに**(上記の学び)
5. 音量キー録画の実現可否を先に技術検証してから、フェーズとして切るか判断する
6. ギャラリー自動保存(`PHPhotoLibrary`)の実装

## 今はできないこと(引き続きネイティブ実装が必要)

- **`AVAssetImageGenerator`によるネイティブ実装**(`probe`/`generateThumbnail`/`extractFrames`/
  `cancelExtraction`)。Android版のKotlin実装(`FrameExtractorApiImpl.kt`, 494行)を移植する規模。
  **これが無いとフレーム展開=アプリの中核機能が動かない**
- **音量キー録画のiOS版実装**。Androidの`dispatchKeyEvent`に相当するAPIがiOSには存在しない。
  `AVAudioSession`の`outputVolume`をKVO監視する方式が候補だが制約あり、追加調査が要る
- **ギャラリー自動保存**(`PHPhotoLibrary`によるMediaStore相当の実装)

## 2026-07-24 追記: TestFlight で実機(iPhone)起動確認まで完了

Codemagic の署名まわりで2エラーを潰し、TestFlight 経由で iPhone にインストール・起動に成功した。

**署名で潰したエラー2件**:
1. `app_store 配布タイプに一致するプロファイルが見つかりません`
   - `environment.ios_signing` の自動ブロックはプロファイルを「取得」するだけで「作成」しなかった
   - → 明示的に `app-store-connect fetch-signing-files --create` する方式へ変更
2. `証明書の秘密鍵がないと署名証明書を保存できません`
   - 証明書一覧は空だった。`--create` に証明書作成用の秘密鍵を渡していなかった
   - → ビルド内で `openssl genrsa` で秘密鍵を生成し `--certificate-key` に渡す方式へ
   - ⚠️ 現状は毎回新しい配布用証明書を作る。Apple は配布証明書を最大2つまでのため、
     多数ビルドする段階になったら秘密鍵を環境変数に保存して再利用へ切り替える(codemagic.yaml に明記済み)

**その他の設定**:
- `codemagic.yaml` を追加(ワークフロー「iOS TestFlight」)。UI設定ではなくファイル方式に切り替え
- App ID `com.sukashiform.sukashiForm` を Developer Portal に登録、App Store Connect に
  アプリ「オフトレカイセキ」を作成
- 暗号化輸出コンプライアンス: 手動で「該当なし」を回答 +
  `ITSAppUsesNonExemptEncryption=false` を Info.plist に追加(次回以降は自動スキップ)

**実機での検証結果(iPhone / TestFlight / リリースビルド)**:

| 項目 | 結果 |
|---|---|
| アプリ起動・ライブラリ画面表示 | ✅ |
| 撮影画面へ遷移・カメラ権限許可 | ✅ |
| 撮影してライブラリにクリップが並ぶ | ✅ |
| 画面遷移・クリップ長押しメニュー | ✅(メモ編集・削除が表示) |
| **「比較範囲を選択」が長押しメニューに出ない** | ⏳ **想定通り**。下記参照 |

**「比較範囲を選択」が出ない理由(バグではない)**:
- `library_screen.dart` は `if (!clip.isBroken)` の時だけ「比較範囲を選択」を表示する
- iOSで録画したクリップは、`video_metadata_service` が録画後に `probe()` を呼ぶが、
  iOS の probe はスタブ(必ず失敗)なので `isBroken: true` になる
- → 全クリップが破損扱いになり「比較範囲を選択」が隠れる。ライブラリのカードにも
  「この動画は読み込めません」の破損表示が出る
- **これはネイティブ未実装の必然的な結果**であり、次フェーズの probe 実装で解消する

**結論: iOS版の「殻」(Dartレイヤー + ビルド/署名/配信パイプライン)は完全に動作確認済み。**
残るはネイティブ(Swift)実装のみ。

## 次フェーズ: iOS ネイティブ実装(AVAssetImageGenerator)

Android版の `FrameExtractorApiImpl.kt`(494行, Kotlin)を Swift に移植する。
Android のフェーズ3a/3b と同じ分割で進めるのが安全:

- **iOSフェーズ1(3a相当)**: `probe`(尺・破損検出)+ `generateThumbnail`(サムネイル)
  - これだけで「クリップが破損扱いされなくなる」「サムネイルが出る」「比較範囲を選択が出る」
    という目に見える成果が出る
  - `AVAsset` / `AVAssetImageGenerator` / `AVAssetTrack`(尺・回転)を使う
- **iOSフェーズ2(3b相当)**: `extractFrames`(範囲指定でのフレーム一括展開)+ 進捗通知 + キャンセル
  - `AVAssetImageGenerator.generateCGImagesAsynchronously` でバッチ生成
  - 長辺1280pxのJPEGに変換して保存(Android実装と同じ出力仕様)
- **iOSフェーズ3(任意・後回し)**: ギャラリー自動保存(`PHPhotoLibrary`)、
  音量キー録画(iOSは標準APIがなく要調査)

🔴 **重要**: Codex/実装者が新しい Swift ファイルを追加したら、
`project.pbxproj` への手動登録を忘れないこと(Windows/Xcode無し環境の制約。
ファイルを置くだけではXcodeのビルド対象にならない。今回これで2回ハマった)。

## 更新履歴

- 2026-07-24: 初版作成。アプリ改名の完了、iOSプラットフォーム生成、Info.plist/AppDelegate.swiftの
  下準備をWindows環境で実施。ネイティブ実装は次フェーズ(Mac確保後)へ切り出した (claude)
- 2026-07-24: Apple Developer Program 加入、Codemagic + GitHub でビルドパイプライン確立。
  pbxproj未登録・Pigeon setUp のクラス名の2エラーを潰し、**iOSビルド成功を実証**。
  「flutter create は既存ネイティブファイルをpbxprojに登録しない」学びを記録 (claude)
- 2026-07-24: Codemagic の署名2エラー(プロファイル未作成・秘密鍵欠如)を潰し、
  TestFlight 経由で **iPhone 実機にインストール・起動成功**。撮影・ライブラリ・画面遷移まで動作確認。
  「比較範囲を選択」非表示はprobeスタブによるisBroken判定=想定通りと確認。
  iOS版の殻は完全動作。次はネイティブ(AVAssetImageGenerator)実装フェーズ (claude)
