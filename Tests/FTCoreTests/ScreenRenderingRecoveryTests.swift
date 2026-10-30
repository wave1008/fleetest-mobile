import XCTest
@testable import FTCore

/// 描画の状態(白紙・文字消え)の手当て(OI-88): 切り離しの判定・1台1回の台帳・回復の手順・案内の公表
final class ScreenRenderingRecoveryTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ft-render-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - 切り離しの判定

    func testDetachesWhenAnotherLaneOfTheSamePlatformIsRunning() {
        var book = RenderingLaneBook()
        book.join(laneKey: "A", platform: "ios")
        book.join(laneKey: "B", platform: "ios")
        XCTAssertEqual(book.decide(laneKey: "A", platform: "ios", scenarioID: "S1", state: .blank), .detach)
    }

    func testKeepsTheLaneWhenNoOtherLaneOfThePlatformIsRunning() {
        var book = RenderingLaneBook()
        book.join(laneKey: "A", platform: "ios")
        book.join(laneKey: "X", platform: "android")
        XCTAssertEqual(book.decide(laneKey: "A", platform: "ios", scenarioID: "S1", state: .blank), .keepNoOtherLane)
    }

    /// 全レーンが同時に報告しても全滅させない: 先の離脱が帳に反映されるので、後の判定は「他のレーンが居ない」になる
    func testSimultaneousReportsNeverDetachEveryLane() {
        var book = RenderingLaneBook()
        book.join(laneKey: "A", platform: "ios")
        book.join(laneKey: "B", platform: "ios")
        XCTAssertEqual(book.decide(laneKey: "A", platform: "ios", scenarioID: "S1", state: .textless), .detach)
        XCTAssertEqual(book.decide(laneKey: "B", platform: "ios", scenarioID: "S2", state: .textless), .keepNoOtherLane)
    }

    func testSameScenarioReportedByAnotherLaneKeepsTheResult() {
        var book = RenderingLaneBook()
        for key in ["A", "B", "C"] { book.join(laneKey: key, platform: "android") }
        XCTAssertEqual(book.decide(laneKey: "A", platform: "android", scenarioID: "S1", state: .blank), .detach)
        XCTAssertEqual(book.decide(laneKey: "B", platform: "android", scenarioID: "S1", state: .blank),
                       .keepReportedByOtherLane(lane: "A"))
    }

    /// 別の状態・別のシナリオは「同じ報告」ではない
    func testDifferentStateOrScenarioIsNotTheSameReport() {
        var book = RenderingLaneBook()
        for key in ["A", "B", "C"] { book.join(laneKey: key, platform: "ios") }
        XCTAssertEqual(book.decide(laneKey: "A", platform: "ios", scenarioID: "S1", state: .blank), .detach)
        XCTAssertEqual(book.decide(laneKey: "B", platform: "ios", scenarioID: "S1", state: .textless), .detach)
        XCTAssertEqual(book.decide(laneKey: "C", platform: "ios", scenarioID: "S2", state: .blank), .keepNoOtherLane)
    }

    func testLeaveRemovesTheLaneFromTheCount() {
        var book = RenderingLaneBook()
        book.join(laneKey: "A", platform: "ios")
        book.join(laneKey: "B", platform: "ios")
        book.leave(laneKey: "B")
        XCTAssertEqual(book.decide(laneKey: "A", platform: "ios", scenarioID: "S1", state: .blank), .keepNoOtherLane)
    }

    func testBlankWinsWhenBothStatesWereReported() {
        XCTAssertEqual(RunOrchestrator.reportedScreenState([.textless, .blank]), .blank)
        XCTAssertEqual(RunOrchestrator.reportedScreenState([.textless]), .textless)
        XCTAssertNil(RunOrchestrator.reportedScreenState([]))
    }

    // MARK: - 1台1回の台帳

    func testLedgerActionByBootTime() {
        let boot = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(ScreenRecoveryLedger.action(firedAt: nil, bootTime: boot), .fire)
        XCTAssertEqual(ScreenRecoveryLedger.action(firedAt: 1_001, bootTime: boot), .advise)
        XCTAssertEqual(ScreenRecoveryLedger.action(firedAt: 999, bootTime: boot), .fire, "マシンの再起動より前の記録は数え直す")
        // 起動時刻が読めないときは繰り返さない側に倒す
        XCTAssertEqual(ScreenRecoveryLedger.action(firedAt: 5, bootTime: nil), .advise)
        XCTAssertEqual(ScreenRecoveryLedger.action(firedAt: nil, bootTime: nil), .fire)
    }

    // MARK: - 回復の手順

    func testRunFiresOnceThenAdvisesWithoutFiringAgain() async throws {
        let dir = try tempDir()
        let boot = Date(timeIntervalSince1970: 1_000)
        let fired = LockedValue<Int>(0)
        let first = await ScreenRenderingRecovery.run(
            key: "K", name: "iPhone", stateDir: dir, bootTime: boot,
            repair: { fired.withLock { $0 += 1 }; return .deviceRestart }, drawn: { false }, log: { _ in })
        XCTAssertEqual(first, .notRecovered(.deviceRestart))
        XCTAssertEqual(UnrecoveredDeviceStore.list(stateDir: dir, bootTime: boot).map(\.name), ["iPhone"])
        let second = await ScreenRenderingRecovery.run(
            key: "K", name: "iPhone", stateDir: dir, bootTime: boot,
            repair: { fired.withLock { $0 += 1 }; return .deviceRestart }, drawn: { true }, log: { _ in })
        XCTAssertEqual(second, .advised)
        XCTAssertEqual(fired.withLock { $0 }, 1, "同じマシンの起動のあいだに2回目は撃たない")
    }

    func testRunClearsThePublishedStateWhenTheScreenIsDrawingAgain() async throws {
        let dir = try tempDir()
        DeviceScreenStateStore.publish(stateDir: dir, key: "K", state: .blank)
        UnrecoveredDeviceStore.publish(stateDir: dir, key: "K", name: "old")
        let outcome = await ScreenRenderingRecovery.run(
            key: "K", name: "Pixel", stateDir: dir, bootTime: Date(timeIntervalSince1970: 1),
            repair: { .displayServerRestart }, drawn: { true }, log: { _ in })
        XCTAssertEqual(outcome, .recovered(.displayServerRestart))
        XCTAssertNil(DeviceScreenStateStore.current(stateDir: dir, key: "K"))
        XCTAssertFalse(UnrecoveredDeviceStore.isPublished(stateDir: dir, key: "K", bootTime: nil))
    }

    func testRunWithoutKeyOrWithNothingFiredLeavesNoTrace() async throws {
        let dir = try tempDir()
        let none = await ScreenRenderingRecovery.run(key: nil, name: "x", stateDir: dir, repair: { .deviceRestart },
                                                     drawn: { true }, log: { _ in })
        XCTAssertEqual(none, .notAttempted)
        let nothing = await ScreenRenderingRecovery.run(key: "K", name: "x", stateDir: dir, bootTime: Date(timeIntervalSince1970: 1),
                                                        repair: { nil }, drawn: { true }, log: { _ in })
        XCTAssertEqual(nothing, .notAttempted)
        XCTAssertNil(ScreenRecoveryLedger.firedAt(stateDir: dir, key: "K"), "撃てなかった回は台帳に残さない")
    }

    // MARK: - 案内の公表

    func testUnrecoveredStoreDropsEntriesOlderThanTheMachineBoot() throws {
        let dir = try tempDir()
        UnrecoveredDeviceStore.publish(stateDir: dir, key: "K1", name: "b", now: Date(timeIntervalSince1970: 500))
        UnrecoveredDeviceStore.publish(stateDir: dir, key: "K2", name: "a", now: Date(timeIntervalSince1970: 1_500))
        let boot = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(UnrecoveredDeviceStore.list(stateDir: dir, bootTime: boot).map(\.name), ["a"])
        XCTAssertFalse(UnrecoveredDeviceStore.isPublished(stateDir: dir, key: "K1", bootTime: boot))
        XCTAssertTrue(UnrecoveredDeviceStore.isPublished(stateDir: dir, key: "K2", bootTime: boot))
    }

    func testClosingNoticeStatesOnlyTheMeasuredFact() {
        XCTAssertNil(UnrecoveredDeviceStore.closingNotice(names: []))
        let text = UnrecoveredDeviceStore.closingNotice(names: ["a", "b"])!
        XCTAssertTrue(text.contains("did not bring the screen back on a, b"))
        XCTAssertTrue(text.contains("restarting this machine is recommended"))
    }

    func testDefaultsAndNamesArePinned() {
        XCTAssertEqual(ScreenRecoveryLedger.entryURL(stateDir: URL(fileURLWithPath: "/x"), key: "K").lastPathComponent,
                       "screen-recovery-K.json")
        XCTAssertEqual(UnrecoveredDeviceStore.entryURL(stateDir: URL(fileURLWithPath: "/x"), key: "K").lastPathComponent,
                       "screen-unrecovered-K.json")
        XCTAssertEqual(WorkerAnomalyCause.rendering.rawValue, "rendering")
    }

    func testReportsOnAnotherPlatformDoNotCount() {
        var book = RenderingLaneBook()
        for (lane, platform) in [("a1", "android"), ("a2", "android"), ("i1", "ios"), ("i2", "ios")] {
            book.join(laneKey: lane, platform: platform)
        }
        XCTAssertEqual(book.decide(laneKey: "a1", platform: "android", scenarioID: "S", state: .blank), .detach)
        XCTAssertEqual(book.decide(laneKey: "i1", platform: "ios", scenarioID: "S", state: .blank), .detach)
    }
}
