// 結果の注記の書式を揃える: 所要の悪化の機械名はそのシナリオの記録で決める(deviceBias と同じ単位)・名前の一覧の上限は1箇所

import XCTest
@testable import FTCore

final class ResultsListingConsistencyTests: XCTestCase {
    private func record(_ scenario: String, day: Int, durationMs: Int, host: String) -> ScenarioRunRecord {
        ScenarioRunRecord(
            runID: "r\(day)", scenarioID: scenario, platform: "ios", worker: nil, host: host,
            passed: true, startedAt: String(format: "2026-03-%02dT00:00:00Z", day), durationMs: durationMs,
            steps: StepCountsRecord(total: 1, passed: 1, failed: 0))
    }

    /// Foo.a は m2 でしか回っていない = 別のシナリオが m1 で回っていても、Foo.a の行に機械名を付けない
    func testDurationRegressionNamesTheMachineOnlyWhenThatScenarioSpansMachines() throws {
        let grown = (1...4).map { record("Foo.a", day: $0, durationMs: $0 <= 2 ? 100 : 300, host: "m2") }
        let other = (1...4).map { record("Bar.b", day: $0, durationMs: 100, host: "m1") }
        let row = try XCTUnwrap(RunResultsQuery.insights(records: grown + other, runs: [])
            .first { $0.kind == "durationRegression" })
        XCTAssertTrue(row.message.hasPrefix("Foo.a [ios]: duration regressed"), row.message)
    }

    /// スキップの合成記録(別の機械で書かれた埋め合わせ)は、機械名を付けるかの判定に数えない(slowTests と同じ記録で数える)
    func testSkippedPlaceholderOnAnotherHostDoesNotAddTheMachineName() throws {
        let grown = (1...4).map { record("Foo.a", day: $0, durationMs: $0 <= 2 ? 100 : 300, host: "m2") }
        let placeholder = ScenarioRunRecord(
            runID: "r9", scenarioID: "Foo.a", platform: "ios", worker: nil, host: "m1", passed: true,
            startedAt: "2026-03-09T00:00:00Z", durationMs: 0, steps: StepCountsRecord(total: 1, skipped: 1))
        let row = try XCTUnwrap(RunResultsQuery.insights(records: grown + [placeholder], runs: [])
            .first { $0.kind == "durationRegression" })
        XCTAssertTrue(row.message.hasPrefix("Foo.a [ios]: duration regressed"), row.message)
    }

    /// 同じシナリオが2台の機械で悪化した行は並べ替えの鍵が機械名まで同じ = 機械名で並びを決め切る
    func testRowsForTheSameScenarioOnTwoMachinesHaveAFixedOrder() {
        let onM2 = (1...4).map { record("Foo.a", day: $0, durationMs: $0 <= 2 ? 100 : 300, host: "m2") }
        let onM1 = (1...4).map { record("Foo.a", day: $0 + 10, durationMs: $0 <= 2 ? 100 : 300, host: "m1") }
        let hosts = RunResultsQuery.insights(records: onM2 + onM1, runs: [])
            .filter { $0.kind == "durationRegression" }.map(\.host)
        XCTAssertEqual(hosts, ["m1", "m2"])
    }

    /// 推移の一覧は打ち切ったら総数を言う(呼び手の文面は数を持たない)
    func testTrendListingStatesTheTotalWhenCut() throws {
        let ids = (1...12).map { "Cart.m\(String(format: "%02d", $0))" }
        let listing = try XCTUnwrap(RunResultsQuery.trendClassMemberListing(selector: "Cart", scenarioIDs: ids))
        XCTAssertTrue(listing.hasSuffix(", ... (12 in all)"), listing)
        XCTAssertEqual(RunResultsQuery.trendClassMemberListing(selector: "Cart", scenarioIDs: ["Cart.a"]), "Cart.a")
    }

    /// 既定値はリテラルで固定する(他のテストは記号で参照するので、値を変えても素通りする)
    func testNameListingLimitIsPinned() {
        XCTAssertEqual(NameListing.limit, 5)
    }

    func testNameListingCapsAtTheSharedLimit() {
        let names = (1...(NameListing.limit + 2)).map { "S\($0)" }
        XCTAssertEqual(NameListing.joined(names), "S1, S2, S3, S4, S5, ...")
        XCTAssertEqual(NameListing.joined(["A", "B"]), "A, B")
    }
}
