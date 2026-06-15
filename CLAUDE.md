# CLAUDE.md

このリポジトリは **MeetScribe** — macOS 向けのリアルタイム会議文字起こし & Q&A アプリ
（Swift / SwiftUI）です。

## ユーザーからセットアップを依頼されたら

ユーザーが「セットアップして」「使えるようにして」などと依頼した場合は、
**[SETUP.md](SETUP.md) を読み、その手順に厳密に従って**環境構築を進めてください。

要点:

- AI が直接実行できる操作（`swift build`、`./build.sh`、ファイルコピー等）は実行する。
- ユーザーの手が必要な操作（OpenAI API キーのブラウザ取得、権限ダイアログ、
  ログインパスワード入力、GUI でのフォルダ選択）は、その都度分かりやすく依頼する。
- 各ステップの完了を確認してから次に進む。
- **OpenAI API キーの値をログ・ファイル・コミットに残さない**（Keychain にのみ保存）。

## 重要な前提

- **BlackHole 等の仮想オーディオデバイスは不要**。システム音声は ScreenCaptureKit で
  直接取得します。オーディオルーティングの設定は案内しないでください。
- 動作要件: macOS 14+ / OpenAI API キー / `claude` CLI（Q&A 用、任意）。

## 開発時

- ビルド: `./build.sh`（リリース）/ `./build.sh debug`（デバッグ）
- アーキテクチャと各ソースの責務は [README.md](README.md) の「Architecture」を参照。
- トラブル時は [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)。
