import XCTest
@testable import FTCore

/// 人のライブ操作の台帳(`HumanOperationLedger`)・結果への載せ方・レポートの節。置き場は毎回一時フォルダ(並列テストで共有しない)
final class HumanOperationLedgerTests: XCTestCase {
    private var stateDir: URL!
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-human-ops-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: stateDir)
    }

    private func entry(_ offset: TimeInterval, _ label: String, ok: Bool = true) -> HumanOperationRecord {
        HumanOperationRecord(at: base.addingTimeInterval(offset), label: label, ok: ok)
    }

    private func append(_ record: HumanOperationRecord, key: String = "UDID-1", now: Date? = nil) {
        HumanOperationLedger.append(stateDir: stateDir, key: key, entry: record,
                                    now: now ?? record.date ?? base)
    }

    // MARK: - 追記と窓

    func testEntriesReturnsOnlyRowsInsideTheWindowInclusiveInTimeOrder() {
        append(entry(10, "tap (1, 2)"))
        append(entry(30, "swipe up"))
        append(entry(20, "home"))
        append(entry(50, "back"))
        let rows = HumanOperationLedger.entries(
            stateDir: stateDir, key: "UDID-1", from: base.addingTimeInterval(20), to: base.addingTimeInterval(30))
        XCTAssertEqual(rows.map(\.label), ["home", "swipe up"], "両端を含み、窓の外は載せない。順は時刻順")
    }

    func testEntriesAreSeparatedByKey() {
        append(entry(1, "tap (1, 2)"), key: "UDID-1")
        append(entry(2, "home"), key: "UDID-2")
        let rows = HumanOperationLedger.entries(stateDir: stateDir, key: "UDID-2", from: base, to: base.addingTimeInterval(100))
        XCTAssertEqual(rows.map(\.label), ["home"])
    }

    func testMissingLedgerReadsAsEmpty() {
        XCTAssertEqual(HumanOperationLedger.entries(stateDir: stateDir, key: "none", from: base, to: base), [])
    }

    func testFailedOperationIsKeptWithOkFalse() {
        append(entry(1, "tap (1, 2)", ok: false))
        let rows = HumanOperationLedger.entries(stateDir: stateDir, key: "UDID-1", from: base, to: base.addingTimeInterval(5))
        XCTAssertEqual(rows.map(\.ok), [false])
    }

    func testBrokenLinesAreSkipped() throws {
        append(entry(1, "tap (1, 2)"))
        let url = HumanOperationLedger.fileURL(stateDir: stateDir, key: "UDID-1")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n{\"at\":\"x\",\"label\":\"bad time\",\"ok\":true}\n".utf8))
        try handle.close()
        append(entry(2, "home"))
        let rows = HumanOperationLedger.entries(stateDir: stateDir, key: "UDID-1", from: base, to: base.addingTimeInterval(5))
        XCTAssertEqual(rows.map(\.label), ["tap (1, 2)", "home"])
    }

    /// 書き込みの途中で死んだ半端な末尾は切り戻され、次の行と連結して読めなくならない
    func testHalfWrittenTailDoesNotSwallowTheNextRow() throws {
        append(entry(1, "tap (1, 2)"))
        let url = HumanOperationLedger.fileURL(stateDir: stateDir, key: "UDID-1")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"at\":\"2027".utf8))
        try handle.close()
        append(entry(2, "home"))
        let rows = HumanOperationLedger.entries(stateDir: stateDir, key: "UDID-1", from: base, to: base.addingTimeInterval(5))
        XCTAssertEqual(rows.map(\.label), ["tap (1, 2)", "home"])
    }

    // MARK: - 間引き

    func testAppendDropsRowsOlderThanRetentionButKeepsFresherOnes() {
        let retention = HumanOperationLedger.retentionSeconds
        append(entry(0, "old"))
        append(entry(retention - 1, "mid"))
        append(entry(retention + 5, "fresh"))
        let rows = HumanOperationLedger.entries(stateDir: stateDir, key: "UDID-1",
                                                from: base, to: base.addingTimeInterval(retention * 2))
        XCTAssertEqual(rows.map(\.label), ["mid", "fresh"], "保持期間より古い行だけが追記のついでに消える")
    }

    func testPrunedReturnsNilWhenNothingIsOld() {
        let rows = HumanOperationLedger.decode(HumanOperationLedger.encodeLine(entry(0, "a"))!)
        XCTAssertNil(HumanOperationLedger.pruned(rows, now: base.addingTimeInterval(1)))
    }

    func testPrunedBoundaryIsExactlyRetention() {
        let rows = HumanOperationLedger.decode(HumanOperationLedger.encodeLine(entry(0, "a"))!)
        let atEdge = base.addingTimeInterval(HumanOperationLedger.retentionSeconds)
        XCTAssertNil(HumanOperationLedger.pruned(rows, now: atEdge), "ちょうど保持期間の行は残す")
        XCTAssertEqual(HumanOperationLedger.pruned(rows, now: atEdge.addingTimeInterval(0.01))?.count, 0)
    }

    func testRetentionIsPinned() {
        XCTAssertEqual(HumanOperationLedger.retentionSeconds, 24 * 3600)
    }

    func testKeyWithSlashStaysInsideTheLedgerDirectory() {
        let url = HumanOperationLedger.fileURL(stateDir: stateDir, key: "a/b")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, HumanOperationLedger.directoryName)
    }

    // MARK: - 結果 JSON

    private func record(humanOperations: [HumanOperationRecord]?) -> ScenarioRunRecord {
        ScenarioRunRecord(scenarioID: "A.b", platform: "ios", passed: true, startedAt: "2027-01-01T00:00:00Z",
                          durationMs: 1, steps: StepCountsRecord(), humanOperations: humanOperations)
    }

    func testHumanOperationsAreOmittedWhenEmptyAndRoundTripWhenPresent() throws {
        let builder = ScenarioRecordBuilder(scenarioID: "A.b", platform: "ios", title: nil, worker: nil, mode: nil)
        let none = builder.build(passed: true, timedOut: false, startedAt: base, durationMs: 1, packageRoot: nil)
        XCTAssertNil(none.humanOperations, "空なら欄ごと省く")
        let json = try String(decoding: JSONEncoder().encode(none), as: UTF8.self)
        XCTAssertFalse(json.contains("humanOperations"))

        let ops = [entry(1, "tap (1, 2)"), entry(2, "type (6 characters)", ok: false)]
        let with = builder.build(passed: false, timedOut: false, startedAt: base, durationMs: 1, packageRoot: nil,
                                 humanOperations: ops)
        let decoded = try JSONDecoder().decode(ScenarioRunRecord.self, from: JSONEncoder().encode(with))
        XCTAssertEqual(decoded.humanOperations, ops)
    }

    /// 欄が無い古い記録は読める(必須化しない)
    func testOldJSONWithoutTheFieldStillDecodes() throws {
        let data = try JSONEncoder().encode(record(humanOperations: nil))
        XCTAssertNil(try JSONDecoder().decode(ScenarioRunRecord.self, from: data).humanOperations)
    }

    // MARK: - Markdown

    func testReportSectionListsLocalTimeAndMarksFailures() throws {
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 9 * 3600))
        let ops = [entry(0, "tap (120, 340)"), entry(1.5, "swipe up", ok: false)]
        let markdown = try XCTUnwrap(HumanOperationReport.appending(markdown: "# Report\n- ✅ 1. tap\n", operations: ops, timeZone: zone))
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = zone
        local.dateFormat = "HH:mm:ss.SSS"
        XCTAssertTrue(markdown.hasPrefix("# Report\n- ✅ 1. tap\n\n## Human operations\n\n"))
        XCTAssertTrue(markdown.contains("- \(local.string(from: base)) tap (120, 340)\n"))
        XCTAssertTrue(markdown.contains("- \(local.string(from: base.addingTimeInterval(1.5))) ✗ swipe up\n"))
    }

    func testReportIsNotTouchedWhenThereIsNothingToAddOrSectionExists() {
        XCTAssertNil(HumanOperationReport.appending(markdown: "# R\n", operations: []))
        let once = HumanOperationReport.appending(markdown: "# R\n", operations: [entry(0, "home")])
        XCTAssertNotNil(once)
        XCTAssertNil(HumanOperationReport.appending(markdown: once ?? "", operations: [entry(0, "home")]), "二重に足さない")
    }

    func testPatchWritesTheFileAndReportsUnreadableOnes() throws {
        let file = stateDir.appendingPathComponent("scenario.md")
        try "# R\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNil(HumanOperationReport.patch(reportPath: file.path, packageRoot: nil, operations: [entry(0, "home")]))
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("## Human operations"))
        XCTAssertNotNil(HumanOperationReport.patch(reportPath: stateDir.appendingPathComponent("missing.md").path,
                                                   packageRoot: nil, operations: [entry(0, "home")]),
                        "読めないレポートは黙らず理由を返す")
        XCTAssertNil(HumanOperationReport.patch(reportPath: nil, packageRoot: nil, operations: [entry(0, "home")]))
        XCTAssertNil(HumanOperationReport.patch(reportPath: file.path, packageRoot: nil, operations: []))
    }
}
