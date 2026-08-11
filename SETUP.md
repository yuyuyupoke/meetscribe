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
- **会議タイトルの自動生成**: 選択中の AI プロバイダー（追加のセットアップ不要）
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

# openssl のバージョン（コード署名用証明書の作成に使う）
openssl version
```

- `sw_vers` の `ProductVersion` が **14 以上**であること。13 以下なら動作しません。
- `swift --version` が失敗する場合は `xcode-select --install` をユーザーに実行してもらう。
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

> コスト目安: 文字起こしは 2 ストリーム並列のため会議 1 時間あたり最大約 $2。
> 実運用では無音送信の抑制が効くため実測はこれより低く、整形・対訳・Copilot の
> トークン料金まで含めて **1 時間あたり $0.9〜1.2** 程度になる（xAI 経路の約3倍）。

### xAIを使う場合

1. [xAI Console](https://console.x.ai/)を開き、APIキーを作成する。
2. 請求設定を有効にし、Grok Speech to Textと`grok-4.3`を利用できることを確認する。

> xAI Streaming STT は音声 1 時間あたり $0.20（無音は送らないので、請求対象の音声は
> 会議時間より短くなる）。これに整形・対訳・Copilot のトークン料金が加わり、
> 2026-08 の実測では **1 時間の講義で約 $0.36**（1分あたり $0.0059、xAI が返す実請求額
> ベース）。アプリのヘッダーに会議ごとの実費が表示される。

取得したキーは後のステップ 6 でアプリに設定します。AI はキーの値をログや
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

# 起動
open "/Applications/MeetScribe.app"
```

> **この手順では Gatekeeper の警告は出ません。** 「開発元を確認できません」は
> インターネットからダウンロードしたファイルに付く検疫属性 (`com.apple.quarantine`)
> に対して出るものです。自分のマシンでビルドした `.app` にはこの属性が付かないため、
> そのまま起動できます（配布 DMG を落とした場合のみ許可の手順が必要です）。
>
> 万一 zip などを経由して検疫属性が付いてしまった場合のみ、次で解除できます。
> ```bash
> xattr -cr "/Applications/MeetScribe.app"
> ```

---

## ステップ 4: 初回起動時の説明への同意

アプリを初めて起動すると「**ご利用の前に**」という画面が表示されます。
内容をユーザーに読んでもらい、**「同意して始める」** をクリックしてもらってください。

説明されるのは次の4点です。AI が代わりに同意してはいけません（利用者本人の判断が必要です）。

- 音声（マイク＋Macが再生している音声）が、利用者自身の API キーで OpenAI / xAI へ送信されること
- 開発者はサーバーを持たず、会議のデータを一切受け取らないこと
- 会議参加者への録音の告知は利用者の責任であること
- AI の利用料は利用者の負担になること

同意するまで録音は開始できません。詳細は [PRIVACY.md](PRIVACY.md) にまとまっています。

---

## ステップ 5: 権限の付与

次の 2 つの権限をユーザーに付与してもらいます。

1. **マイク** — セットアップ画面の「許可する」をクリック → OS のダイアログで許可。
2. **画面収録** — 「許可する」をクリック → システム設定が開く → MeetScribe を ON →
   **アプリの再起動が必要**（画面収録権限は再起動後に有効化される）。

権限の状態はセットアップ画面の更新ボタン（↻）で再チェックできます。

---

## ステップ 6: アプリ内の設定

セットアップ画面で以下を設定します（すべて完了すると画面は自動で折り畳まれます）。

1. **AIプロバイダー** — OpenAIまたはxAIを選択。
2. **API Key** — 選択した側のキーを入力して「保存」。Keychainへプロバイダー別に保存され、
   文字起こしとCopilotパネル（整形/対訳・Catchup要約・全体像自動更新）が同じ側のキーを使います。
3. **議事録の保存先（必須）** — 「選択」で録音停止時に議事録 Markdown を書き出す
   フォルダを指定。**未設定だと録音を開始できません**。

---

## ステップ 7: 動作確認

1. ヘッダー右の録音ボタン（⏺）をクリック。
2. 何か話す、または音声付きの動画を再生する。
3. 左カラムに `[自分]`（マイク）/ `[相手]`（システム音）のラベル付きで
   文字起こしがリアルタイム表示されることを確認。
4. ヘッダーの停止ボタン（⏹）で録音終了 → タイトルが自動生成され、
   ステップ 6 で指定したフォルダに `YYYY-MM-DD_HH-mm_<タイトル>.md` が保存される。

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
