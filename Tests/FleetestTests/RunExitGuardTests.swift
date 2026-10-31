// `RunExitGuard` の順序。緑の run では差が出ず(ビルド失敗・中断・対象なしの出口だけが供給を置いて抜ける)、
// 破ると次の run が走っている供給・終了スクリプトと重なる。

import XCTest
@testable import fleetest

final class RunExitGuardTests: XCTestCase {

    private final class Trace: @unchecked Sendable {   // 記録はテストの1つのタスクから順に呼ぶ
        var steps: [String] = []
    }

    private func guardRecording(into trace: Trace) -> RunExitGuard {
        let exit = RunExitGuard()
        exit.settle = { trace.steps.append("settle") }
        exit.close = { trace.steps.append("close") }
        exit.dispatchLock = LocalDispatchLock.Holder { trace.steps.append("lock") }
        exit.stopInterruptRelay = { trace.steps.append("relay") }
        return exit
    }

    func testTheLockAndTheInterruptRegistrationOutliveTheSupplyAndTheCleanup() async {
        let trace = Trace()
        await guardRecording(into: trace).finish()
        XCTAssertEqual(trace.steps, ["settle", "close", "lock", "relay"])
    }

    /// 結果を書く前に片付けた経路でも、ロックの解放はそこでは起きない
    func testSettleAndCloseKeepsTheLock() async {
        let trace = Trace()
        await guardRecording(into: trace).settleAndClose()
        XCTAssertEqual(trace.steps, ["settle", "close"])
    }

    /// 走っている供給を実際に待つ(待たずに進むと、片付けが供給の完了より先に記録される)
    func testFinishWaitsForTheRunningSupply() async {
        let trace = Trace()
        let exit = RunExitGuard()
        let supply = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            return "supply"
        }
        exit.settle = { trace.steps.append(await supply.value) }
        exit.close = { trace.steps.append("close") }
        await exit.finish()
        XCTAssertEqual(trace.steps, ["supply", "close"])
    }

    /// ロック前に抜けた経路(何も登録していない)でも落ちない
    func testFinishWithNothingRegisteredIsANoOp() async {
        await RunExitGuard().finish()
    }

    /// 片付けの2回目は効かない(結果の前の片付けと出口の `finish()` が重なる経路)
    func testSupplyCleanupRunsOnce() {
        var lines: [String] = []
        let cleanup = ProfileRunner.SupplyCleanup { lines.append($0) }
        cleanup.run()
        cleanup.run()
        XCTAssertEqual(lines, [])
    }
}
