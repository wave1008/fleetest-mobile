// `RunExitGuard` の順序。緑の run では差が出ず(ビルド失敗・中断・対象なしの出口だけが供給を置いて抜ける)、
// 破ると次の run が走っている供給・終了スクリプトと重なる。

import ArgumentParser
import XCTest
@testable import fleetest

final class RunExitGuardTests: XCTestCase {

    private final class Trace: @unchecked Sendable {   // 記録はテストの1つのタスクから順に呼ぶ
        var steps: [String] = []
    }

    private struct Boom: Error, LocalizedError {
        var errorDescription: String? { "boom" }
    }

    private func register(_ exit: RunExitGuard, into trace: Trace) {
        exit.settle = { trace.steps.append("settle") }
        exit.close = { trace.steps.append("close") }
        exit.removeProgress = { trace.steps.append("progress") }
        exit.dispatchLock = LocalDispatchLock.Holder { trace.steps.append("lock") }
        exit.stopInterruptRelay = { trace.steps.append("relay") }
    }

    private let fullOrder = ["settle", "close", "progress", "lock", "relay"]

    func testTheLockAndTheInterruptRegistrationOutliveTheSupplyAndTheCleanup() async throws {
        let trace = Trace()
        try await RunExitGuard.run(log: { _ in }) { register($0, into: trace) }
        XCTAssertEqual(trace.steps, fullOrder)
    }

    /// 投げた経路も同じ順序で全部通り、元のエラーがそのまま出る
    func testAThrowingBodyStillRunsTheWholeExitAndRethrows() async {
        let trace = Trace()
        var logged: [String] = []
        do {
            try await RunExitGuard.run(log: { logged.append($0) }) {
                register($0, into: trace)
                throw Boom()
            }
            XCTFail("投げ直していない")
        } catch {
            XCTAssertTrue(error is Boom)
        }
        XCTAssertEqual(trace.steps, fullOrder)
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged[0].contains("boom"), "待つ前に落ちた理由を言っていない: \(logged)")
    }

    /// 赤の run(ExitCode)は理由の行を持たない・供給が無ければ待つと言わない
    func testNoStopLineForARedRunOrWithoutASupply() async {
        var logged: [String] = []
        try? await RunExitGuard.run(log: { logged.append($0) }) {
            $0.settle = {}
            throw ExitCode(1)
        }
        try? await RunExitGuard.run(log: { logged.append($0) }) { _ in throw Boom() }
        XCTAssertEqual(logged, [])
    }

    /// 結果を書く前に片付けた経路でも、ロックの解放はそこでは起きず、出口で片付けを繰り返さない
    func testSettleAndCloseKeepsTheLockAndRunsOnce() async {
        let trace = Trace()
        let exit = RunExitGuard()
        register(exit, into: trace)
        await exit.settleAndClose()
        XCTAssertEqual(trace.steps, ["settle", "close"])
        await exit.finish()
        XCTAssertEqual(trace.steps, fullOrder)
    }

    /// 走っている供給を実際に待つ。待つ前に放棄の印を立てる(立てないと段の境目で止まらず最後まで走る)
    func testFinishMarksTheSupplyAbandonedAndWaitsForIt() async {
        let trace = Trace()
        let exit = RunExitGuard()
        let abandon = exit.supplyAbandon
        // 上限を置く(印が立たない変異で永久に待たない。尽きたら別の文字列で落ちる)
        let supply = Task {
            for _ in 0..<100 {
                if abandon.isAbandoned { return "supply" }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return "never abandoned"
        }
        exit.settle = { trace.steps.append(await supply.value) }
        exit.close = { trace.steps.append("close") }
        XCTAssertFalse(abandon.isAbandoned)
        await exit.finish()
        XCTAssertEqual(trace.steps, ["supply", "close"])
    }

    /// ArgumentParser の ValidationError も文面が読める(「no scenarios」が理由の行に出る)
    func testTheStopLineReadsAValidationError() async {
        var logged: [String] = []
        try? await RunExitGuard.run(log: { logged.append($0) }) {
            $0.settle = {}
            throw ValidationError("no scenarios")
        }
        XCTAssertEqual(logged, ["→ Stopping the device supply before cleaning up: no scenarios"])
    }

    /// 中断は受けた時に言っているので、待つ前の行を出さない
    func testNoStopLineForAnInterruption() async {
        var logged: [String] = []
        try? await RunExitGuard.run(log: { logged.append($0) }) {
            $0.settle = {}
            throw RunInterruptedBeforeStartError(phase: "the test")
        }
        XCTAssertEqual(logged, [])
    }

    func testShouldStopSeesTheInterruptionAndTheAbandonment() {
        let abandon = SupplyAbandon()
        let check = abandon.shouldStop(RunInterruptState(recorder: nil))
        XCTAssertFalse(check())
        abandon.mark()
        XCTAssertTrue(check())
    }

    /// 中断済みなら終了スクリプトへ渡さない(登録で止まる)・実行中の中断は受ける(刺さったスクリプトを止める口)
    func testTeardownKeepsTheInterruptOnlyWhileNotYetStopped() {
        let running = RunInterruptState(recorder: nil)
        XCTAssertTrue(RunHookRunner.teardownInterrupt(running) === running)
        let stopped = RunInterruptState(recorder: nil)
        stopped.requestStop()
        XCTAssertNil(RunHookRunner.teardownInterrupt(stopped))
        XCTAssertNil(RunHookRunner.teardownInterrupt(nil))
    }

    /// ロック前に抜けた経路(何も登録していない)でも落ちない
    func testFinishWithNothingRegisteredIsANoOp() async {
        await RunExitGuard().finish()
    }
}
