// E2 の修正(ensure-settings の ask 復元・results log のクラス名/0本の run・insights の空期間)を production の関数経由で固定する。

import XCTest
@testable import FTCore

final class ResultsAndSettingsRepairTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("results-settings-repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func settings() throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(".claude/settings.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// allow ごと消えた設定へ `mcp__fleetest` を足し直すなら、台帳が「提示済み」でも ask を置く。
    /// 直す前は ask が空のまま = ft_start_run / ft_services が承認なしで通る
    func testRestoringMcpAllowAlsoRestoresAsk() throws {
        try ProjectScaffold.writeClaudeSettings(packageRoot: root, toolRoot: "/tools/ft")
        try "{}".write(to: root.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        try ProjectScaffold.writeClaudeSettings(packageRoot: root, toolRoot: "/tools/ft")
        let permissions = try XCTUnwrap(try settings()["permissions"] as? [String: Any])
        XCTAssertTrue((permissions["allow"] as? [String] ?? []).contains(ProjectScaffold.mcpToolsPermission))
        XCTAssertEqual(Set(permissions["ask"] as? [String] ?? []), Set(ProjectScaffold.mcpAskPermissions))
    }

    /// 逆向き: allow が残っていて利用者が ask を外した設定へは戻さない
    func testAskRemovedByTheUserIsNotRestoredWhileAllowRemains() throws {
        try ProjectScaffold.writeClaudeSettings(packageRoot: root, toolRoot: "/tools/ft")
        var current = try settings()
        var permissions = try XCTUnwrap(current["permissions"] as? [String: Any])
        permissions["ask"] = [String]()
        current["permissions"] = permissions
        try JSONSerialization.data(withJSONObject: current)
            .write(to: root.appendingPathComponent(".claude/settings.json"))
        try ProjectScaffold.writeClaudeSettings(packageRoot: root, toolRoot: "/tools/ft")
        let after = try XCTUnwrap(try settings()["permissions"] as? [String: Any])
        XCTAssertEqual(after["ask"] as? [String] ?? [], [])
    }

    func testMissingEventsOfARunThatRanNothingSaysSo() {
        let message = ResultsLogEntries.missingEventsMessage(
            runID: "r1", interrupted: false, abortReason: nil, anyScenarioStarted: false, recordedTotal: 0)
        XCTAssertTrue(message.contains("ran no scenarios"), message)
        XCTAssertFalse(message.contains("retention"), message)
    }

    /// 逆向き: total が 0 でない/不明なら従来の文言
    func testMissingEventsWithNonzeroTotalKeepsTheOldWording() {
        for total in [nil, 3] as [Int?] {
            let message = ResultsLogEntries.missingEventsMessage(
                runID: "r1", interrupted: false, abortReason: nil, anyScenarioStarted: false, recordedTotal: total)
            XCTAssertTrue(message.contains("predates this feature"), message)
        }
    }

    func testLogScenarioFilterAcceptsAClassName() throws {
        let events = root.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        for (base, id) in [("A.S0010", "A.S0010"), ("A.S0020", "A.S0020"), ("B.S0010", "B.S0010")] {
            let record = ScenarioRunRecord(
                scenarioID: id, platform: "ios", worker: nil, passed: true,
                startedAt: "2026-09-28T00:00:00.000Z", durationMs: 1, steps: StepCountsRecord(total: 1, passed: 1))
            RunResultsStore.writeScenario(record, runDir: root, fileName: base)
            try "x".write(to: events.appendingPathComponent("\(base).ndjson"), atomically: true, encoding: .utf8)
        }
        try "x".write(to: events.appendingPathComponent(".inflight-1.ndjson"), atomically: true, encoding: .utf8)
        let byClass = ResultsLogEntries.collect(runDir: root, eventsDir: events, scenarioFilter: "A")
        XCTAssertEqual(byClass.map(\.heading), ["A.S0010", "A.S0020"])
        let exact = ResultsLogEntries.collect(runDir: root, eventsDir: events, scenarioFilter: "A.S0010")
        XCTAssertEqual(exact.map(\.heading), ["A.S0010"])
    }

    func testInsightsOfAnEmptyWindowDoesNotClaimNothingNeedsAttention() {
        XCTAssertEqual(ResultsRendering.insights([], runCount: 0), "No runs in the period — nothing was checked")
        XCTAssertEqual(ResultsRendering.insights([], runCount: 4), "Nothing needs attention")
    }
}
