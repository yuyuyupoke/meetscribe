<div align="center">
  <img src="Resources/Scribe.png" alt="MeetScribe" width="140" />

  # MeetScribe

  macOS 向けリアルタイム会議文字起こし & Copilot。

  [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
  [![Release](https://img.shields.io/github/v/release/yuyuyupoke/meetscribe)](https://github.com/yuyuyupoke/meetscribe/releases)
  [![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](https://www.apple.com/macos/)
  [![Swift 6](https://img.shields.io/badge/Swift-6-orange?logo=swift)](https://swift.org/)

  [機能](#features) · [インストール](#install) · [使い方](#usage) · [アーキテクチャ](#architecture) · [ドキュメント](docs/)
</div>

---

MeetScribe は、マイク音声とシステム音声を並列で文字起こしし、右カラムの Copilot パネルが会議の全体像とキャッチアップ要約を自動で提示する、macOS ネイティブのフローティングパネルアプリ。会議に別のボットを呼ばずに、静かな副操縦士が欲しいときのために設計されている。

## Features

- **デュアルストリーム文字起こし** — マイクとシステム音声を独立にキャプチャし、話者ラベル付きで OpenAI `gpt-realtime-whisper` にストリーミング。
- **インライン整形・翻訳** — 確定したセグメントを `gpt-4.1-mini` でフィラー除去・言い直し統合。原文が日本語以外なら日本語訳を同時に生成し、原文の下に併記。
- **Copilot パネル** — ボタン押下で直近 1/3/5/10 分の発話を日本語で要約する「Catchup」と、発話量・経過時間トリガーで自動更新される「全体像」（目的・議題・現在地）。
- **自動タイトル生成** — 停止時に `claude -p` 経由で Claude が会議タイトルを生成し、`YYYY-MM-DD_HH-mm_<title>.md` として保存。
- **フローティングパネル** — 常に最前面、サイズ可変、画面共有から非表示（ステルスウィンドウ）。
- **エコーキャンセル** — Voice Processing（AEC + AGC + ノイズ抑制）でオンライン会議での二重キャプチャを防止。
- **低オーバーヘッド** — VU メータと権限チェックをスロットリングし、終日利用に耐える設計。

## Requirements

| | |
|---|---|
| OS | macOS 14 (Sonoma) 以降 |
| OpenAI | `gpt-realtime-whisper`（文字起こし）と `gpt-4.1-mini`（整形・翻訳・Copilot）にアクセス可能な API キー |
| Claude Code | `$PATH` 上の `claude` CLI（会議タイトル生成のみに使用。Pro または Max サブスク推奨） |
| 権限 | マイク、画面収録 |

コスト目安: 文字起こし単体で会議 1 時間あたり約 $0.7（2 ストリーム並列）。これに加えて、セグメント整形・翻訳と Copilot パネル（Catchup 要約・全体像自動更新）の利用分だけ `gpt-4.1-mini` の追加費用（$0.40/M 入力・$1.60/M 出力）が発生する。

## Install

> **AI にセットアップを任せる場合**: このリポジトリを clone し、Claude Code などの
> AI エージェントに「[SETUP.md](SETUP.md) を読んでセットアップして」と依頼するだけで、
> ビルドから権限設定・API キー登録まで対話的に完了できます。

[Releases](https://github.com/yuyuyupoke/meetscribe/releases) から最新の DMG をダウンロードし、以下の手順でインストールする。

1. `MeetScribe-*.dmg` をダブルクリックしてマウント
2. マウントされたウィンドウ内の **`install.command`** をダブルクリック
3. Terminal が自動起動してセットアップが進み、完了すると MeetScribe が起動する

> `install.command` がうまく動かない場合の手動代替手段（ad-hoc 署名のため初回のみ Gatekeeper にブロックされる）。
>
> ```bash
> xattr -cr "/Applications/MeetScribe.app"
> open "/Applications/MeetScribe.app"
> ```

もしくはソースからビルド。

```bash
git clone https://github.com/yuyuyupoke/meetscribe.git
cd meetscribe
./scripts/setup-signing.sh
./build.sh
```

## Usage

初回起動時に OpenAI キー、出力フォルダ、必要に応じてナレッジフォルダを設定する。資格情報は Keychain に保存される。

**会議を録音する**

録音ボタンをクリック。マイクとシステム音声が並列にストリーミングされ、それぞれ `[self]` / `[other]` とラベル付けされる。停止すると自動でタイトルが生成され、Markdown として出力フォルダにエクスポートされる。

**Copilot パネルを使う**

右パネルは録音中、自動で「全体像」（目的・議題・現在地）を更新し続ける。加えて下部の 1/3/5/10 分ボタンを押すと、その期間の発話を日本語で要約した「Catchup」カードが追加される。

| 操作 | 挙動 |
|---|---|
| 何もしない | 発話が一定量溜まる、または一定時間経過するたびに全体像が自動更新される |
| Catchup ボタン（1/3/5/10分） | 押した時点から遡ったN分間の発話を要約してカード表示 |
| 発話ゼロの期間で Catchup | LLM を呼ばず「この期間の発話はありません」と即時表示（課金なし） |

**バックグラウンドエージェントとして実行する**

```bash
sed "s|\$HOME|$HOME|g" config/com.meetscribe.agent.plist \
  > ~/Library/LaunchAgents/com.meetscribe.agent.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.meetscribe.agent.plist
```

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  MeetScribe (Swift / SwiftUI)                                     │
├──────────────────────────────────────────────────────────────────┤
│  ┌──────────────┐   ┌────────────────────┐   ┌────────────────┐  │
│  │ AVAudioEngine│   │  ScreenCaptureKit  │   │   AppKit UI     │  │
│  │     mic      │   │   system audio     │   │  float panel    │  │
│  └──────┬───────┘   └─────────┬──────────┘   └────────┬────────┘  │
│         │  PCM 24kHz mono     │                        │          │
│         ▼                     ▼                        │          │
│  ┌──────────────────────────────────┐                  │          │
│  │ OpenAI Realtime API (WebSocket)  │                  │          │
│  │  gpt-realtime-whisper            │                  │          │
│  └────────────────┬─────────────────┘                  │          │
│                   │ delta / completed                  │          │
│                   ▼                                    │          │
│  ┌─────────────────────┐    ┌───────────────────────┐  │          │
│  │ TranscriptCleaner   │───▶│ TranscriptStore        │──┤          │
│  │  gpt-4.1-mini        │    └──────┬─────────────────┘  │          │
│  │  整形 + 対訳         │           │                    │          │
│  └─────────────────────┘           ▼                    │          │
│                          ┌─────────────────────┐         │          │
│                          │ CopilotController   │─────────┤          │
│                          │  gpt-4.1-mini        │         │          │
│                          │  Catchup要約 / 全体像 │         │          │
│                          └─────────────────────┘         │          │
│  ┌─────────────────────┐                                 │          │
│  │ TranscriptExporter  │◀─ 停止時タイトル生成 (claude -p) │          │
│  │   Markdown out      │                                 │          │
│  └─────────────────────┘                                 │          │
└──────────────────────────────────────────────────────────────────┘
```

| ソース | 責務 |
|---|---|
| `AudioSession.swift` | セッションのライフサイクル |
| `MicrophoneCapture.swift` | `AVAudioEngine` + Voice Processing |
| `SystemAudioCapture.swift` | `ScreenCaptureKit` タップ |
| `TranscriptionClient.swift` | OpenAI Realtime WebSocket（`gpt-realtime-whisper`） |
| `TranscriptCleaner.swift` | 確定セグメントの整形・対訳（`gpt-4.1-mini`） |
| `CopilotController.swift` | Catchup 要約・全体像自動更新のロジック統括 |
| `OpenAIChatClient.swift` | `gpt-4.1-mini` chat/completions 共通クライアント |
| `ClaudeQAClient.swift` | Claude CLI サブプロセス（会議タイトル生成のみ） |
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

MeetScribe で時間を節約できたなら、[note で開発を応援する](https://note.com/yuyuyu303030jp/n/n17ba34bf2ffb?app_launch=false)。

## Disclaimer

MeetScribe は個人が開発した非公式プロジェクトであり、Anthropic, PBC および OpenAI, Inc. とは一切関係がなく、これらの企業による承認・提携・後援を受けていません。「Claude」「OpenAI」「gpt-realtime-whisper」等は各社の商標です。

会議タイトル生成機能はユーザーのマシン上で Claude Code CLI (`claude -p`) を呼び出し、ユーザー自身の Claude サブスクリプションを使用します。サブスクリプションの利用は [Anthropic の利用規約](https://www.anthropic.com/legal/consumer-terms) に従う必要があります。本ソフトウェアの利用は自己責任で行ってください。

## License

[MIT](LICENSE)
