// 描画の状態の手当て(OI-88)の配線を固定する。未注入は合法なのでコンパイルでは止まらない = 走査で固定する

import XCTest

final class ScreenRenderingRecoveryWiringTests: XCTestCase {

    private static func code(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testTheSharedWiringPassesTheRecoveryAndTheClosingNames() throws {
        let text = try Self.code("Sources/fleetest/ProfileRunOrchestrator.swift")
        XCTAssertTrue(text.contains("recoverRendering: {"))
        XCTAssertTrue(text.contains("ScreenRenderingRecoverer.recover("))
        XCTAssertTrue(text.contains("unrecoveredDevices: {"))
    }

    func testBothSupplyLanesRunThePreRunRecoveryThroughTheLedger() throws {
        let text = try Self.code("Sources/fleetest/ProfileSupplyLanes.swift")
        XCTAssertEqual(text.components(separatedBy: "ScreenRenderingRecoverer.prepareBeforeRun(").count - 1, 2)
    }

    /// 回復はテスト中に撃たない: 離脱の後(cleanup の後)・revive の前に 1 箇所だけ
    func testTheOrchestratorRecoversOnlyAfterTheLaneLeftAndBeforeRevive() throws {
        let text = try Self.code("Sources/FTCore/RunOrchestrator.swift")
        XCTAssertEqual(text.components(separatedBy: "await recoverRendering(").count - 1, 1)
        let cleanup = text.range(of: "await cleanupRetiredWorker?(retired)")!
        let recover = text.range(of: "await recoverRendering(")!
        let revive = text.range(of: "guard let newWorker = await revive(retired)")!
        XCTAssertLessThan(cleanup.lowerBound, recover.lowerBound)
        XCTAssertLessThan(recover.lowerBound, revive.lowerBound)
        XCTAssertTrue(text.contains("cause: .rendering,\n                                            failed: failed"), "切り離しは retireUnusable を通す")
    }

    /// 中断中は回復も revive も撃たない(キューは中断後も残る = `hasItems` だけでは門にならない)
    func testRecoveryAndReviveAreGatedOnTheInterruption() throws {
        let text = try Self.code("Sources/FTCore/RunOrchestrator.swift")
        let recover = try XCTUnwrap(text.range(of: "let recoverRendering, revives < MAX_WORKER_REVIVES"))
        XCTAssertTrue(String(text[recover.upperBound...].prefix(200)).contains("await !stoppedByUser()"))
        let revive = try XCTUnwrap(text.range(of: "guard revives < MAX_WORKER_REVIVES, await queue.hasItems()"))
        XCTAssertTrue(String(text[revive.upperBound...].prefix(120)).contains("await !stoppedByUser()"))
    }

    /// 供給の2レーン(と呼び手 5 箇所)は中断を渡す。渡し忘れは run の前の回復が中断後も続く
    func testSupplyLanesReceiveTheInterruption() throws {
        let lanes = try Self.code("Sources/fleetest/ProfileSupplyLanes.swift")
        XCTAssertEqual(lanes.components(separatedBy: "isStopped: isStopped").count - 1, 2)
        let api = try Self.code("Sources/fleetest/ApiRunCommand.swift")
        let supply = try Self.code("Sources/fleetest/ProfileRunner+Supply.swift")
        // 並行の供給は放棄の印も見る(`SupplyAbandon.shouldStop`)
        let calls = [api, supply].map { text in
            ["isStopped: { interruptState.isStopped }", "isStopped: shouldStop"]
                .map { text.components(separatedBy: $0).count - 1 }.reduce(0, +)
        }.reduce(0, +)
        XCTAssertEqual(calls, 6)
    }

    /// 切り離しは緑と素の赤だけ・中断中は撃たない・ブリッジが答えるときだけ(順序が崩れると既存の仕分けを横取りする)
    func testDetachGates() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FTCore/RunOrchestrator.swift"), encoding: .utf8)
        let block = try XCTUnwrap(source.range(of: "var renderingDetach: DeviceScreenState?"))
        let gate = String(source[block.upperBound...].prefix(420))
        XCTAssertTrue(gate.contains("outcome == .passed || outcome == .failed"), gate)
        XCTAssertTrue(gate.contains("await !stoppedByUser()"), gate)
        XCTAssertTrue(gate.contains("worker.driver.status()"), gate)
        let leave = try XCTUnwrap(source.range(of: "もうシナリオを取らないので"))
        let tearDown = try XCTUnwrap(source.range(of: "ScenarioHost.runDeviceTearDowns("))
        XCTAssertLessThan(leave.lowerBound, tearDown.lowerBound, "片付けの前に判定帳から外す")
    }
}
