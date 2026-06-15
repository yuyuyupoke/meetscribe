<div align="center">
  <img src="Resources/Clawd.png" alt="Clawd Listen" width="140" />

  # Clawd Listen

  macOS 向けリアルタイム会議文字起こし & Q&A。

  [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
  [![Release](https://img.shields.io/github/v/release/yuyuyupoke/clawd-listen)](https://github.com/yuyuyupoke/clawd-listen/releases)
  [![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](https://www.apple.com/macos/)
  [![Swift 6](https://img.shields.io/badge/Swift-6-orange?logo=swift)](https://swift.org/)

  [機能](#features) · [インストール](#install) · [使い方](#usage) · [アーキテクチャ](#architecture) · [ドキュメント](docs/)
</div>

---

Clawd Listen は、マイク音声とシステム音声を並列で文字起こしし、ライブの議事録と手元のナレッジベースに対して Claude で問い合わせができる、macOS ネイティブのフローティングパネルアプリ。会議に別のボットを呼ばずに、静かな副操縦士が欲しいときのために設計されている。

## Features

- **デュアルストリーム文字起こし** — マイクとシステム音声を独立にキャプチャし、話者ラベル付きで OpenAI `gpt-4o-transcribe` にストリーミング。
- **会議中 Q&A** — ライブ議事録に対して Claude で質問。`Glob` / `Grep` / `Read` を介してユーザー指定のナレッジフォルダ（例: Obsidian vault）にもグラウンディング。
- **サブスク連動** — Q&A は `claude -p` 経由で実行され、Claude Max プランを追加課金なしで再利用。
- **フローティングパネル** — 常に最前面、サイズ可変、画面共有から非表示（ステルスウィンドウ）。
- **自動エクスポート** — 停止時に Claude が会議タイトルを生成し、`YYYY-MM-DD_HH-mm_<title>.md` として保存。
- **エコーキャンセル** — Voice Processing（AEC + AGC + ノイズ抑制）でオンライン会議での二重キャプチャを防止。
- **低オーバーヘッド** — VU メータと権限チェックをスロットリングし、終日利用に耐える設計。

## Requirements

| | |
|---|---|
| OS | macOS 14 (Sonoma) 以降 |
| OpenAI | `gpt-4o-transcribe` にアクセス可能な API キー |
| Claude Code | `$PATH` 上の `claude` CLI（Pro または Max サブスク推奨） |
| 権限 | マイク、画面収録 |

文字起こしコスト: 会議 1 時間あたり約 $0.7（2 ストリーム並列）。

## Install

> **AI にセットアップを任せる場合**: このリポジトリを clone し、Claude Code などの
> AI エージェントに「[SETUP.md](SETUP.md) を読んでセットアップして」と依頼するだけで、
> ビルドから権限設定・API キー登録まで対話的に完了できます。

[Releases](https://github.com/yuyuyupoke/clawd-listen/releases) から最新の DMG をダウンロードし、以下を実行する。

```bash
# First launch only — bypass Gatekeeper (ad-hoc signed)
xattr -cr "/Applications/Clawd Listen.app"
open "/Applications/Clawd Listen.app"
```

もしくはソースからビルド。

```bash
git clone https://github.com/yuyuyupoke/clawd-listen.git
cd clawd-listen
./scripts/setup-signing.sh
./build.sh
```

## Usage

初回起動時に OpenAI キー、出力フォルダ、必要に応じてナレッジフォルダを設定する。資格情報は Keychain に保存される。

**会議を録音する**

録音ボタンをクリック。マイクとシステム音声が並列にストリーミングされ、それぞれ `[self]` / `[other]` とラベル付けされる。停止すると自動でタイトルが生成され、Markdown として出力フォルダにエクスポートされる。

**会議中に質問する**

右パネルに質問を入力。Claude がライブ議事録、ナレッジフォルダ、Web 検索を組み合わせて回答する。

| 質問 | 挙動 |
|---|---|
| 「この用語の意味は?」 | ライブコンテキストから要約 |
| 「関連メモを探して」 | ナレッジフォルダを横断して Grep/Read |
| 「業界の最新データは?」 | WebSearch + WebFetch |

**バックグラウンドエージェントとして実行する**

```bash
sed "s|\$HOME|$HOME|g" config/com.clawdlisten.agent.plist \
  > ~/Library/LaunchAgents/com.clawdlisten.agent.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.clawdlisten.agent.plist
```

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  Clawd Listen (Swift / SwiftUI)                              │
├──────────────────────────────────────────────────────────────┤
│  ┌──────────────┐   ┌────────────────────┐   ┌────────────┐  │
│  │ AVAudioEngine│   │  ScreenCaptureKit  │   │ AppKit UI  │  │
│  │     mic      │   │   system audio     │   │ float panel│  │
│  └──────┬───────┘   └─────────┬──────────┘   └─────┬──────┘  │
│         │  PCM 24kHz mono     │                    │         │
│         ▼                     ▼                    │         │
│  ┌──────────────────────────────────┐              │         │
│  │ OpenAI Realtime API (WebSocket)  │              │         │
│  │  gpt-4o-transcribe · server_vad  │              │         │
│  └────────────────┬─────────────────┘              │         │
│                   │ delta / completed              │         │
│                   ▼                                │         │
│  ┌─────────────────────────────┐                   │         │
│  │ TranscriptStore             │ ──────────────────┤         │
│  └──────┬──────────────────────┘                   │         │
│         │                          ┌───────────────┴──────┐  │
│         ▼                          │ Q&A input            │  │
│  ┌─────────────────────┐           ▼                      │  │
│  │ TranscriptExporter  │     ┌─────────────────────┐      │  │
│  │   Markdown out      │     │ ClaudeQAClient      │ ◀────┤  │
│  └─────────────────────┘     │  claude -p · --add-dir│    │  │
│                              └─────────────────────┘      │  │
└──────────────────────────────────────────────────────────────┘
```

| ソース | 責務 |
|---|---|
| `AudioSession.swift` | セッションのライフサイクル |
| `MicrophoneCapture.swift` | `AVAudioEngine` + Voice Processing |
| `SystemAudioCapture.swift` | `ScreenCaptureKit` タップ |
| `TranscriptionClient.swift` | OpenAI Realtime WebSocket |
| `ClaudeQAClient.swift` | Claude CLI サブプロセス + プロンプト組み立て |
| `TranscriptExporter.swift` | Markdown レンダリング |
| `FloatingPanel.swift` | `NSWindow` フローティングパネル |

## Documentation

- [セットアップガイド（AI 向け）](SETUP.md)
- [トラブルシューティング](docs/TROUBLESHOOTING.md)
- [変更履歴](CHANGELOG.md)
- [セキュリティポリシー](SECURITY.md)

## Contributing

Issue と Pull Request を歓迎。クローン後は `./build.sh debug` を実行すること。

## Support

Clawd Listen で時間を節約できたなら、[note で開発を応援する](https://note.com/yuyuyu303030jp/n/n17ba34bf2ffb?app_launch=false)。

## License

[MIT](LICENSE)
