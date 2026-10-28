// 他人・CLI・リモートの run のログを実行ログビューへ流す読み手(RunLogTailer / monitorRunLog)の検証。
// 守るもの: ①先頭から読む ②追記ぶんだけ読む ③行の途中で切れたら持ち越す ④rename 後も同じ fd で読める
// ⑤参照が消え、読み切ってから閉じる ⑥整形は ScenarioLogFormatter 経由・stderr/text は素通し
// ⑦**件数で打ち切らない** ⑧台帳が指す任意のファイルは開かない。ファイルは一時ディレクトリ(共有資源ではない)

import XCTest
import FTCore
@testable import fleetest

final class ApiMonitorRunLogTests: XCTestCase {

    private var root: URL!
    private var eventsDir: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApiMonitorRunLogTests-\(UUID().uuidString)", isDirectory: true)
        eventsDir = root.appendingPathComponent("events", isDirectory: true)
        try? FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func newLogPath() -> String {
        eventsDir.appendingPathComponent(".inflight-\(UUID().uuidString).ndjson").path
    }

    private func append(_ text: String, to path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func record(pid: Int32 = 100, owner: String? = "host:1", eventLog: String?,
                        laneName: String = "iPhone 17-01", platform: String? = "ios",
                        lanes extra: [RunProgressLane] = []) -> RunProgressRecord {
        let lane = RunProgressLane(key: "K", name: laneName, platform: platform, scenario: eventLog == nil ? nil : "S",
                                   scenarioStartedAt: nil, expectedSeconds: nil, eventLog: eventLog)
        return RunProgressRecord(pid: pid, runID: "r1", runGroup: nil, issuer: nil, project: "p", profile: nil,
                                 startedAt: "2026-09-20T10:00:00Z", total: 1, done: 0, failed: 0, actions: 0,
                                 requeued: 0, laneDropouts: 0, etaSeconds: nil, lanes: [lane] + extra,
                                 phase: "running", supply: [], videoClips: nil, owner: owner)
    }

    private func stdoutLine(_ eventJSON: String) -> String {
        #"{"t":"2026-09-20T10:00:00.000Z","stream":"stdout","event":\#(eventJSON)}"# + "\n"
    }

    private func textLine(stream: String, _ text: String) -> String {
        #"{"t":"2026-09-20T10:00:00.000Z","stream":"\#(stream)","text":"\#(text)"}"# + "\n"
    }

    // MARK: - pure

    func testSplitCarriesAPartialLineAndCompletesItNextTime() {
        let first = RunLogTailer.split(carry: Data(), chunk: Data("aaa\nbb".utf8))
        XCTAssertEqual(first.complete.map { String(decoding: $0, as: UTF8.self) }, ["aaa"])
        XCTAssertEqual(String(decoding: first.carry, as: UTF8.self), "bb")
        let second = RunLogTailer.split(carry: first.carry, chunk: Data("b\ncc\n".utf8))
        XCTAssertEqual(second.complete.map { String(decoding: $0, as: UTF8.self) }, ["bbb", "cc"])
        XCTAssertTrue(second.carry.isEmpty)
    }

    func testDisplayLinesFormatsEventsThroughScenarioLogFormatter() {
        let raw = #"{"t":"x","stream":"stdout","event":{"kind":"scenarioStarted","scenario":"05_検索","title":"検索"}}"#
        var expected = ScenarioEvent(kind: "scenarioStarted")
        expected.scenario = "05_検索"
        expected.title = "検索"
        XCTAssertEqual(RunLogTailer.displayLines(rawLine: raw), ScenarioLogFormatter.lines(for: expected))
        XCTAssertEqual(RunLogTailer.displayLines(rawLine: raw), ["▶ 05_検索 — 検索"])
    }

    func testDisplayLinesPassesStderrAndTextThroughVerbatim() {
        XCTAssertEqual(RunLogTailer.displayLines(
            rawLine: #"{"t":"x","stream":"stderr","text":"boom: failed"}"#), ["boom: failed"])
        XCTAssertEqual(RunLogTailer.displayLines(
            rawLine: #"{"t":"x","stream":"stdout","text":"plain child output"}"#), ["plain child output"])
        XCTAssertEqual(RunLogTailer.displayLines(rawLine: "not json at all"), ["not json at all"],
                       "読めない行は原文を出す(黙って捨てない)")
    }

    func testReferencesBuildDeviceIDAndInferPlatformOnlyWhenUnambiguous() {
        let path = "/tmp/x/events/.inflight-A.ndjson"
        let named = RunLogTailer.references(records: [record(eventLog: path)])
        XCTAssertEqual(named[path], RunLogTailer.Meta(device: "ios:iPhone 17-01", runID: "r1", pid: 100, owner: "host:1"))
        let sibling = RunProgressLane(key: "K2", name: "iPhone 17-02", platform: "ios", scenario: nil,
                                      scenarioStartedAt: nil, expectedSeconds: nil)
        XCTAssertEqual(RunLogTailer.references(records: [record(eventLog: path, platform: nil, lanes: [sibling])])[path]?.device,
                       "ios:iPhone 17-01", "他の lane の platform が1種類ならそれで推せる")
        XCTAssertNil(RunLogTailer.references(records: [record(eventLog: path, platform: nil)])[path],
                     "推せないときは出さない")
    }

    func testOnlyInflightEventLogPathsAreOpenable() {
        XCTAssertTrue(RunLogTailer.isEventLogPath("/r/events/.inflight-A.ndjson"))
        XCTAssertFalse(RunLogTailer.isEventLogPath("/etc/passwd"))
        XCTAssertFalse(RunLogTailer.isEventLogPath("/r/events/scenario.ndjson"))
        XCTAssertFalse(RunLogTailer.isEventLogPath("/r/other/.inflight-A.ndjson"))
        XCTAssertFalse(RunLogTailer.isEventLogPath("events/.inflight-A.ndjson"))
    }

    // MARK: - tail

    func testReadsFromTheStartThenOnlyWhatWasAppended() throws {
        let path = newLogPath()
        try append(textLine(stream: "stderr", "one"), to: path)
        let tailer = RunLogTailer()
        let rec = record(eventLog: path)
        let first = tailer.poll(records: [rec])
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].lines, ["one"], "後から開いても先頭から出す")
        XCTAssertEqual(first[0].device, "ios:iPhone 17-01")
        XCTAssertEqual(first[0].pid, 100)
        XCTAssertEqual(first[0].owner, "host:1")
        XCTAssertNil(first[0].machine)
        XCTAssertTrue(tailer.poll(records: [rec]).isEmpty, "増えていなければ何も出さない")
        try append(textLine(stream: "stderr", "two"), to: path)
        XCTAssertEqual(tailer.poll(records: [rec]).first?.lines, ["two"], "追記ぶんだけ")
    }

    func testPartialLineIsCarriedToTheNextPoll() throws {
        let path = newLogPath()
        let full = textLine(stream: "stderr", "split me")
        let cut = full.index(full.startIndex, offsetBy: 20)
        try append(String(full[..<cut]), to: path)
        let tailer = RunLogTailer()
        let rec = record(eventLog: path)
        XCTAssertTrue(tailer.poll(records: [rec]).isEmpty)
        try append(String(full[cut...]), to: path)
        XCTAssertEqual(tailer.poll(records: [rec]).first?.lines, ["split me"])
    }

    func testKeepsReadingAfterTheInflightFileIsRenamed() throws {
        let path = newLogPath()
        try append(textLine(stream: "stderr", "before"), to: path)
        let tailer = RunLogTailer()
        let rec = record(eventLog: path)
        XCTAssertEqual(tailer.poll(records: [rec]).first?.lines, ["before"])
        try FileManager.default.moveItem(atPath: path, toPath: eventsDir.appendingPathComponent("final.ndjson").path)
        // rename 後に書き手が書く(finish は fd を閉じた後に rename するので実際は無いが、同じ inode を読めることの確認)
        try append(textLine(stream: "stderr", "after"), to: eventsDir.appendingPathComponent("final.ndjson").path)
        XCTAssertEqual(tailer.poll(records: [rec]).first?.lines, ["after"])
    }

    func testDrainsThenClosesOnlyAfterTheReferenceIsGone() throws {
        let path = newLogPath()
        try append(textLine(stream: "stderr", "last"), to: path)
        let tailer = RunLogTailer()
        _ = tailer.poll(records: [record(eventLog: path)])
        XCTAssertEqual(tailer.trackedPaths, [path])
        try append(textLine(stream: "stderr", "tail end"), to: path)
        // 参照が消えた周期でも、増分があれば読み切って出す(まだ閉じない)
        let drained = tailer.poll(records: [record(eventLog: nil)])
        XCTAssertEqual(drained.first?.lines, ["tail end"])
        XCTAssertEqual(tailer.trackedPaths, [path], "増分が0になるまで閉じない")
        XCTAssertTrue(tailer.poll(records: [record(eventLog: nil)]).isEmpty)
        XCTAssertTrue(tailer.trackedPaths.isEmpty, "参照なし + 増分0 で閉じる")
    }

    func testRecordDisappearingStillDrainsBeforeClosing() throws {
        let path = newLogPath()
        try append(textLine(stream: "stderr", "a"), to: path)
        let tailer = RunLogTailer()
        _ = tailer.poll(records: [record(eventLog: path)])
        try append(textLine(stream: "stderr", "b"), to: path)
        XCTAssertEqual(tailer.poll(records: []).first?.lines, ["b"])
        XCTAssertTrue(tailer.poll(records: []).isEmpty)
        XCTAssertTrue(tailer.trackedPaths.isEmpty)
    }

    func testFormatsEventsAndEmitsAllLinesWithoutTruncation() throws {
        let path = newLogPath()
        var body = stdoutLine(#"{"kind":"scenarioStarted","scenario":"S","title":"T"}"#)
        let count = 5_000
        for index in 1...count {
            body += stdoutLine(#"{"kind":"step","index":\#(index),"description":"tap","status":"passed"}"#)
        }
        body += textLine(stream: "stderr", "warn")
        try append(body, to: path)
        let events = RunLogTailer().poll(records: [record(eventLog: path)])
        XCTAssertEqual(events.count, 1, "lane ごと・周期ごとに1件")
        XCTAssertEqual(events[0].lines.count, 1 + count + 1, "件数で打ち切らない・間引かない")
        XCTAssertEqual(events[0].lines.first, "▶ S — T")
        XCTAssertEqual(events[0].lines[1], "    ✅ 1. tap")
        XCTAssertEqual(events[0].lines.last, "warn")
    }

    func testDoesNotOpenFilesOutsideTheEventLogShape() throws {
        let outside = root.appendingPathComponent("secret.txt").path
        try append("secret\n", to: outside)
        let tailer = RunLogTailer()
        XCTAssertTrue(tailer.poll(records: [record(eventLog: outside)]).isEmpty)
        XCTAssertTrue(tailer.trackedPaths.isEmpty)
    }

    func testTwoLanesProduceSeparateEvents() throws {
        let a = newLogPath(), b = newLogPath()
        try append(textLine(stream: "stderr", "from a"), to: a)
        try append(textLine(stream: "stderr", "from b"), to: b)
        let laneB = RunProgressLane(key: "K2", name: "iPhone 17-02", platform: "ios", scenario: "S",
                                    scenarioStartedAt: nil, expectedSeconds: nil, eventLog: b)
        let events = RunLogTailer().poll(records: [record(eventLog: a, lanes: [laneB])])
        XCTAssertEqual(Set(events.map(\.device)), ["ios:iPhone 17-01", "ios:iPhone 17-02"])
        XCTAssertEqual(events.first { $0.device == "ios:iPhone 17-02" }?.lines, ["from b"])
    }

    func testEventEncodesWithoutMachineForLocalAndTheKind() throws {
        let event = ApiMonitorRunLogEvent(device: "ios:A", runID: nil, pid: 1, owner: nil, lines: ["x"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(event)) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "monitorRunLog")
        XCTAssertNil(object["machine"], "手元は machine を省略する(monitorRuns と同じ綴り)")
        XCTAssertEqual(object["lines"] as? [String], ["x"])
    }
}
