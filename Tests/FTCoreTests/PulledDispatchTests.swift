import XCTest
@testable import FTCore

/// `ScenarioDispatch.pulled`: キューは空で始まり、配り手が配った ID だけが item になる
final class PulledDispatchTests: XCTestCase {

    private func item(_ id: String, platform: String = "ios") -> ScenarioRunItem {
        ScenarioRunItem(info: ScenarioInfo(id: id, title: id, platform: platform))
    }

    /// 配り手の偽物。返す ID の列を順に返し、聞かれた (platform, lane) を控える
    private final class FakeSource: ScenarioPullSource {
        private let replies: LockedValue<[String?]>
        let asked = LockedValue<[String]>([])
        init(_ replies: [String?]) { self.replies = LockedValue(replies) }
        func next(platform: String, lane: String) async -> String? {
            asked.withLock { $0.append("\(platform):\(lane)") }
            return replies.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        }
        let stops = LockedValue(0)
        func stopWaiting() { stops.withLock { $0 += 1 } }
    }

    private func makeQueue(_ catalog: [ScenarioRunItem], source: FakeSource,
                           handedOut: LockedValue<[String]> = LockedValue([]),
                           unknown: LockedValue<[String]> = LockedValue([])) -> ScenarioQueue {
        var map: [String: [ScenarioRunItem]] = [:]
        for item in catalog { map[item.info.id, default: []].append(item) }
        return ScenarioQueue(pulled: ScenarioQueue.PullState(
            source: source, platform: "ios", catalog: LockedValue(map),
            onHandOut: { item in handedOut.withLock { $0.append(item.info.id) } },
            onUnknownID: { id in unknown.withLock { $0.append(id) } }))
    }

    func testNothingRunsUntilTheSourceHandsItOut() async {
        let source = FakeSource(["A"])
        let queue = makeQueue([item("A"), item("B")], source: source)
        XCTAssertTrue(source.asked.value.isEmpty, "作っただけで配り手へ聞いている")
        let got = await queue.next(lane: "iPhone 17")
        XCTAssertEqual(got?.info.id, "A")
        XCTAssertEqual(source.asked.value, ["ios:iPhone 17"])
        // B はカタログにあっても配られていないので出ない
        let end = await queue.next(lane: "iPhone 17")
        XCTAssertNil(end)
    }

    func testRequeuedItemRunsLocallyBeforeAskingTheSource() async {
        let source = FakeSource(["B"])
        let queue = makeQueue([item("A"), item("B")], source: source)
        let a = item("A")
        let attempt = await queue.requeue(a)
        XCTAssertEqual(attempt, 1)
        let first = await queue.next(lane: "x")
        XCTAssertEqual(first?.info.id, "A")
        XCTAssertTrue(source.asked.value.isEmpty, "再キューが残っているのに配り手へ聞いた")
        let second = await queue.next(lane: "x")
        XCTAssertEqual(second?.info.id, "B")
        XCTAssertEqual(source.asked.value.count, 1)
    }

    func testSourceNilEndsTheQueueAndIsNotAskedAgain() async {
        let source = FakeSource([nil, "A"])
        let queue = makeQueue([item("A")], source: source)
        let hasBefore = await queue.hasItems()
        XCTAssertTrue(hasBefore, "配り手がまだ nil を返していない間は仕事が来うる")
        let first = await queue.next(lane: "x")
        XCTAssertNil(first)
        let hasAfter = await queue.hasItems()
        XCTAssertFalse(hasAfter)
        let again = await queue.next(lane: "x")
        XCTAssertNil(again)
        XCTAssertEqual(source.asked.value.count, 1, "終わった後に聞き直している")
    }

    func testRequeueAfterExhaustionStillRunsLocally() async {
        let source = FakeSource([nil])
        let queue = makeQueue([item("A")], source: source)
        _ = await queue.next(lane: "x")
        _ = await queue.requeue(item("A"))
        let hasItems = await queue.hasItems()
        XCTAssertTrue(hasItems)
        let got = await queue.next(lane: "x")
        XCTAssertEqual(got?.info.id, "A")
    }

    func testUnknownIDIsReportedAndAskedAgain() async {
        let unknown = LockedValue<[String]>([])
        let handed = LockedValue<[String]>([])
        let source = FakeSource(["NOPE", "A"])
        let queue = makeQueue([item("A")], source: source, handedOut: handed, unknown: unknown)
        let got = await queue.next(lane: "x")
        XCTAssertEqual(got?.info.id, "A")
        XCTAssertEqual(unknown.value, ["NOPE"])
        XCTAssertEqual(handed.value, ["A"], "未知の ID を配った本数に数えている")
    }

    func testSameIDHandedTwiceUsesEachCatalogEntryOnce() async {
        let source = FakeSource(["A", "A", "A"])
        let unknown = LockedValue<[String]>([])
        let queue = makeQueue([item("A"), item("A")], source: source, unknown: unknown)
        _ = await queue.next(lane: "x")
        _ = await queue.next(lane: "x")
        let third = await queue.next(lane: "x")
        XCTAssertNil(third)
        XCTAssertEqual(unknown.value, ["A"], "カタログに無くなった ID は未知として扱う")
    }

    func testDrainTakesLocalLeftoversOnly() async {
        let source = FakeSource(["B"])
        let queue = makeQueue([item("A"), item("B")], source: source)
        _ = await queue.requeue(item("A"))
        let local = await queue.nextLocal()
        XCTAssertEqual(local?.info.id, "A")
        let none = await queue.nextLocal()
        XCTAssertNil(none)
        XCTAssertTrue(source.asked.value.isEmpty, "ドレインが配り手へ聞いている")
    }

    func testSharedQueueIsUnchanged() async {
        let queue = ScenarioQueue([item("A"), item("B")])
        let has = await queue.hasItems()
        XCTAssertTrue(has)
        let a = await queue.next(lane: "ignored")
        let b = await queue.next()
        let end = await queue.next()
        XCTAssertEqual([a?.info.id, b?.info.id], ["A", "B"])
        XCTAssertNil(end)
        let hasAfter = await queue.hasItems()
        XCTAssertFalse(hasAfter, "shared は空になったら hasItems が false")
    }

    // MARK: - RunOrchestrator(ワーカー無し)

    private static func startedTotal(_ orchestrator: RunOrchestrator) async -> Int? {
        var total: Int?
        for await event in orchestrator.events {
            if case .runStarted(let value, _) = event { total = value }
        }
        return total
    }

    /// ワーカーが居ない platform のシナリオは、pulled では失敗に数えない(配られていない = この子のものではない)。
    /// 配り手へも聞かない。total は配られた本数 = 0
    func testPulledWithoutWorkersCountsNothingAndNeverAsksTheSource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PulledDispatchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let orchestrator = RunOrchestrator(
            project: TestProject(name: "Pulled", rootURL: root), workers: [],
            settings: ScenarioExecutionSettings(fm: FMConfig(enabled: false)),
            reportDir: root.appendingPathComponent("reports"),
            progressHistoryRuns: 1, clearResidualSystemAlert: nil)
        let source = FakeSource(["A"])
        async let started = Self.startedTotal(orchestrator)
        let summary = await orchestrator.run(items: [item("A"), item("B")], defaultPlatform: "ios",
                                             dispatch: .pulled(source: source))
        let startedTotal = await started
        XCTAssertEqual(summary.total, 0)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(startedTotal, 0)
        XCTAssertTrue(source.asked.value.isEmpty)
    }

    /// 中断は pulled の配り手の待ちを解く(run の設定より前に来た中断も、後に来た中断も)。
    /// 渡し済みの返事が届かなかったレーンは親の none の相手にならず、子が中断のあと終わらなかった
    func testInterruptStopsThePullSourceWhetherItComesBeforeOrAfterTheRunStarts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PulledDispatchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let orchestrator = RunOrchestrator(
            project: TestProject(name: "Pulled", rootURL: root), workers: [],
            settings: ScenarioExecutionSettings(fm: FMConfig(enabled: false)),
            reportDir: root.appendingPathComponent("reports"),
            progressHistoryRuns: 1, clearResidualSystemAlert: nil)
        let source = FakeSource([])
        orchestrator.requestInterrupt()
        _ = await orchestrator.run(items: [item("A")], defaultPlatform: "ios", dispatch: .pulled(source: source))
        XCTAssertEqual(source.stops.value, 1, "run より前の中断で待ちを解いていない")
        orchestrator.requestInterrupt()
        XCTAssertEqual(source.stops.value, 2, "run が配り手を持った後の中断で待ちを解いていない")
    }
}
