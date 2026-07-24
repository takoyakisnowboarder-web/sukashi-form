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

## 次のアクション(優先順)

1. (オーナー判断) **Mac環境の確保方法を決める**(クラウドビルド/リモートMacレンタル/実機購入)。
   `docs`の企画設計書に記載の通り、ネイティブSwiftコードを含むため
   Xcodeデバッガが使える環境が実質必須(クラウドビルドのみでは実機クラッシュの原因調査が困難)
2. 環境が決まり次第、**まず`flutter build ios`(または`flutter run`)が通ることだけを確認**する
   小さなフェーズを切る。今回の未検証差分(Info.plist・AppDelegate.swift)はここで最初に検証される
3. Apple Developer Program(年99ドル)への加入(iOS実機テスト・TestFlight配布に必要)
4. ネイティブ実装(`AVAssetImageGenerator`)のフェーズ指示書をClaudeが作成し、Codexが実装
   (Android版フェーズ3a/3bと同じ分割: 配線+probe+サムネイル → extractFrames本体)
5. 音量キー録画の実現可否を先に技術検証してから、フェーズとして切るか判断する
6. Android版のPlay Store審査結果が出た後、**「iOS着手条件」(企画設計書の未決事項)を
   実際の売上と照らして再確認**しておくとよい

## 更新履歴

- 2026-07-24: 初版作成。アプリ改名の完了、iOSプラットフォーム生成、Info.plist/AppDelegate.swiftの
  下準備をWindows環境で実施。ネイティブ実装は次フェーズ(Mac確保後)へ切り出した (claude)
