import XCTest
@testable import FTCore

/// results の集計の鍵: summary / flaky は (scenarioID, platform)、devices / deviceBias は (host, worker)、
/// durationRegression は機械ごと。--since の範囲と --scenario のクラス名。
final class ResultsGroupingKeysTests: XCTestCase {

    private func record(_ scenario: String, platform: String = "ios", passed: Bool, day: Int, durationMs: Int = 100,
                        worker: String? = nil, host: String = "m1") -> ScenarioRunRecord {
        ScenarioRunRecord(
            runID: "r\(day)", scenarioID: scenario, platform: platform, worker: worker, host: host,
            passed: passed, startedAt: String(format: "2026-03-%02dT00:00:00Z", day), durationMs: durationMs,
            steps: StepCountsRecord(total: 1, passed: passed ? 1 : 0, failed: passed ? 0 : 1))
    }

    /// iOS は毎回失敗・Android は毎回成功。OS ごとには決定的なので、フレークでも 50% でもない
    private func osSplitRecords() -> [ScenarioRunRecord] {
        (1...6).flatMap { day in
            [record("Cart.add", platform: "ios", passed: false, day: day),
             record("Cart.add", platform: "android", passed: true, day: day)]
        }
    }

    func testSummarySeparatesPlatforms() {
        let rows = RunResultsQuery.scenarioSummary(osSplitRecords(), recentRuns: .max)
        XCTAssertEqual(rows.map(\.platform), ["ios", "android"], "成功率の低い行が先")
        XCTAssertEqual(rows.map(\.successRate), [0, 100])
        XCTAssertEqual(rows.map(\.runs), [6, 6])
    }

    func testFlakyDoesNotMixPlatforms() {
        XCTAssertTrue(RunResultsQuery.flakyScenarios(osSplitRecords(), minRuns: 5, recentRuns: .max).isEmpty,
                      "OS ごとには決定的なシナリオをフレークに並べない")
        let flipping = (1...6).map { record("Cart.add", platform: "android", passed: $0 % 2 == 0, day: $0) }
        let rows = RunResultsQuery.flakyScenarios(osSplitRecords() + flipping, minRuns: 5, recentRuns: .max)
        XCTAssertEqual(rows.map(\.platform), ["android"])
    }

    func testDevicesKeyIncludesTheMachine() {
        let records = [record("A.a", passed: true, day: 1, worker: "ios:iPhone", host: "m1"),
                       record("A.a", passed: false, day: 2, worker: "ios:iPhone", host: "m2")]
        let rows = RunResultsQuery.deviceSummary(records).byWorker
        XCTAssertEqual(rows.map(\.host), ["m1", "m2"])
        XCTAssertEqual(rows.map(\.runs), [1, 1])
        XCTAssertEqual(rows.map(\.successRate), [100, 0])
    }

    func testDeviceBiasSeparatesSameNamedDevicesOnDifferentMachines() throws {
        // 同名の ios:A が m1 では 12 run 中 8 敗・m2 では 20 run 全通。worker だけで束ねると1種類で判定不能
        let m1 = (0..<12).map { record("Foo.a", passed: $0 >= 8, day: $0 + 1, worker: "ios:A", host: "m1") }
        let m2 = (0..<20).map { record("Foo.a", passed: true, day: 13 + $0 % 15, worker: "ios:A", host: "m2") }
        let rows = RunResultsQuery.insights(records: m1 + m2, runs: [])
        let row = try XCTUnwrap(rows.first { $0.kind == "deviceBias" })
        XCTAssertEqual(row.worker, "ios:A")
        XCTAssertEqual(row.host, "m1", "同名のデバイスの行をマシンで見分けられない")
        XCTAssertEqual(row.message, "Foo.a [ios]: failures cluster on ios:A on m1 (its failure rate is 67% vs overall 25%)")
    }

    func testDurationRegressionComparesOneMachineAtATime() {
        // m1 は常に 100ms(古い側)・m2 は常に 300ms(新しい側)。混ぜると前半 100 → 後半 300 の悪化に見える
        let fast = (1...4).map { record("Foo.a", passed: true, day: $0, durationMs: 100, host: "m1") }
        let slow = (5...8).map { record("Foo.a", passed: true, day: $0, durationMs: 300, host: "m2") }
        let rows = RunResultsQuery.insights(records: fast + slow, runs: [])
        XCTAssertFalse(rows.contains { $0.kind == "durationRegression" })

        // 同じ機械の中で本当に伸びていれば出る・複数の機械があるので機械名が付く
        let grown = (1...4).map { record("Foo.a", passed: true, day: $0, durationMs: $0 <= 2 ? 100 : 300, host: "m2") }
        let regressed = RunResultsQuery.insights(records: fast + grown, runs: [])
            .filter { $0.kind == "durationRegression" }
        XCTAssertEqual(regressed.count, 1)
        XCTAssertTrue(regressed[0].message.hasPrefix("Foo.a [ios] on m2: duration regressed"), regressed[0].message)
        XCTAssertEqual(regressed[0].host, "m2")
    }

    func testScenarioSelectorAcceptsClassNames() {
        XCTAssertTrue(ScenarioSelection.selects("Cart.add", scenarioID: "Cart.add"))
        XCTAssertTrue(ScenarioSelection.selects("Cart", scenarioID: "Cart.add"))
        XCTAssertFalse(ScenarioSelection.selects("Cart", scenarioID: "Cartoon.add"))
        XCTAssertFalse(ScenarioSelection.selects("Cart.ad", scenarioID: "Cart.add"))
    }

    func testTrendBarsAreScaledPerPlatform() {
        let rows = [record("Cart.add", platform: "ios", passed: true, day: 1, durationMs: 10),
                    record("Cart.add", platform: "android", passed: true, day: 2, durationMs: 1000)]
        let out = ResultsRendering.trend(rows, scenario: "Cart.add").components(separatedBy: "\n")
        XCTAssertTrue(out[2].hasSuffix(String(repeating: "█", count: 20)), "ios の最大は ios の中で 20 文字: \(out[2])")
    }

    // MARK: - --since の範囲

    func testTimeBoundRejectsDatesBeforeYearOneAndAfter9999() {
        XCTAssertNil(TimeBoundParse.parse("1500000d"), "紀元前へ届く相対期間は窓を空にするので断る")
        XCTAssertNil(TimeBoundParse.parse("@-70000000000"))
        XCTAssertNil(TimeBoundParse.parse("@300000000000"))
        XCTAssertNotNil(TimeBoundParse.parse("700000d"))
    }

    /// クラス名の照合は `ScenarioSelection` の1か所(run と results で同じ集合を選ぶ)。名前の途中では切らない
    func testClassSelectorMatchesOnlyWholeClassNames() {
        XCTAssertTrue(ScenarioSelection.selects("A", scenarioID: "A.m"))
        XCTAssertTrue(ScenarioSelection.selects("A.m", scenarioID: "A.m"))
        XCTAssertFalse(ScenarioSelection.selects("A", scenarioID: "AB.m"))
        XCTAssertFalse(ScenarioSelection.selects("A", scenarioID: "AB.m"))
    }

    /// trend にクラス名を渡したときの候補の列挙は CLI と MCP が共有する(重複なし・名前順・5件まで + ...)
    func testTrendClassMemberListingIsSortedUniqueAndCapped() {
        let ids = ["C.f", "C.a", "C.b", "C.a", "C.c", "C.d", "C.e", "D.x"]
        XCTAssertEqual(RunResultsQuery.trendClassMemberListing(selector: "C", scenarioIDs: ids),
                       "C.a, C.b, C.c, C.d, C.e, ... (6 in all)")
        XCTAssertNil(RunResultsQuery.trendClassMemberListing(selector: "Z", scenarioIDs: ids))
    }
}
