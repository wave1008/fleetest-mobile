// `fleetest run` / `fleetest api run` の出口の順序(手元の dispatch.lock と中断の登録は、供給と片付けが終わるまで持つ)。

import ArgumentParser
import FTCore

/// 供給のレーンが段の境目で見る「もう要らない」の印。中断とは別に持つ(run.json に中断と残さない)
final class SupplyAbandon: Sendable {
    private let abandoned = LockedValue(false)
    var isAbandoned: Bool { abandoned.withLock { $0 } }
    func mark() { abandoned.withLock { $0 = true } }

    /// 供給のレーンへ渡す「止まるか」(条件を足すならここ1箇所)
    func shouldStop(_ interruptState: RunInterruptState) -> @Sendable () -> Bool {
        { [self] in interruptState.isStopped || isAbandoned }
    }
}

/// **入口は `run(log:_:)` の1箇所**(`defer` の中では待てない)。**結果を書いた後に走る**(終了スクリプトに上限が無いので、先に片付けると
/// 刺さった回の run.json が残らない)。順序: 供給のタスクを待つ → 片付け → 進捗の控えを消す →
/// dispatch.lock の解放 → 中断の登録の解除。本体の `defer` でロックを外すと、走っている供給・終了スクリプトの横で
/// 次の run がロックを取る。控えもロックの直前に消す(シナリオの前に落ちた回。始まった run の控えは orchestrator の終了が消す)
final class RunExitGuard {
    /// 供給のタスクが終わるまで待つ。起こしていなければ nil
    var settle: (() async -> Void)?
    /// 準備の段で作ったものの片付け
    var close: (() -> Void)?
    /// run ボードの入口の控えを消す
    var removeProgress: (() -> Void)?
    var dispatchLock: LocalDispatchLock.Holder?
    var stopInterruptRelay: (() -> Void)?
    let supplyAbandon = SupplyAbandon()

    static func run(log: (String) -> Void, _ body: (RunExitGuard) async throws -> Void) async throws {
        let exit = RunExitGuard()
        do {
            try await body(exit)
        } catch {
            // 供給の完了を待つ間、落ちた理由が出ないと止まって見える(赤の run の ExitCode は理由を持たない・中断は受けた時に言っている)
            if exit.settle != nil, !(error is ExitCode), !(error is RunInterruptedBeforeStartError) {
                log("→ Stopping, then cleaning up: \(error.localizedDescription)")
            }
            await exit.finish()
            throw error
        }
        await exit.finish()
    }

    func finish() async {
        supplyAbandon.mark()
        await settle?()
        close?()
        removeProgress?()
        dispatchLock?.release()
        stopInterruptRelay?()
    }
}
