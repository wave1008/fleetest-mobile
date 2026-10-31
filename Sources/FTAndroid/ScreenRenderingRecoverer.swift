// 描画の状態(白紙・文字消え)を見つけたデバイスの回復の本番の実体(OI-88)。手順と台帳は FTCore.ScreenRenderingRecovery。
// - 撃つ操作は凍結の回復と同じ関数(`DisplayFreezeWatch.productionRepair` = iOS は backboardd(全面一様のときだけ)→ shutdown/boot、
//   Android は sleep/wake → ゲストの再起動 → 停止と起動)。段を足さない
// - 実機は見ない(再起動しない・切り離しもしない)
// - 直後の確かめは OS 側の絵が全面一様でないこと(再起動後はブリッジもアプリも居ないのでホーム画面が描かれているかまで)。
//   アプリの白紙・文字消えそのものが消えたかは次の検出が決める(同じ状態を再び検出したら台帳が撃たずに案内へ回す)

import FTBridgeClient
import FTCore
import Foundation

public enum ScreenRenderingRecoverer {
    /// 離脱したレーンのデバイスへ回復を1回撃つ(RunOrchestrator.recoverRendering の本番)
    public static func recover(_ worker: RunWorker, state: DeviceScreenState, repoRoot: URL, locale: String,
                               log: @escaping @Sendable (String) -> Void) async -> RenderingRecoveryOutcome {
        guard let key = DisplayFreezeWatch.key(of: worker) else { return .notAttempted }
        log("🔧 \(worker.label): the screen was reported as \(state.rawValue) — restarting the device while it is idle")
        let outcome = await ScreenRenderingRecovery.run(
            key: key, name: displayName(worker), stateDir: repoRoot.appendingPathComponent(".fleetest"),
            repair: {
                // run の中では複数のレーンが同時に離脱する。一斉の起動は描画の凍結の引き金なので Emulator も同時2台まで(Simulator は SimulatorBootSlots)
                await restartSlots.acquire()
                let kind = await DisplayFreezeWatch.productionRepair(
                    worker, stillFrozen: stillBad(worker), sleepWakeMeasurable: sleepWakeMeasurable(state),
                    repoRoot: repoRoot, locale: locale, log: log)
                await restartSlots.release()
                return kind
            },
            drawn: { await isDrawing(worker) }, log: log)
        // 撃てなかった理由がデバイスの消失なら事実として返す(呼び手が「再起動した」と記録しない)
        if outcome == .notAttempted, isGone(worker) {
            log("⚠️ \(worker.label): the device disappeared while it was being restarted")
            // 止めて戻せなかった台: 撃った事実を台帳に戻す(次の機会にまた撃たない)
            ScreenRecoveryLedger.markFired(stateDir: repoRoot.appendingPathComponent(".fleetest"), key: key)
            return .deviceGone
        }
        return outcome
    }

    public static func isGone(_ worker: RunWorker) -> Bool {
        if worker.platform == "ios" {
            return worker.connection.udid.map { simulatorIsDown(simctlList(udid: $0), udid: $0) } == true
        }
        return worker.platform == "android" && worker.connection.serial.map { DisplayFreezeWatch.deviceIsGone(serial: $0) } == true
    }

    private static func simctlList(udid: String) -> String? {
        (try? Shell.run(["xcrun", "simctl", "list", "devices"]))?.outputIfSucceeded
    }

    /// 起動していないと読めたときだけ true。読めない(nil)は消えたと言わない
    static func simulatorIsDown(_ list: String?, udid: String) -> Bool {
        guard let line = list?.split(separator: "\n").first(where: { $0.contains(udid) }) else { return false }
        return !line.contains("(Booted)")
    }

    /// この実行の run の前の点検で除外した台。供給の後で作る RunOrchestrator の最後の案内が引く(1プロセス = 1 run)
    public static let excludedBeforeRun = LockedValue<Set<String>>([])

    static let restartSlots = RestartSlots(limit: SimulatorBootSlots.concurrency)

    /// 同時に修復を撃てる台数の枠(プロセスの中)
    actor RestartSlots {
        private let limit: Int
        private var held = 0
        private var waiting: [CheckedContinuation<Void, Never>] = []

        init(limit: Int) { self.limit = limit }

        func acquire() async {
            if held < limit {
                held += 1
                return
            }
            await withCheckedContinuation { waiting.append($0) }
        }

        func release() {
            if waiting.isEmpty {
                held -= 1
            } else {
                waiting.removeFirst().resume()
            }
        }
    }

    static func displayName(_ worker: RunWorker) -> String { worker.connection.deviceName ?? worker.logicalName ?? worker.label }

    /// sleep/wake の後に「まだ直っていない」か(OS 側の絵が一様なまま)
    static func stillBad(_ worker: RunWorker) -> @Sendable () async -> Bool {
        { !(await isDrawing(worker)) }
    }

    /// 文字消えは絵が一様にならないので sleep/wake の効きを絵で測れない = 撃たずゲストの再起動へ進む
    static func sleepWakeMeasurable(_ state: DeviceScreenState) -> Bool { state != .textless }

    /// OS 側の絵が全面一様でない(描かれている)か。撮れないときは描かれているとは言わない
    public static func isDrawing(_ worker: RunWorker) async -> Bool {
        if worker.platform == "android" {
            guard let serial = worker.connection.serial else { return false }
            return await AndroidHealthProbe.isDrawingObserved(serial: serial)
        }
        guard let udid = worker.connection.udid else { return false }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(SimulatorDisplayServer.drawingWaitSeconds)
        while true {
            if let frame = DisplayFreezeWatch.simulatorScreenshot(udid: udid), !SimulatorDisplayServer.isBlankFrame(frame) { return true }
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .seconds(SimulatorDisplayServer.pollSeconds))
        }
    }

    public struct PreRun {
        public var workers: [RunWorker]
        public var excludedWorkers: [RunWorker] = []
        public var repairedWorkers: [RunWorker] = []
        public var anomalies: [WorkerAnomalyRecord] = []
    }

    /// run の前の点検: 描画の状態が公表されたまま残っている Simulator / Emulator を、使う前に1回だけ回復する(台帳を通す)。
    /// 戻らなかった・今回の起動以降すでに撃っているデバイスは使わず run を続ける。**全部がそうなら使う**(全滅を作らない)。
    /// `recoverIOS` = 凍結の回復と同じ iOS の再起動 + ブリッジの張り直し(`recoverFrozenIOSWorkers`。nil = 張り直せなかった)
    public static func prepareBeforeRun(
        _ workers: [RunWorker], stateDir: URL, locale: String, repoRoot: URL,
        recoverIOS: @Sendable ([String], [RunWorker], _ onDisplayServerRestored: @escaping @Sendable (String) -> Void) async -> [RunWorker]?,
        isStopped: @Sendable () -> Bool,
        bootTime: Date? = MachineBoot.time(),
        drawing: @Sendable (RunWorker) async -> Bool = isDrawing,
        deviceGone: @Sendable (RunWorker) -> Bool = isGone,
        repairAndroid injectedRepair: (@Sendable (RunWorker, DeviceScreenState) async -> WorkerRecoveryKind?)? = nil,
        log: @escaping @Sendable (String) -> Void) async -> PreRun {
        let repairAndroid = injectedRepair ?? { worker, state in
            await DisplayFreezeWatch.productionRepair(worker, stillFrozen: stillBad(worker),
                                                      sleepWakeMeasurable: sleepWakeMeasurable(state),
                                                      repoRoot: repoRoot, locale: locale, log: log)
        }
        var result = PreRun(workers: workers)
        var published: [(worker: RunWorker, key: String, state: DeviceScreenState)] = []
        for worker in workers {
            guard let key = DisplayFreezeWatch.key(of: worker),
                  let state = DeviceScreenStateStore.current(stateDir: stateDir, key: key) else { continue }
            published.append((worker, key, state))
        }
        guard !published.isEmpty else { return result }
        var unrecovered: [(worker: RunWorker, state: DeviceScreenState)] = []
        var gone: [RunWorker] = []
        var fired: [(worker: RunWorker, key: String, state: DeviceScreenState)] = []
        for entry in published {
            // 中断後は台帳にも触らない(begin は撃つ前に記録する = 撃たない台に残すと、以降マシンの再起動まで回復されない)
            if isStopped() { break }
            let name = displayName(entry.worker)
            // **撃った後の台は、残った印だけで除外しない**: 除外すると緑の確かめが来ないので案内がマシンの再起動まで消えない。
            // 今の絵で描けていれば印だけ消して使う(文字消えは絵で測れないので使う = 再発すれば run の中の検出が案内する)。
            // **案内(UnrecoveredDeviceStore)は消さない** —— 消すのは緑の確かめ(FTRuntime の screenStatePublisher)かマシンの再起動だけ。
            // 絵が一様でないことは「文字が描けている」の根拠にならない
            if ScreenRecoveryLedger.action(stateDir: stateDir, key: entry.key, bootTime: bootTime) == .advise,
               await drawing(entry.worker) {
                DeviceScreenStateStore.clear(stateDir: stateDir, key: entry.key)
                log("→ \(entry.worker.label): the published \(entry.state.rawValue) state was cleared — the screen is drawing"
                    + " (the reboot advice stays until a scenario passes on this device)")
                continue
            }
            if ScreenRenderingRecovery.begin(key: entry.key, name: name, stateDir: stateDir, bootTime: bootTime) == .fire {
                fired.append(entry)
            } else {
                log("⚠️ \(entry.worker.label): a \(entry.state.rawValue) screen is still published, but this device was already"
                    + " restarted since the machine started — not restarting it again; restarting the machine is recommended")
                unrecovered.append((entry.worker, entry.state))
            }
        }
        // iOS は1回の呼び出しで束ねる(ブリッジを止めて落として張り直すまでが1セット・2台ずつ)。Android は1台ずつ直列
        // (同時の起動は描画の凍結の引き金になる = 凍結の回復と同じ)
        let iosFired = fired.filter { $0.worker.platform == "ios" }
        var current = workers
        // 中断後に撃たない。begin で記録した台帳は戻す(撃っていない台を「撃った」にしない)
        func restoreLedger(_ entries: [(worker: RunWorker, key: String, state: DeviceScreenState)]) {
            for entry in entries {
                _ = ScreenRenderingRecovery.conclude(key: entry.key, name: displayName(entry.worker), stateDir: stateDir,
                                                     kind: nil, drawn: false)
            }
        }
        if !iosFired.isEmpty && isStopped() {
            restoreLedger(iosFired)
        } else if !iosFired.isEmpty {
            log("🔧 restarting \(iosFired.count) simulator(s) that still show a published screen state (\(iosFired.map(\.worker.label).joined(separator: ", ")))")
            let restored = LockedValue<Set<String>>([])
            let rebuilt = await recoverIOS(iosFired.map(\.worker.label), workers) { udid in
                restored.withLock { _ = $0.insert(udid) }
            }
            // `recoverFrozenIOSWorkers` はプロファイルの全台を作り直す = 直前の点検が除外した台を戻さない
            let kept = Set(workers.map { DisplayFreezeWatch.key(of: $0) })
            if let rebuilt { current = rebuilt.filter { kept.contains(DisplayFreezeWatch.key(of: $0)) } }
            for entry in iosFired {
                let after = rebuilt.flatMap { list in list.first { DisplayFreezeWatch.key(of: $0) == entry.key } } ?? entry.worker
                let drawn = rebuilt == nil ? false : await drawing(after)
                let kind: WorkerRecoveryKind? = rebuilt == nil ? nil
                    : restored.withLock { $0.contains(entry.key) } ? .displayServerRestart : .deviceRestart
                let outcome = ScreenRenderingRecovery.conclude(
                    key: entry.key, name: displayName(after), stateDir: stateDir, kind: kind, drawn: drawn)
                record(outcome, entry: (after, entry.state), into: &result, unrecovered: &unrecovered, gone: &gone)
            }
        }
        for entry in fired where entry.worker.platform == "android" {
            if isStopped() {
                restoreLedger([entry])
                continue
            }
            var outcome = await ScreenRenderingRecovery.fire(
                key: entry.key, name: displayName(entry.worker), stateDir: stateDir,
                repair: { await repairAndroid(entry.worker, entry.state) },
                drawn: { await drawing(entry.worker) }, log: log)
            if outcome == .notAttempted, deviceGone(entry.worker) {
                log("⚠️ \(entry.worker.label): the device disappeared while it was being restarted")
                outcome = .deviceGone
            }
            record(outcome, entry: (entry.worker, entry.state), into: &result, unrecovered: &unrecovered, gone: &gone)
        }
        result.workers = current
        let goneKeys = Set(gone.map { DisplayFreezeWatch.key(of: $0) })
        let bad = Set(unrecovered.map { DisplayFreezeWatch.key(of: $0.worker) }).union(goneKeys)
        for entry in unrecovered { result.anomalies.append(WorkerAnomalyRecord.rebootAdvice(entry.worker, state: entry.state)) }
        let candidates = current.filter { !bad.contains(DisplayFreezeWatch.key(of: $0)) }
        // 全部が戻らなかったなら使う(全滅を作らない)。除外は「他に使える台がある」ときだけ
        if !candidates.isEmpty && candidates.count < current.count {
            result.excludedWorkers = current.filter { bad.contains(DisplayFreezeWatch.key(of: $0)) }
            result.workers = candidates
            excludedBeforeRun.withLock { $0.formUnion(bad.compactMap { $0 }) }
            func isGoneWorker(_ worker: RunWorker) -> Bool { goneKeys.contains(DisplayFreezeWatch.key(of: worker)) }
            func why(_ worker: RunWorker) -> String {
                isGoneWorker(worker) ? "the device disappeared while it was being restarted"
                    : "restarting the device did not bring the screen back"
            }
            result.anomalies += WorkerAnomalyRecord.preRunTriage(
                excluded: result.excludedWorkers, repaired: [],
                excludedReasons: Dictionary(uniqueKeysWithValues: result.excludedWorkers.map {
                    ($0.label, "excluded before the run started: \(why($0))") }),
                excludedCauses: Dictionary(uniqueKeysWithValues: result.excludedWorkers.filter(isGoneWorker).map {
                    ($0.label, WorkerAnomalyCause.deviceGone) }))
            for worker in result.excludedWorkers {
                log("⚠️ \(worker.label): excluded from this run — \(why(worker))")
            }
        } else {
            // 使うしかない(全台が戻らなかった)ときも、消えた事実は記録に残す
            for worker in gone {
                result.anomalies.append(WorkerAnomalyRecord(
                    kind: "degraded", worker: RunOrchestrator.workerID(worker), label: worker.label,
                    reason: "the device disappeared while it was being restarted", cause: .deviceGone))
            }
        }
        return result
    }

    private static func record(_ outcome: RenderingRecoveryOutcome, entry: (worker: RunWorker, state: DeviceScreenState),
                               into result: inout PreRun,
                               unrecovered: inout [(worker: RunWorker, state: DeviceScreenState)],
                               gone: inout [RunWorker]) {
        switch outcome {
        case .recovered(let kind):
            result.repairedWorkers.append(entry.worker)
            result.anomalies += WorkerAnomalyRecord.preRunTriage(
                excluded: [], repaired: [entry.worker], repairedRecovery: [entry.worker.label: kind])
        case .notRecovered, .advised:
            unrecovered.append(entry)
        case .deviceGone:
            gone.append(entry.worker)
        case .notAttempted:
            break
        }
    }
}
