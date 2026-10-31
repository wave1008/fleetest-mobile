// `fleetest run` / `fleetest api run` の出口の順序(手元の dispatch.lock と中断の登録は、供給と片付けが終わるまで持つ)。

/// **本体の外側で1回だけ `finish()` を通す**(`defer` の中では待てない)。順序: 供給のタスクを待つ → 片付け →
/// dispatch.lock の解放 → 中断の登録の解除。本体の `defer` でロックを外すと、走っている供給・終了スクリプトの横で
/// 次の run がロックを取り、その間の中断も後始末の無い既定の終了になる
final class RunExitGuard {
    /// 供給のタスクが終わるまで待つ。起こしていなければ nil
    var settle: (() async -> Void)?
    /// 準備の段で作ったものの片付け(`SupplyCleanup.run` = 2回呼んでも1回だけ効く)
    var close: (() -> Void)?
    var dispatchLock: LocalDispatchLock.Holder?
    var stopInterruptRelay: (() -> Void)?

    /// 結果を書く前に片付ける経路も呼ぶ。`close` が2回目を無視するので `finish()` と重ねてよい
    func settleAndClose() async {
        await settle?()
        close?()
    }

    func finish() async {
        await settleAndClose()
        dispatchLock?.release()
        stopInterruptRelay?()
    }
}
