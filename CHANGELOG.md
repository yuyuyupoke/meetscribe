# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[1.0.0]: https://github.com/yuyuyupoke/clawd-listen/releases/tag/v1.0.0
