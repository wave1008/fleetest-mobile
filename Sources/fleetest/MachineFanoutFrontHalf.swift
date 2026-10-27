// MachineFanoutFrontHalf.swift
// マシンをまたぐ3つの親(DeviceMachineRunner.run / MultiTargetRunner.run / ApiRunMachineFanout.run)の
// **前段を1箇所に持つ**: 入口の印 → チケット → 手元のロックの先取り → ビルド・割り当て(呼び手の差分)→
// 手放す → 手元のデバイスの使用中の待ち → (api run だけ runStarted)→ DispatchPrelock。
// 並びは remote.md の規律(1マシン1 run・FIFO・全順序)そのもので、3か所に手書きすると直しが3回要り、
// 写しのずれ(ロックを握ったまま使用中を待つ)が実際に出た。順序はこのファイルの走査で固定する
// (DispatchLockBeforeBuildOrderingTests・DynamicDispatcherTests・LocalLeaseRefusalBeforeDispatchTests)。
//
// 呼び手の差分は引数だけ: ログの出し口・NDJSON の出し口(api run)・ビルドと割り当て(`build`)・
// 使用中を確かめる対象(`Plan.leaseChecks`)・ロックを取る機械(`Plan.machines`)。
// 戻りの後(購読の登録・子の起動)は呼び手の持ち物で、購読の後に `Held.exitIfInterruptedBeforeLaunch` を呼ぶ。

import ArgumentParser
import FTCore
import FTRemote
import Foundation

/// `--wait-lock N` の期限を親の入口で1つに決める(開始 + N)。段ごと・対象ごと・機械ごとに N を払い直さない。
/// **数えるのは待ちだけ**: ビルド・一覧取得の時間は `excluding` で外す(利用者向けの docs は「上限は待ちの合計」。
/// 初回のビルドが長いと、何も待っていないのに使用中の端末や機械を即座に断っていた)。
/// 尽きたら 0 を返す —— 各段は「待たずに断る」と同じ経路(上限に達した断り)に落ちる。新しい定数は持たない
struct WaitLockDeadline: Sendable {
    let limitSeconds: Int?
    let start: Date

    init(limitSeconds: Int?, start: Date = Date()) {
        self.limitSeconds = limitSeconds
        self.start = start
    }

    /// 待ちでない区間(秒)を期限から外した期限
    func excluding(_ seconds: TimeInterval) -> WaitLockDeadline {
        WaitLockDeadline(limitSeconds: limitSeconds, start: start.addingTimeInterval(max(0, seconds)))
    }

    /// 残り秒。`--wait-lock` が無ければ nil(待たない)
    func remaining(now: Date = Date()) -> Int? {
        guard let limitSeconds else { return nil }
        return max(0, limitSeconds - max(0, Int(now.timeIntervalSince(start))))
    }
}

enum MachineFanoutFrontHalf {

    struct Settings {
        let mode: RemoteDispatchMode
        let remoteDir: String?
        let forceLock: Bool
        let waitLock: Int?
        let setOverrides: [String: RunProfileSetValue]
        let log: (String) -> Void
        /// 手元の dispatch.lock の待ちの NDJSON(`fleetest api run` だけ。`fleetest run` は nil)
        let emitLocalLockWaiting: ((DispatchWaitStatus) -> Void)?
        /// 手元のデバイスの使用中の待ちの NDJSON(`fleetest api run` だけ)。`dispatchWaiting` とは別のイベント
        let emitLocalDevicesWaiting: ((_ elapsedSeconds: Int, _ limitSeconds: Int?) -> Void)?
    }

    /// 手元のデバイスの二重使用を確かめる対象(1つの実行プロファイルにつき1件)
    struct LeaseCheck {
        let project: TestProject
        let profileName: String
        let localDeviceNames: [String]
        let localScenarios: [ScenarioInfo]
        let broadcast: Bool
    }

    /// `build` の答え。配分が確定した後に前段が使う
    struct Plan {
        let leaseChecks: [LeaseCheck]
        /// ロックを取りに行く機械のラベル(重複は畳まれる)
        let machines: [String]
        /// facts の読み出し・ssh の組み立てに使うプロジェクト
        let prelockProject: TestProject
    }

    /// 前段を抜けた親が持つもの。`close()` を呼び手の defer で呼ぶ(二重解放は無害)
    final class Held {
        let parentInterrupt: DeviceMachineRunner.ParentInterrupt
        let runGroup: String
        let ticket: DispatchTicket
        let prelock: DispatchPrelock

        init(parentInterrupt: DeviceMachineRunner.ParentInterrupt, runGroup: String, ticket: DispatchTicket,
             prelock: DispatchPrelock) {
            self.parentInterrupt = parentInterrupt
            self.runGroup = runGroup
            self.ticket = ticket
            self.prelock = prelock
        }

        /// 子タスクへ渡すのは値のコピー(prelock 自身を @Sendable な closure へ持ち込まない)
        var lockMarkers: [String: String] { prelock.markers }

        /// 呼び手が中断の購読(`InterruptRelay.observing(catchUp: true)`)を登録した**後**に呼ぶ。
        /// 登録より前の中断は子を起こす前にここで抜ける(後の中断は購読と各子の relay が受ける)
        func exitIfInterruptedBeforeLaunch(log: (String) -> Void) throws {
            try parentInterrupt.exitIfSet(noticedAt: "the dispatch lock acquisition", log: log)
        }

        func close() {
            prelock.releaseAll()
            parentInterrupt.stop()
        }
    }

    /// 前段。`build` は手元のロックを握っている間に走る(ビルドの直列化)—— nil を返すと「走らせるものが無い」で、
    /// ロックを手放して nil を返す(呼び手は自分の正常終了へ進む)。`announceBeforePrelock` は api run が runStarted を
    /// 出す口(割り当てまでの中断は出す前に抜け、出した後の出口の runFinished は呼び手が持つ)。
    /// 戻りが nil でも throw でも、握ったものは全部手放して印を外してある
    static func run<Built>(
        settings: Settings,
        announceBeforePrelock: (() -> Void)? = nil,
        build: (_ parentInterrupt: DeviceMachineRunner.ParentInterrupt) throws -> (built: Built, plan: Plan)?
    ) throws -> (held: Held, built: Built)? {
        let log = settings.log
        let parentInterrupt = DeviceMachineRunner.ParentInterrupt()
        let deadlineAtEntry = WaitLockDeadline(limitSeconds: settings.waitLock)
        var prelock: DispatchPrelock?
        var succeeded = false
        defer {
            if !succeeded {
                prelock?.releaseAll()
                parentInterrupt.stop()
            }
        }

        // 機械ごとに別々の run になるので、束ね鍵はここで1回だけ発行して全員へ配る
        // (FTCore.RunMetaRecord.runGroup。子が自分で作ると束にならない)。ビルドより前に採る ——
        // 待機列のチケット(下)にも使うので、build 分だけ epoch が遅れないようにする
        let runGroup = RunRecorder.makeRunGroupID()
        // dispatch.lock の待機チケットも**ここで1回だけ**採る(DispatchTicketIssuer の宣言。機械ごとに
        // 採り直すと前後関係が機械によって食い違い、2つの run が互いに相手の機械を待つ)。
        // **プロセス環境へも書く**(`FT_DISPATCH_TICKET`。子と同じ綴り・同じ資格で自分自身にも効かせる)——
        // 下のローカル先取りと、あとで `DispatchPrelock` が local を取り直すときの両方が、この早い epoch の
        // チケットを引く。書かずに後で採り直すと、build 中に列へ並んだ別 run のチケットのほうが早い epoch に
        // なり、build を終えて戻ってきた自分が FIFO で追い越される
        let ticket = DispatchTicketIssuer.issue(runGroup: runGroup)
        setenv(DispatchTicket.environmentKey, ticket.environmentValue, 1)

        // **この Mac のロックを、ビルド/一覧取得より前に取る**(ユーザー決定「1つのマシンで同時に複数の run は
        // 走らせない」・規律③「取るのは run の入口」)。**build を直列化するための一時的な先取り** —— 配分が確定したら
        // local に配られるかどうかに関わらず必ず手放す(下)。全順序どおりの本取得は `DispatchPrelock` が local を
        // 含めて改めて行う(RR-18.10)。待っていることは NDJSON にも出す(渡し忘れると api run の複数機械だけ
        // 実行ログビューが無言のまま止まって見える → MN-62.4)
        var localLock = try parentInterrupt.acquireLocalLock(log: log) {
            try LocalDispatchLock(
                runGroup: runGroup, waitLock: deadlineAtEntry.remaining(), forceLock: settings.forceLock, log: log,
                emitWaiting: settings.emitLocalLockWaiting).acquire(interruptCheck: parentInterrupt.isSet)
        }
        defer { localLock?.release() }

        let buildStart = Date()
        guard let (built, plan) = try build(parentInterrupt) else { return nil }
        let deadline = deadlineAtEntry.excluding(Date().timeIntervalSince(buildStart))

        // 配分が確定したら、build 直列化のために先取りしたロックは**local に配られたかどうかに関わらず**必ず手放す
        // (下の DispatchPrelock が local を含めて全順序どおり取り直すため。手放さずに残すと local だけ順序の外に
        // 出た「取得済み」扱いになり、循環待ちを作れる形へ戻る。使用中の待ちを握ったまま待つと他の run も待たせる)
        localLock?.release()
        localLock = nil

        // 手元のデバイスの二重使用は**どの機械へも配る前に**断る。dispatch.lock より手前なのは意図 —— 読み取りだけの
        // 先読みで、どのロックも取る前に断る(理由は FTBridgeClient/RunLeaseGuard.swift の冒頭)。
        // 待ちの上限は入口で決めた期限の残り(段ごとに `--wait-lock` を払い直さない)
        for check in plan.leaseChecks {
            try ProfileRunner.rejectIfLocalDevicesLeasedBeforeDispatch(
                project: check.project, profileName: check.profileName, setOverrides: settings.setOverrides,
                localDeviceNames: check.localDeviceNames, localScenarios: check.localScenarios,
                broadcast: check.broadcast, waitLock: deadline.remaining(),
                interruptCheck: parentInterrupt.isSet, log: log, emitWaiting: settings.emitLocalDevicesWaiting)
        }

        if let announceBeforePrelock {
            try parentInterrupt.exitIfSet(noticedAt: "the scenario assignment", log: log)
            announceBeforePrelock()
        }

        // **親が機械の全順序どおりに1台ずつ取り切ってから子を起こす**(DispatchPrelock。local も他の機械と同じ扱いで、
        // 上で発行し環境へ書いたチケットを引く)。機械ごとの待ちも期限の残りで決める
        let lock = DispatchPrelock(actions: DispatchPrelock.live(
            project: plan.prelockProject, remoteDir: settings.remoteDir, forceLock: settings.forceLock,
            waitLockProvider: { deadline.remaining() },
            runGroup: runGroup, mode: settings.mode, log: log))
        prelock = lock
        // 戻り値 false = 中断されて、ここまでに握った分は既に外し終えている(DispatchPrelock の宣言)。
        // **子を1つも起こさずに抜ける**(中断済みなのに複数機械へ run を撃つと、届いていた分の二重実行になりうる)
        guard lock.acquireInOrder(machines: DispatchPrelock.machinesToLock(plan.machines)) else {
            throw DeviceMachineRunner.interruptedBeforeAnySubRun
        }
        succeeded = true
        return (Held(parentInterrupt: parentInterrupt, runGroup: runGroup, ticket: ticket,
                     prelock: lock), built)
    }
}
