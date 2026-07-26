# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- 議事録の保存直後に、開発を応援できる導線を控えめに表示するようにした。押し付けにならないよう「3回以上保存した後」「一度表示したら30日は出さない」「今後表示しないを選べる」の3条件を満たしたときだけ出る。ヘッダー右上のコーヒーアイコン（常設）はそのまま

- 初回起動時に、音声が第三者AI（OpenAI / xAI）へ送信されること・録音の告知は利用者の責任であること・API利用料は利用者負担であることを説明する同意画面を追加。同意するまで録音を開始できない
- 録音中にウィンドウを閉じる／⌘Qで終了しようとした場合に「保存して終了 / キャンセル / 保存せずに終了」を確認するようにした。従来は無警告・無保存でアプリが終了し、会議の記録がすべて失われていた
- 緊急停止（Kill Switch）に確認ダイアログを追加。停止ボタンの隣にあり、誤クリックすると議事録が復旧不能で失われていた
- 議事録の保存に失敗した場合、`~/Library/Application Support/MeetScribe/rescue/` へ自動退避するようにした（保存先フォルダの移動・削除・権限喪失・ディスク不足でもデータを失わない）
- `PRIVACY.md` を追加。外部送信されるデータの一覧、ローカル保存先、アンインストール手順を明記

- ⌘+ / ⌘- / ⌘0 でUI全体の文字サイズを拡大・縮小・リセットできるようにした（Macの標準慣習）。メインメニュー「表示」に対応項目を追加。スケールは0.8〜1.8倍・0.1刻みで、設定は再起動後も保持される。文字起こし本文・Copilotパネル・ヘッダー・フッター全体に適用
- ストリーム別ミュートボタンをヘッダーに追加（[自分]=マイク、[相手]=システム音）。ハイブリッド会議（対面参加+Zoom同時入室）で部屋の発話がマイクとZoom経由の両方から二重に文字起こしされるとき、片側を「Scribeに聴かせない」状態にできる。録音中いつでも切替可能、ミュート中はVUメーターがグレー表示、録音終了時に自動解除（次会議への持ち越し事故防止）
- OpenAIとxAIのAPIキーをKeychainへ個別保存し、設定GUIからプロバイダーを選択可能にした
- xAI Grok Speech to TextのStreaming WebSocket（16kHz PCM、partial/final対応）を追加
- xAI選択時は整形・日本語対訳・Catchup・全体像生成を`grok-4.3`へ統一
- 議事録frontmatterへ`provider`と`assistantModel`を記録

### Changed

- **コスト表示を実請求額ベースに正確化**。xAIが返す `cost_in_usd_ticks`（全割引適用後の実請求額、1 USD = 10^10 ticks）を最優先で使うようにした。従来はトークン内訳からの自前計算で、grok-4.3が推論モデルであるために発生する `reasoning_tokens`（`completion_tokens` に含まれない別カウント、実測で完了トークンの8〜18倍）を計上できておらず、**表示が実請求の 1/1.2〜1/2.3 に過小**だった。請求額自体は変わらないが、表示される金額は従来より高くなる
- プロンプトキャッシュにヒットした入力トークンを割引単価で計算するようにした（gpt-4.1-mini $0.10/M、grok-4.3 $0.20/M。`prompt_tokens` はキャッシュ分を含む総数のため、総数×標準単価では過大計算になっていた）
- xAIへのリクエストに `x-grok-conv-id` ヘッダー（用途別の固定キー）を付与し、同一プロンプト接頭辞のリクエストを同じサーバーへ寄せてキャッシュヒット率を上げるようにした（公式推奨の最適化。送信するモデル・プロンプト・パラメータは一切変わらないため応答品質に影響しない）
- プロバイダー選択を会議開始時に固定し、自動再接続でも同じAPIキー・モデルを使用
- xAI Streaming STTの送信音声秒数に基づくコスト表示を追加

### Security

- 動作ログに会議の発話内容を書かないようにした（文字数などのメタ情報のみ）。従来は確定した発話がすべて平文で `~/Library/Logs/MeetScribe/` に永久に蓄積され、議事録の意図しない二重保存になっていた。あわせてログに5MB×2世代の上限を設けた
- 配布ビルドから `com.apple.security.get-task-allow` entitlement を除去。有効な状態では他プロセスからデバッガをアタッチでき、メモリ上のAPIキーや会議音声を読み取られる可能性があった
- 議事録の保存時に同名ファイルを上書きしないようにした（衝突時は `-2`, `-3` を付与）。タイトル生成に失敗すると `会議_HH-mm` が固定名になるため、同じ分に2件保存すると先の議事録が消えていた

### Removed

- 議事録タイトル生成の Claude Code CLI (`claude -p`) 依存を廃止し、会議で使用中のプロバイダー（OpenAI / xAI）で生成するようにした。これにより (1) CLI未導入ユーザーでもタイトルが生成される (2) 転写冒頭3,000字がAnthropicへ送信されなくなり送信先が1社に閉じる (3) コスト表示に出ない不可視の課金が発生しなくなる (4) 未ログイン時に保存が最大60秒待たされる問題が解消する
- DMGの `install.command`（`xattr` による検疫属性の除去）を廃止し、Applicationsへドラッグする標準レイアウトに変更。DMG経由ではスクリプト自体も検疫対象となり機能せず、macOS 15以降はCtrl+クリックでの回避も廃止されているため、READMEに正しい許可手順を記載する方式に改めた
- 「参照」（知識源フォルダ）のUIと設定を削除。旧 `claude -p` Q&A機能の名残で、Copilotパネル化以降どこからも使われていないデッドコードだった

### Fixed

- 同一フレーズが大量反復するSTTハルシネーション（「うんうんうんうんうん」「Information Technology, Information Technology, …」「十十一二十十二…」等、無音・低SNR区間でWhisper系が生成する周期反復）が議事録に混入する問題を修正。`HallucinationFilter`に反復検出（フレーズ4回以上連続かつ全体の6割以上）を追加し、確定時に破棄する（2026-07-24 の議事録2件で最大7.8万文字の反復混入があった実害の対策）
- アプリ自身が行うWebSocketキャンセル（ハートビートタイムアウト・xAI無音タイムアウト・recoverable APIエラーの再接続）を「[相手] 受信エラー: 通信がキャンセルされました」として赤字表示してしまう問題を修正。自己都合キャンセルを`_selfInitiatedCancel`でマークしUI表示を抑制、あわせて再接続成功時に該当ストリームの受信エラー/APIエラー表示もクリアするようにした（従来は再接続成功後も赤字が残り続けた）
- xAIの無音タイムアウト（`ASR stream timed out`）で赤エラーが出続け、以降そのストリームの文字起こしが死んだままになる問題を修正。良性エラーとして扱い、バナーを出さず静かに自動再接続する（再接続を諦めた場合のみ表示）
- SCStreamがOS都合で停止した時（`Stream was stopped by the system` / `Failed to find any displays or windows to capture`）に録音全体を即・保存終了して議事録が分断される問題を修正。まずシステム音声キャプチャの自動復帰をバックオフ付きで約60秒試み、復帰できなかった場合のみ従来どおり保存終了する（2026-07-22 リクルート面談が47分で切断・2ファイルに分断された実害の対策）

## [1.0.0] - 2026-06-09

Initial public release.

### Added

- macOS 14+ 向け SwiftUI / AppKit ネイティブアプリケーション
- マイクとシステム音の 2 ストリーム独立キャプチャ
- OpenAI Realtime API (`gpt-4o-transcribe`) によるリアルタイム文字起こし
- Voice Processing (AEC / AGC / ノイズ抑制) によるオンライン会議の二重記録防止
- `voiceProcessingOtherAudioDuckingConfiguration` (macOS 14+) によるシステム音 ducking 最小化
- Claude Code CLI を介した会議中 Q&A 機能 (Claude Max サブスクリプション利用)
- ユーザー指定の知識源フォルダを `--add-dir` で動的渡し、Glob / Grep / Read による参照
- フローティング小窓 (`NSWindow.level = .floating`、ScreenCaptureKit から不可視)
- 議事録の Markdown 自動保存 (タイトルは Claude が自動生成)
- `HSplitView` による左右カラム幅のドラッグリサイズ
- バッテリー消費低減のためのスロットリング (VU レベル更新 100ms、権限再チェック 30 秒)

[1.0.0]: https://github.com/yuyuyupoke/meetscribe/releases/tag/v1.0.0
