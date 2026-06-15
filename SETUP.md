# Clawd Listen セットアップガイド（AI エージェント向け）

> **このドキュメントについて**
> このガイドは、Clawd Listen を利用したいユーザーの代わりに、AI エージェント
> （Claude Code など）が macOS 環境へセットアップを行うための手順書です。
> ユーザーは「このリポジトリを読んでセットアップして」と AI に依頼することを想定しています。
>
> **AI への指示**: 以下のステップを順に実行してください。AI が直接実行できる
> 操作はコマンドを実行し、ユーザーの手が必要な操作（ブラウザ操作・GUI・パスワード入力・
> 権限ダイアログ）は、その都度ユーザーに分かりやすく依頼してください。各ステップの完了を
> 確認してから次へ進んでください。

---

## 前提知識

Clawd Listen は次の構成で動作する macOS ネイティブアプリです。

- **文字起こし**: OpenAI Realtime API (`gpt-4o-transcribe`) — OpenAI API キーが必要（有料）
- **会議中 Q&A**: Claude Code CLI (`claude -p`) — Claude の Pro / Max サブスクリプション推奨
- **システム音声の取得**: ScreenCaptureKit（macOS 標準）

> **重要**: BlackHole などの仮想オーディオデバイスは **不要** です。
> ScreenCaptureKit がシステム音声を直接キャプチャするため、オーディオルーティングの
> 設定は要りません。古い記事で BlackHole + Multi-Output Device の設定を求めるものが
> ありますが、本アプリ（ScreenCaptureKit 版）には当てはまりません。

---

## ステップ 0: 環境の前提チェック

以下を順に確認してください。

```bash
# macOS 14 (Sonoma) 以降か
sw_vers

# Swift toolchain（Xcode Command Line Tools）があるか
swift --version || xcode-select --install

# claude CLI があるか（Q&A 機能に必要。なければ Q&A のみ使えない）
which claude
```

- `sw_vers` の `ProductVersion` が **14 以上**であること。13 以下なら動作しません。
- `swift --version` が失敗する場合は `xcode-select --install` をユーザーに実行してもらう。
- `claude` が見つからない場合は、Q&A 機能を使うなら
  [Claude Code 公式手順](https://docs.claude.com/en/docs/claude-code/quickstart) に従って
  インストールするようユーザーに案内する（文字起こし・議事録保存だけなら不要）。

---

## ステップ 1: OpenAI API キーの取得

文字起こしに OpenAI API キーが必須です。以下をユーザーに依頼してください。

1. ブラウザで [platform.openai.com/api-keys](https://platform.openai.com/api-keys) を開く。
2. OpenAI アカウントでログイン（なければ新規登録）。
3. **「Create new secret key」** をクリックし、名前（例: `clawd-listen`）を付けて作成。
4. 表示された `sk-proj-...` で始まるキーをコピーして控える（**この画面を閉じると再表示されない**）。
5. [platform.openai.com/settings/organization/billing](https://platform.openai.com/settings/organization/billing)
   で支払い方法を登録し、`gpt-4o-transcribe` を利用できる残高があることを確認する。

> コスト目安: 会議 1 時間あたり約 $0.7（マイク + システム音の 2 ストリーム並列）。

取得したキーは後のステップ 5 でアプリに設定します。AI はキーの値をログや
ファイルに書き出さないでください（Keychain にのみ保存します）。

---

## ステップ 2: ビルド

リポジトリのルートで以下を実行します。

```bash
# 1. 自己署名証明書のセットアップ（初回のみ）
#    実行中に macOS のログインパスワード入力をユーザーに求めます。
./scripts/setup-signing.sh

# 2. リリースビルド + .app バンドル組み立て
./build.sh
```

成功すると `dist/Clawd Listen.app` が生成されます。

- `setup-signing.sh` はコード署名用の自己署名証明書を作成し、再ビルド時に
  マイク・画面収録権限が維持されるようにします。**ログインパスワードの入力が必要**な
  ので、その旨をユーザーに伝えてください。
- ビルドに失敗する場合は [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) を参照。

---

## ステップ 3: インストール

```bash
# .app を Applications へコピー
cp -R "dist/Clawd Listen.app" /Applications/

# 初回起動の Gatekeeper 警告を回避（ad-hoc 署名のため）
xattr -cr "/Applications/Clawd Listen.app"

# 起動
open "/Applications/Clawd Listen.app"
```

`xattr -cr` を実行しない場合、「開発元が未確認」と表示されて起動できません。
その場合はユーザーに **Applications フォルダ内のアプリを右クリック → 開く** を案内してください。

---

## ステップ 4: 権限の付与

アプリ起動後、初回セットアップ画面が表示されます。次の 2 つの権限をユーザーに付与してもらいます。

1. **マイク** — セットアップ画面の「許可する」をクリック → OS のダイアログで許可。
2. **画面収録** — 「許可する」をクリック → システム設定が開く → Clawd Listen を ON →
   **アプリの再起動が必要**（画面収録権限は再起動後に有効化される）。

権限の状態はセットアップ画面の更新ボタン（↻）で再チェックできます。

---

## ステップ 5: アプリ内の設定

セットアップ画面で以下を設定します（すべて完了すると画面は自動で折り畳まれます）。

1. **OpenAI API Key** — ステップ 1 で取得した `sk-proj-...` を入力して「保存」。
   Keychain に暗号化保存されます。
2. **議事録の保存先（必須）** — 「選択」で録音停止時に議事録 Markdown を書き出す
   フォルダを指定。**未設定だと録音を開始できません**。
3. **知識源フォルダ（任意）** — Q&A 時に Claude が参照するフォルダ（Obsidian vault や
   ナレッジ管理ディレクトリなど）。未指定なら Q&A は会議文脈 + Web 検索のみで回答します。

---

## ステップ 6: 動作確認

1. ヘッダー右の録音ボタン（⏺）をクリック。
2. 何か話す、または音声付きの動画を再生する。
3. 左カラムに `[自分]`（マイク）/ `[相手]`（システム音）のラベル付きで
   文字起こしがリアルタイム表示されることを確認。
4. ヘッダーの停止ボタン（⏹）で録音終了 → タイトルが自動生成され、
   ステップ 5 で指定したフォルダに `YYYY-MM-DD_HH-mm_<タイトル>.md` が保存される。

ここまで確認できればセットアップ完了です。

---

## バックグラウンド常駐（任意）

ログイン時に自動起動させたい場合:

```bash
sed "s|\$HOME|$HOME|g" config/com.clawdlisten.agent.plist \
  > ~/Library/LaunchAgents/com.clawdlisten.agent.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.clawdlisten.agent.plist
```

---

## トラブルシューティング

問題が起きた場合は [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) を参照してください。
代表的な症状と対処をまとめてあります。
