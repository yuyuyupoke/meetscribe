# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- OpenAIとxAIのAPIキーをKeychainへ個別保存し、設定GUIからプロバイダーを選択可能にした
- xAI Grok Speech to TextのStreaming WebSocket（16kHz PCM、partial/final対応）を追加
- xAI選択時は整形・日本語対訳・Catchup・全体像生成を`grok-4.3`へ統一
- 議事録frontmatterへ`provider`と`assistantModel`を記録

### Changed

- プロバイダー選択を会議開始時に固定し、自動再接続でも同じAPIキー・モデルを使用
- xAI Streaming STTの送信音声秒数に基づくコスト表示を追加

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
