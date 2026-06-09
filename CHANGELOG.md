# Changelog

すべての注目すべき変更はこのファイルに記録する。[Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に準拠。

## [1.0.0] - 2026-06-09

### 初回公開リリース

- macOS 14+ 用 SwiftUI / AppKit ネイティブアプリ
- マイク + システム音 2ストリーム独立キャプチャ
- OpenAI Realtime API (`gpt-4o-transcribe`) でリアルタイム文字起こし
- Voice Processing (AEC + AGC + ノイズ抑制) によるオンライン会議2重記録防止
- `voiceProcessingOtherAudioDuckingConfiguration` (macOS 14+) でシステム音 ducking を最小化
- Claude Code CLI 経由の会議中 Q&A (Claude Max サブスク活用)
- ユーザー指定の知識源フォルダを `--add-dir` で動的渡し、Glob/Grep/Read で参照
- フローティング小窓 (NSWindow.level = .floating、ScreenCaptureKit から不可視)
- 議事録 Markdown 自動保存 (タイトル Claude 自動生成)
- HSplitView で左右カラム幅をドラッグリサイズ可能
- バッテリー軽量化: VU レベル更新 100ms throttle、権限再チェック 30秒 throttle
