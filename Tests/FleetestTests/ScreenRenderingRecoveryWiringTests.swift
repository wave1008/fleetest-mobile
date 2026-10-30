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
        XCTAssertTrue(text.contains("unrecoveredDeviceNames: {"))
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
