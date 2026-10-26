// ブリッジが**届けていないと確定できる**形で断ったときの撃ち直し。古い ref(DriverError.staleRef)は木を撮り直して引き直し、
// システムアラート(DriverError.systemAlertBlocked)は登録(iosAlertHandler)で閉じてから撃ち直す。
// 呼び口は StepExecutor.execute の executeAction 呼び出し1箇所。

import Foundation

extension StepExecutor {

    /// 引き直してよいかの判定。**staleRef だけ**(ブリッジが何も撃っていないと保証した断り)。
    /// 他のエラーは届いたかもしれない操作の失敗を含むので撃ち直さない(届いたか分からない操作は撃ち直さない方針)
    static func isRetryableStaleRef(_ error: Error) -> Bool {
        if case DriverError.staleRef? = error as? DriverError { return true }
        return false
    }

    /// システムアラートに遮られ、ブリッジが届けていないと確定した断りか(`DriverError.systemAlertBlocked`)。
    /// 撃ち直すのは登録がある回だけ(呼び手が `systemAlertWatchlist.isWatching` を見る)—— 登録の無いアラートは閉じない
    static func isUndeliveredBySystemAlert(_ error: Error) -> Bool {
        if case DriverError.systemAlertBlocked? = error as? DriverError { return true }
        return false
    }

    /// `executeAction` を、届けていないと確定した断り(staleRef / 登録のあるときの systemAlertBlocked)を受けたときだけ
    /// `step.timeout`(未指定は既定の待ち)の予算内で最初からやり直す。
    /// やり直しはロケータの解決(木の撮り直し)から入るので、新しい木から ref を引き直す
    /// (executor.md「ブリッジの ref は、そのドライバが最後に撮った木の中でだけ有効」)。
    /// **撃っていない操作の記録を巻き戻す**: 入口が `lastInteraction` 等を前のタップの確定に使うので、
    /// 撃たなかった試行が残した記録を次の試行が「前のタップ」として読まないよう、試行の前の値へ戻す。
    /// **やり直しは同じ action の準備の操作(type(replace:) の消去・覆いの下からの持ち上げ・キーボードの向こうへの寄せ)も
    /// 引き直した要素へ撃ち直す**。許容する理由: 断りが出るのは最後に撃つ要求だけで、準備の消去にも同じ撃つ直前の確かめが
    /// 入っている(古い欄を消す前に断られる)・持ち上げと寄せはスクロールの類で、送信・購入のような取り返しのつかない操作ではない
    func executeActionRetryingUndelivered(_ action: String, step: FlowStep, fingerprint: LocatorFingerprint?,
                                       phase: inout PhaseAccumulator) async throws -> StepOutcome {
        let clock = ContinuousClock()
        let start = clock.now
        var backoff = PollBackoff()
        while true {
            let savedLast = lastInteraction
            let savedAwaiting = tapAwaitingNextTree
            let savedPrevious = previousTapTree
            let savedUnchanged = unchangedEarlierTaps
            let savedTapTarget = lastTapTarget
            do {
                return try await executeAction(action, step: step, fingerprint: fingerprint, phase: &phase)
            } catch {
                let blockedByAlert = Self.isUndeliveredBySystemAlert(error)
                    && systemAlertWatchlist.isWatching && fallbackDriver != nil
                guard Self.isRetryableStaleRef(error) || blockedByAlert else { throw error }
                // 予算を Duration にするのは最初の断りのとき —— `.seconds(Double)` は範囲外で trap する。範囲外の
                // waitSeconds は executeStep の入口(FlowStep.secondsArgumentViolation)が先に断るので、isFinite は二重の備え
                let budget = step.timeout ?? tunables.defaultTimeout
                guard budget.isFinite, clock.now < start.advanced(by: .seconds(budget)) else { throw error }
                lastInteraction = savedLast
                tapAwaitingNextTree = savedAwaiting
                previousTapTree = savedPrevious
                unchangedEarlierTaps = savedUnchanged
                lastTapTarget = savedTapTarget
                if blockedByAlert {
                    // ステップ開始の確認(executeAction の入口の waitOutSystemUI)の後に出たアラート。同じ門で閉じる/待つ:
                    // 登録のボタンが無ければ予算まで待って systemUICovered で落ちる(登録は「次に出る」という予告でもある)
                    noteCodesThisStep.insert(.systemAlertRetried)
                    if let covered = try await waitOutSystemUI(step: step, phase: &phase) {
                        return StepOutcome(status: covered)
                    }
                    continue
                }
                noteCodesThisStep.insert(.staleRefRetried)
                let waitStart = clock.now
                try await Task.sleep(for: backoff.nextDelay())
                phase.waitMs += Self.ms(clock.now - waitStart)
            }
        }
    }
}
