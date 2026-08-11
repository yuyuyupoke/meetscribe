import XCTest
@testable import MeetScribeCore

/// DebugLog のファイル出力可否の解決ロジック。
///
/// 目的は「`swift test` の出力が本番ログ (`~/Library/Logs/MeetScribe/meetscribe.log`) に
/// 混ざらないこと」。2026-08-11 のコスト分析では、テストが出したログが混入して
/// cleaner のパース失敗件数を3倍に見誤っていた。
final class DebugLogTests: XCTestCase {

    private let suiteName = "com.meetscribe.tests.debuglog"

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// **本テストプロセス自身**がテストとして検出されること (これが本命の不変条件)。
    func test_detectRunningTests_isTrueInsideTestProcess() {
        XCTAssertTrue(DebugLog.detectRunningTests())
    }

    /// 上書き設定が無ければ、テスト中はファイルに書かない。
    func test_resolve_defaultDuringTests_doesNotWriteToFile() {
        XCTAssertFalse(DebugLog.resolveWritesToFile(
            environment: [:], defaults: nil, isRunningTests: true
        ))
    }

    /// **本番実行では必ず書く** (止まると障害調査ができない)。
    func test_resolve_defaultInProduction_writesToFile() {
        XCTAssertTrue(DebugLog.resolveWritesToFile(
            environment: [:], defaults: nil, isRunningTests: false
        ))
    }

    /// 環境変数が最優先 (テスト中でも強制的に有効化できる)。
    func test_resolve_environmentOverride_wins() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: DebugLog.userDefaultsKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(DebugLog.resolveWritesToFile(
            environment: [DebugLog.environmentKey: "1"],
            defaults: defaults,
            isRunningTests: true
        ))
        XCTAssertFalse(DebugLog.resolveWritesToFile(
            environment: [DebugLog.environmentKey: "0"],
            defaults: defaults,
            isRunningTests: false
        ))
    }

    /// GUI 起動でも効く恒久設定 (env が届かないため併設が必須)。
    func test_resolve_userDefaultsOverride_appliesWhenEnvironmentAbsent() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: DebugLog.userDefaultsKey)
        XCTAssertTrue(DebugLog.resolveWritesToFile(
            environment: [:], defaults: defaults, isRunningTests: true
        ))

        defaults.set(false, forKey: DebugLog.userDefaultsKey)
        XCTAssertFalse(DebugLog.resolveWritesToFile(
            environment: [:], defaults: defaults, isRunningTests: false
        ))
    }

    /// 未知の値は「指定なし」として扱い、既定へ落ちる (破損した設定で本番ログを止めない)。
    func test_resolve_unknownValues_fallBackToDefault() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("maybe", forKey: DebugLog.userDefaultsKey)

        XCTAssertTrue(DebugLog.resolveWritesToFile(
            environment: [DebugLog.environmentKey: "perhaps"],
            defaults: defaults,
            isRunningTests: false
        ))
    }
}
