// `fleetest run` / `fleetest api run` の出口の順序(手元の dispatch.lock と中断の登録は、供給と片付けが終わるまで持つ)。

import ArgumentParser
import FTCore

/// 供給のレーンが段の境目で見る「もう要らない」の印。中断とは別に持つ(run.json に中断と残さない)
final class SupplyAbandon: Sendable {
    private let abandoned = LockedValue(false)
    var isAbandoned: Bool { abandoned.withLock { $0 } }
    func mark() { abandoned.withLock { $0 = true } }
}

/// **入口は `run(log:_:)` の1箇所**(`defer` の中では待てない)。順序: 供給のタスクを待つ → 片付け → 進捗の控えを消す →
/// dispatch.lock の解放 → 中断の登録の解除。本体の `defer` でロックを外すと、走っている供給・終了スクリプトの横で
/// 次の run がロックを取り、控えを先に消すとロックを握ったままマシンが空いて見える
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
            // 供給の完了を待つ間、落ちた理由が出ないと止まって見える(赤の run の ExitCode は理由を持たない)
            if exit.settle != nil, !(error is ExitCode) {
                log("→ Stopping the device supply before cleaning up: \(error.localizedDescription)")
            }
            await exit.finish()
            throw error
        }
        await exit.finish()
    }

    /// 結果を書く前に片付ける経路も呼ぶ。どちらも1回だけ効く(`finish()` と重ねてよい)
    func settleAndClose() async {
        supplyAbandon.mark()
        let settle = self.settle
        self.settle = nil
        await settle?()
        let close = self.close
        self.close = nil
        close?()
    }

    func finish() async {
        await settleAndClose()
        removeProgress?()
        dispatchLock?.release()
        stopInterruptRelay?()
    }
}
