# MeetScribe セットアップガイド（AI エージェント向け）

> **このドキュメントについて**
> このガイドは、MeetScribe を利用したいユーザーの代わりに、AI エージェント
> （Claude Code など）が macOS 環境へセットアップを行うための手順書です。
> ユーザーは「このリポジトリを読んでセットアップして」と AI に依頼することを想定しています。
>
> **AI への指示**: 以下のステップを順に実行してください。AI が直接実行できる
> 操作はコマンドを実行し、ユーザーの手が必要な操作（ブラウザ操作・GUI・パスワード入力・
> 権限ダイアログ）は、その都度ユーザーに分かりやすく依頼してください。各ステップの完了を
> 確認してから次へ進んでください。

---

## 前提知識

MeetScribe は次の構成で動作する macOS ネイティブアプリです。

- **OpenAI選択時**: Realtime API (`gpt-realtime-whisper`)で文字起こし、`gpt-4.1-mini`で整形・翻訳・Copilot
- **xAI選択時**: Grok Speech to Textで文字起こし、`grok-4.3`で整形・翻訳・Copilot
- OpenAI/xAIのAPIキーは別々にKeychainへ保存でき、GUIで会議に使うプロバイダーを選択する
- **会議タイトルの自動生成**: Claude Code CLI (`claude -p`) — Claude の Pro / Max サブスクリプション推奨。録音停止時にのみ使用
- **システム音声の取得**: ScreenCaptureKit（macOS 標準）

> **重要**: BlackHole などの仮想オーディオデバイスは **不要** です。
> ScreenCaptureKit がシステム音声を直接キャプチャするため、オーディオルーティングの
> 設定は要りません。古い記事で BlackHole + Multi-Output Device の設定を求めるものが
> ありますが、本アプリ（ScreenCaptureKit 版）には当てはまりません。

> **注意（規約）**: 会議タイトル生成機能はユーザー自身の Claude サブスクリプションを
> Claude Code CLI 経由で使用します。[Anthropic の利用規約](https://www.anthropic.com/legal/consumer-terms)
> を確認の上、自己責任でご利用ください。MeetScribe は Anthropic / OpenAI / xAI とは無関係の
> 非公式プロジェクトです。

---

## ステップ 0: 環境の前提チェック

以下を順に確認してください。

```bash
# macOS 14 (Sonoma) 以降か
sw_vers

# Swift toolchain（Xcode Command Line Tools）があるか
swift --version || xcode-select --install

# claude CLI があるか（会議タイトル自動生成に使う。なければタイムスタンプ名にフォールバック）
which claude

# openssl のバージョン（コード署名用証明書の作成に使う）
openssl version
```

- `sw_vers` の `ProductVersion` が **14 以上**であること。13 以下なら動作しません。
- `swift --version` が失敗する場合は `xcode-select --install` をユーザーに実行してもらう。
- `claude` が見つからない場合は、会議タイトルの自動生成を使うなら
  [Claude Code 公式手順](https://docs.claude.com/en/docs/claude-code/quickstart) に従って
  インストールするようユーザーに案内する（無くてもクラッシュせず、タイムスタンプ名で保存される）。
- `openssl version` は OpenSSL 3.x 以外（LibreSSL 等、macOS 標準のもの）でも動作します。
  `scripts/setup-signing.sh` が自動でバージョンに応じたオプションを選択します。万一
  証明書の p12 作成でエラーが出た場合は、`brew install openssl@3` で OpenSSL 3.x を導入し、
  `PATH` を通してから再実行してください。

---

## ステップ 1: AI API キーの取得

OpenAIまたはxAI、少なくとも選択する側のAPIキーが必要です。両方登録して会議ごとに切り替えることもできます。

### OpenAIを使う場合

1. ブラウザで [platform.openai.com/api-keys](https://platform.openai.com/api-keys) を開く。
2. OpenAI アカウントでログイン（なければ新規登録）。
3. **「Create new secret key」** をクリックし、名前（例: `meetscribe`）を付けて作成。
4. 表示された `sk-proj-...` で始まるキーをコピーして控える（**この画面を閉じると再表示されない**）。
5. [platform.openai.com/settings/organization/billing](https://platform.openai.com/settings/organization/billing)
   で支払い方法を登録し、`gpt-realtime-whisper` と `gpt-4.1-mini` を利用できる残高があることを確認する。
   同じキーを文字起こし・セグメント整形/対訳・Copilot パネル（Catchup 要約・全体像自動更新）すべてで使う。

> コスト目安: 文字起こし単体で会議 1 時間あたり約 $0.7（マイク + システム音の 2 ストリーム並列）。
> これに加え、整形・翻訳と Copilot パネルの利用分だけ `gpt-4.1-mini` の追加費用
> （$0.40/M 入力・$1.60/M 出力）が発生する。

### xAIを使う場合

1. [xAI Console](https://console.x.ai/)を開き、APIキーを作成する。
2. 請求設定を有効にし、Grok Speech to Textと`grok-4.3`を利用できることを確認する。

> xAI Streaming STTは音声1時間あたり$0.20。マイクとシステム音声を30分ずつ送る場合、
> 文字起こし費は最大約$0.20です。整形・翻訳・Copilotのトークン料金は別途発生します。

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

成功すると `dist/MeetScribe.app` が生成されます。

- `setup-signing.sh` はコード署名用の自己署名証明書を作成し、再ビルド時に
  マイク・画面収録権限が維持されるようにします。**ログインパスワードの入力が必要**な
  ので、その旨をユーザーに伝えてください。
- ビルドに失敗する場合は [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) を参照。

---

## ステップ 3: インストール

```bash
# .app を Applications へコピー
cp -R "dist/MeetScribe.app" /Applications/

# 初回起動の Gatekeeper 警告を回避（ad-hoc 署名のため）
xattr -cr "/Applications/MeetScribe.app"

# 起動
open "/Applications/MeetScribe.app"
```

`xattr -cr` を実行しない場合、「開発元が未確認」と表示されて起動できません。
その場合はユーザーに **Applications フォルダ内のアプリを右クリック → 開く** を案内してください。

---

## ステップ 4: 権限の付与

アプリ起動後、初回セットアップ画面が表示されます。次の 2 つの権限をユーザーに付与してもらいます。

1. **マイク** — セットアップ画面の「許可する」をクリック → OS のダイアログで許可。
2. **画面収録** — 「許可する」をクリック → システム設定が開く → MeetScribe を ON →
   **アプリの再起動が必要**（画面収録権限は再起動後に有効化される）。

権限の状態はセットアップ画面の更新ボタン（↻）で再チェックできます。

---

## ステップ 5: アプリ内の設定

セットアップ画面で以下を設定します（すべて完了すると画面は自動で折り畳まれます）。

1. **AIプロバイダー** — OpenAIまたはxAIを選択。
2. **API Key** — 選択した側のキーを入力して「保存」。Keychainへプロバイダー別に保存され、
   文字起こしとCopilotパネル（整形/対訳・Catchup要約・全体像自動更新）が同じ側のキーを使います。
3. **議事録の保存先（必須）** — 「選択」で録音停止時に議事録 Markdown を書き出す
   フォルダを指定。**未設定だと録音を開始できません**。

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
sed "s|\$HOME|$HOME|g" config/com.meetscribe.agent.plist \
  > ~/Library/LaunchAgents/com.meetscribe.agent.plist
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.meetscribe.agent.plist
```

---

## トラブルシューティング

問題が起きた場合は [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) を参照してください。
代表的な症状と対処をまとめてあります。
