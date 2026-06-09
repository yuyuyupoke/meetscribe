# Clawd Listen

<p align="center">
  <img src="Resources/Clawd.png" alt="Clawd Listen" width="160" />
</p>

<p align="center">
  <strong>macOS 用リアルタイム会議傍聴アシスタント</strong><br>
  あなたが参加している会議をフローティング小窓が静かに聞きながら、必要なときに Claude へ質問できる。
</p>

<p align="center">
  <a href="#-機能"><strong>機能</strong></a> ·
  <a href="#-インストール"><strong>インストール</strong></a> ·
  <a href="#-必要なもの"><strong>必要なもの</strong></a> ·
  <a href="#-使い方"><strong>使い方</strong></a> ·
  <a href="#-トラブルシューティング"><strong>トラブルシューティング</strong></a>
</p>

---

## ✨ 機能

- **リアルタイム文字起こし** — マイク（自分）とシステム音（相手）を独立した 2 ストリームで OpenAI `gpt-4o-transcribe` に送信。話者ラベル付きでリアルタイム表示。
- **会議中 Q&A** — 進行中の文字起こしを文脈として Claude に質問できる。ユーザー指定の知識源フォルダ（Obsidian Vault 等）を `Glob` / `Grep` / `Read` で検索して根拠付き回答。
- **完全ローカル + 既存サブスク活用** — Claude Max のサブスクリプションをそのまま使うため、文字起こし以外の Q&A コストはゼロ。
- **フローティング小窓** — 常に最前面、ドラッグでリサイズ可能、画面共有時は非表示 (Stealth Window)。
- **議事録自動保存** — 録音停止と同時にタイトルを Claude が自動生成、ユーザー指定フォルダに Markdown で書き出し。
- **エコー対策** — Voice Processing (AEC + AGC + ノイズ抑制) を有効化し、オンライン会議で相手の声がマイクに回り込む 2 重記録を防止。
- **バッテリー最適化** — VU メーター更新の throttle、権限再チェックの throttle で常時稼働でも軽量。

## 📥 インストール

### 方法 A: DMG をダウンロード（推奨）

1. [Releases](https://github.com/yuyuyupoke/clawd-listen/releases) から `Clawd-Listen-x.y.z.dmg` をダウンロード。
2. DMG をダブルクリックし、`Clawd Listen.app` を `Applications` フォルダにドラッグ。
3. **初回起動時**: `Applications` 内の `Clawd Listen.app` を **右クリック → 開く** を選択（Gatekeeper の警告回避）。
   - 一度この方法で開けば、以降は通常のダブルクリックで起動できる。

### 方法 B: ソースからビルド

```bash
git clone https://github.com/yuyuyupoke/clawd-listen.git
cd clawd-listen
./scripts/setup-signing.sh   # 初回のみ: 自己署名証明書を作成
./build.sh                   # release ビルド + .app バンドル組み立て
open dist/Clawd\ Listen.app
```

## 🔑 必要なもの

| 要件 | 用途 |
|---|---|
| **macOS 14 (Sonoma) 以降** | `AVAudioVoiceProcessingOtherAudioDuckingConfiguration` を使用 |
| **OpenAI API Key** | リアルタイム文字起こし (`gpt-4o-transcribe`) に必須。[platform.openai.com](https://platform.openai.com/api-keys) で取得 |
| **Claude Code CLI** | Q&A 機能に必要。`~/.local/bin/claude` / `/usr/local/bin/claude` / `/opt/homebrew/bin/claude` のいずれかに存在することを想定。[公式インストール手順](https://docs.claude.com/en/docs/claude-code/quickstart) |
| **Claude Max サブスクリプション** | Q&A は `claude -p` 経由で実行されるため Claude Max 契約 (Pro/Max) があると課金不要 |
| **マイク権限** | システム設定 → プライバシーとセキュリティ → マイク |
| **画面収録権限** | システム音声キャプチャに必須 (映像は記録・送信されません) |

### 文字起こしのコスト目安

OpenAI `gpt-4o-transcribe` の課金: マイクとシステム音の 2 ストリームを並列送信するため、**1 時間の会議でおよそ $0.7 程度**。1 ヶ月 20 時間使用で約 $14 ($1 ≒ 150 円換算で 約 ¥2,100)。

## 🎙️ 使い方

### 初回セットアップ

アプリを起動すると、ヘッダーに「⚙️ 初回セットアップ」セクションが表示される。以下を上から順に設定。

1. **マイク権限** — クリックで OS のダイアログ。
2. **画面収録権限** — クリックで OS のダイアログ。許可後はアプリの再起動が必要。
3. **OpenAI API Key** — `sk-proj-...` を入力 → 「保存」。Keychain に暗号化保存される。
4. **議事録の保存先（必須）** — 録音停止時に Markdown 議事録を書き出すフォルダを選択。
5. **知識源フォルダ（任意）** — Q&A 時に Claude が参照するフォルダ (Obsidian Vault, ナレッジ管理ディレクトリ等)。未指定なら Q&A は会議文脈 + Web 検索のみ。

すべて設定が完了するとセットアップセクションは自動で折り畳まれる。ヘッダー左の 📁 ボタンで知識源フォルダはいつでも変更可能。

### 録音 → 議事録保存

1. 会議が始まったら、ヘッダー右の ⏺ ボタン（赤い録音アイコン）をクリック。
2. マイクとシステム音が並列で文字起こしされる。左カラムに `[自分]` `[相手]` ラベル付きで流れる。
3. 会議中に質問したいときは右カラム下部の入力欄に質問 → ⏎ または ✈️ ボタン。Claude が知識源と Web を参照して回答。
4. 会議が終わったら ⏹ ボタンで停止 → タイトル自動生成 + Markdown 保存 → 「議事録保存先」フォルダに `YYYY-MM-DD_HH-mm_<タイトル>.md` で書き出し。
5. 保存せず破棄したい場合は ❌ ボタン (Kill Switch)。

### Q&A の例

| 質問 | 期待動作 |
|---|---|
| 「今の話題の◯◯って何？」 | 会議文脈から要約 |
| 「過去の同テーマの議事録を探して」 | 知識源フォルダから関連 md を Grep / Read |
| 「業界の最新動向を教えて」 | WebSearch / WebFetch で調査 |

## 🛠️ トラブルシューティング

### 「開発元未確認」と表示されて起動できない

ad-hoc 署名のため Gatekeeper が警告を出す。**Applications フォルダの `Clawd Listen.app` を右クリック → 「開く」** を選択。一度許可すれば以降は普通にダブルクリックで起動できる。

それでも開けない場合：

```bash
xattr -cr "/Applications/Clawd Listen.app"
```

### 「The Realtime Beta API is no longer supported」エラー

OpenAI Realtime API の Beta → GA 移行に追従できていない古いバージョン。最新バージョンに更新。

### Q&A で `claude CLI が見つかりません`

Claude Code をインストールし、`claude` バイナリが `$PATH` に含まれていることを確認：

```bash
which claude
# /usr/local/bin/claude  などが表示されればOK
```

[Claude Code 公式インストール手順](https://docs.claude.com/en/docs/claude-code/quickstart)

### マイクの音声レベルメーターは振れるが文字起こしされない

OpenAI 側のクォータ超過、または音声入力が無音判定されている可能性。[OpenAI Usage](https://platform.openai.com/usage) で使用量を確認。

### バックグラウンド常駐させたい

```bash
# 同梱の plist を $HOME 展開してインストール
sed "s|\$HOME|$HOME|g" config/com.clawdlisten.agent.plist \
    > ~/Library/LaunchAgents/com.clawdlisten.agent.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.clawdlisten.agent.plist
```

## 🏗️ アーキテクチャ

```
┌────────────────────────────────────────────────────────────────┐
│  Clawd Listen (Swift/SwiftUI ネイティブ)                       │
├────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐    ┌────────────────────┐    ┌─────────────┐ │
│  │ AVAudioEngine│   │  ScreenCaptureKit  │    │  AppKit UI  │ │
│  │  (マイク)    │   │  (システム音)      │    │  (Float Pan)│ │
│  └──────┬──────┘    └─────────┬──────────┘    └──────┬──────┘ │
│         │  PCM 24kHz mono     │                       │        │
│         ↓                     ↓                       │        │
│  ┌──────────────────────────────────┐                 │        │
│  │ OpenAI Realtime API (WebSocket)  │                 │        │
│  │ - gpt-4o-transcribe              │                 │        │
│  │ - server_vad turn detection      │                 │        │
│  └──────────────┬───────────────────┘                 │        │
│                 │ delta / completed                   │        │
│                 ↓                                     │        │
│  ┌───────────────────────────┐                        │        │
│  │ TranscriptStore           │ ─────────────────────→ │        │
│  └──────┬────────────────────┘                        │        │
│         │                                             │        │
│         ↓                          ┌──────────────────┴─────┐  │
│  ┌─────────────────────┐           │ Q&A 入力              │  │
│  │ TranscriptExporter  │           ↓                       │  │
│  │ (Markdown 保存)     │      ┌─────────────────────┐      │  │
│  └─────────────────────┘      │ ClaudeQAClient      │      │  │
│         ↓                     │ (claude -p CLI)     │ ←────┤  │
│  ユーザー指定の保存先          │ --add-dir <知識源>  │      │  │
│                               └─────────────────────┘      │  │
│                                                            │  │
└────────────────────────────────────────────────────────────┘
```

主要ファイル:

| ファイル | 役割 |
|---|---|
| `Sources/ClawdListen/AudioSession.swift` | 録音セッション全体の統合制御 |
| `Sources/ClawdListen/MicrophoneCapture.swift` | マイク `AVAudioEngine` + Voice Processing |
| `Sources/ClawdListen/SystemAudioCapture.swift` | システム音 `ScreenCaptureKit` |
| `Sources/ClawdListen/TranscriptionClient.swift` | OpenAI Realtime WebSocket クライアント |
| `Sources/ClawdListen/ClaudeQAClient.swift` | Claude CLI subprocess + プロンプト構築 |
| `Sources/ClawdListen/TranscriptExporter.swift` | Markdown 議事録レンダリング |
| `Sources/ClawdListen/FloatingPanel.swift` | NSWindow ベースのフローティング小窓 |

## 🤝 コントリビュート

Issue / Pull Request 歓迎。

開発環境のセットアップ：

```bash
git clone https://github.com/yuyuyupoke/clawd-listen.git
cd clawd-listen
./scripts/setup-signing.sh
./build.sh debug
```

## ☕ サポート

このアプリが役に立ったら [Buy Me a Coffee](https://buymeacoffee.com/yuyuyupoke) で開発を応援していただけると嬉しいです。

## 📄 License

[MIT License](LICENSE) — 商用利用、改変、再配布、すべて自由。

## 🙏 謝辞

- [OpenAI Realtime API](https://platform.openai.com/docs/guides/realtime) — `gpt-4o-transcribe`
- [Anthropic Claude](https://www.anthropic.com/) — Q&A エンジン
- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) / [AVFoundation](https://developer.apple.com/documentation/avfoundation) — Apple のキャプチャ API
