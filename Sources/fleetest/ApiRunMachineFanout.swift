// ApiRunMachineFanout.swift
// `fleetest api run --profile <p>` で p のデバイスが複数の機械にまたがるときの実行
// (RR-13)。DeviceMachineRunner(`fleetest run` の同じ状況)と同じ割り当て
// (build→list→resolve→assign)を再利用し、ホストごとに `fleetest api run --runner <label> …` を
// 子プロセスとして並行に起動、NDJSON を1本の stdout ストリームへ多重化する。
//
// 拡張(vscode-fleetest/src/model.ts)は「1本の NDJSON = runStarted → workersReady →
// (各種イベント) → runFinished」という契約しか知らない。子1つにつき1本ずつ来る同じ形の
// ストリームを、runStarted/runFinished は集計してこちらが1回だけ出し、workersReady は
// **子ごとに届くたび**それまでの累積(子 index 順)で合成して出し直し、それ以外は worker
// フィールドをホスト付き id(FTCore.DeviceMachineGrouping.workerID)へ書き換えて**即時**中継する
// (バッファしない = リモート機の準備待ちでローカル分の表示が止まらない)。
// 子が担当シナリオを残して終了したら、そのシナリオを failed として合成イベントで報告する。

import ArgumentParser
import FTCore
import FTRemote
import Foundation

enum ApiRunMachineFanout {

    /// 子プロセスへ素通しするオプション。skipBuild/folders は無い —— ビルドは常にここで1回だけ
    /// 行う(DeviceMachineRunner.run と同じ理由。シナリオ一覧が割り当てに要る)。--report-dir は
    /// 意図的に含めない: リモートホストの子は `dispatchToRemoteHost` が --report-dir を
    /// 常に拒否するため(RemoteDispatchFlagPolicy.rejected)、一部のホストにだけ効く/効かないが
    /// 混在する形になる。CLI 側の多機械ディスパッチ(DeviceMachineRunner/FleetRunner)も同じ理由で
    /// --report-dir を子へ渡していない(既存の踏襲)
    struct Options {
        var setOverrides: [String: RunProfileSetValue] = [:]
        var defaultTimeout: Double?
        var scenarioTimeout: Int?
        var noLPT: Bool
        var lptHistoryRuns: Int?
        var performanceMode: Bool
        var remoteDir: String?
        var remoteTimeout: Int?
        /// `--wait-lock <秒>`。**親の待ち(先読み・DispatchPrelock)にだけ使い、子へは渡さない**
        /// (下の args 組み立てと RR-18.10)。ここに無いと、拡張の設定 `fleetest.remoteWaitLock` が
        /// **複数機械にまたがるプロファイルでだけ黙って落ちる** —— 共有フリートで一番待ちたい形がまさにそれ
        var waitLock: Int?
    }

    /// 戻り値 = FleetProfile.aggregateExitCode(各ホストの exit code の集約)
    static func run(
        project: TestProject, profileName: String, groups: [DeviceMachineRunner.Group],
        scenarios: [String], options: Options
    ) async throws -> Int32 {
        let machineList = groups.map { "\($0.machineLabel)(\($0.deviceNames.count))" }.joined(separator: " + ")
        logStderr("==> profile \"\(profileName)\" spans \(groups.count) machines: \(machineList)"
            + " — building \(project.name) locally to split the scenarios")
        // **中断で抜けるときに runFinished を補わない**: 拡張は runFinished の無いままプロセスが終わったら、その時点で
        // 走っている表示を解き「取り消した」と出す(runHandler.ts の `!sawEnd`・runLaneModel.ts の forceEndRunLaneState)。
        // 0 件の runFinished を補うと、取り消しを正常終了(0 passed, 0 failed)に見せてしまう
        // 自己修復の書き戻しは全機械の子が終わってから親が1回だけ(HealSourceWriteBack.Collection)
        let healCollection = HealSourceWriteBack.Collection()
        // 前段(入口の印・チケット・手元のロックの先取り・ビルド・使用中の待ち・Prelock)は MachineFanoutFrontHalf の1箇所。
        // ここが持つのは差分 = NDJSON の出し口・シナリオ一覧の取得と配分・runStarted。
        // runStarted を Prelock の後へ動かさないのは、待っている間の total を拡張に出すため(runStarted は拡張のレーン状態を
        // 作り直す合図なので、待ちの dispatchWaiting より前に要る)
        typealias Active = [(index: Int, group: DeviceMachineRunner.Group, ids: [String])]
        typealias DynamicPlan = (scenarios: [DynamicSplit.Scenario],
                                 estimate: @Sendable (DynamicSplit.Scenario, Int) -> Double)
        let totalScenarios = LockedValue(0)
        guard let (held, built) = try MachineFanoutFrontHalf.run(
            settings: .init(
                mode: .apiRun, remoteDir: options.remoteDir, forceLock: false, waitLock: options.waitLock,
                setOverrides: options.setOverrides, log: { logStderr($0) },
                emitLocalLockWaiting: LocalDispatchLock.apiRunWaitingEmitter(),
                emitLocalDevicesWaiting: { ApiLocalDevicesWaitingEvent.emit(elapsedSeconds: $0, limitSeconds: $1) }),
            announceBeforePrelock: {
                // total は対象外を除いた本数(単機の ApiRunCommand と同じ: スキップは runStarted に数えない)
                writeLine(encode(ApiRunStartedEvent(total: totalScenarios.value)))
            },
            build: { parentInterrupt -> (built: (Active, DynamicPlan?), plan: MachineFanoutFrontHalf.Plan)? in
                // 割り当てを決めるにはシナリオ一覧が要る(DeviceMachineRunner.run と同じ理由。ここで1回だけ
                // ローカルビルドする。ローカルの子には --skip-build を渡す = 下の buildChildArgs 参照)
                let all = try parentInterrupt.stage("the scenario build", log: { logStderr($0) }) {
                    try ScenarioHost.build(project: project) { logStderr($0) }
                    return try ScenarioHost.list(project: project)
                }
                guard !all.isEmpty else {
                    throw ValidationError(
                        "no scenarios (add a @TestClass under TestProjects/\(project.name)/scenarios/)")
                }
                let selected = try ScenarioSelection.resolve(scenarios, from: all)
                guard !selected.isEmpty else {
                    throw ValidationError("no scenarios to run after filtering")
                }

                // 動的な割り振り(RR-8.1。DeviceMachineRunner.run と同じ分岐。FT_STATIC_SPLIT=1 で静的へ戻る)
                let notApplicable: [ScenarioInfo]
                let active: [(index: Int, group: DeviceMachineRunner.Group, ids: [String])]
                var dynamicPlan: (scenarios: [DynamicSplit.Scenario],
                                  estimate: @Sendable (DynamicSplit.Scenario, Int) -> Double)?
                if DeviceMachineRunner.dynamicSplitEnabled(
                    broadcast: false,
                    measuresResponse: ProfileResolver.declaresResponseMeasurement(
                        project: project, runName: profileName, overrides: options.setOverrides)) {
                    let split = DeviceMachineRunner.splitApplicable(selected: selected, groups: groups)
                    notApplicable = split.notApplicable
                    let resolved = DynamicDispatcher.resolve(
                        split.runnable.map { (id: $0.id, platform: $0.platform) },
                        defaultPlatform: DynamicDispatcher.undeclaredPlatform(groups: groups))
                    active = groups.indices.compactMap { index in
                        let ids = DynamicDispatcher.candidateIDs(for: groups[index], in: resolved)
                        return ids.isEmpty ? nil : (index, groups[index], ids)
                    }
                    if !active.isEmpty {
                        let inputs = DeviceMachineRunner.estimationInputs(
                            project: project, groups: groups, lptHistoryRuns: options.lptHistoryRuns)
                        dynamicPlan = (resolved, DeviceMachineRunner.dynamicEstimator(inputs: inputs, groups: groups))
                    }
                } else {
                    let (buckets, basis, notApplicableStatic) = try DeviceMachineRunner.assign(
                        project: project, groups: groups, selected: selected,
                        lptHistoryRuns: options.lptHistoryRuns)
                    notApplicable = notApplicableStatic
                    active = groups.indices.compactMap { index in
                        let ids = buckets[index].scenarioIDs
                        return ids.isEmpty ? nil : (index, groups[index], ids)
                    }
                    // CLI と同じ「見積りの根拠」を拡張の OUTPUT にも出す(片方だけ見える情報を作らない)
                    for (index, group, ids) in active {
                        logStderr("    \(group.machineLabel): \(ids.count) scenario(s)"
                            + " on \(group.deviceNames.count) device(s) [\(basis[index].summary)]")
                    }
                }
                for line in DeviceMachineRunner.notApplicableLines(notApplicable, groups: groups) { logStderr(line) }
                // 全部が宣言 platform の対象外なら単機の run と同じく 0/0 で終える(正しく緑)。
                // それ以外で全滅(= 対象外でもないのに割り当て 0)は FleetSplit.partition が設定ミスとして
                // throw 済みなので、ここへは来ない
                guard !active.isEmpty else {
                    writeLine(encode(ApiRunStartedEvent(total: 0)))
                    writeLine(encode(ApiRunFinishedEvent(
                        passed: 0, failed: 0, skipped: 0,
                        testSeconds: nil, scenarioTotalSeconds: nil,
                        runID: nil)))
                    return nil
                }
                if let dynamicPlan {
                    logStderr("==> dynamic split: \(dynamicPlan.scenarios.count) scenario(s) across \(active.count) machine(s)"
                        + " — each free device takes the next scenario")
                } else {
                    for (_, group, ids) in active {
                        logStderr("    \(group.machineLabel): \(ids.count) scenario(s) on \(group.deviceNames.count) device(s)")
                    }
                }

                totalScenarios.withLock { $0 = selected.count - notApplicable.count }
                var leaseChecks: [MachineFanoutFrontHalf.LeaseCheck] = []
                if let local = active.first(where: { $0.group.machine == nil }) {
                    let ids = Set(local.ids)
                    leaseChecks.append(.init(
                        project: project, profileName: profileName, localDeviceNames: local.group.deviceNames,
                        localScenarios: selected.filter { ids.contains($0.id) }, broadcast: false))
                }
                return ((active, dynamicPlan), .init(
                    leaseChecks: leaseChecks, machines: active.map { $0.group.machineLabel }, prelockProject: project))
            }) else { return 0 }
        defer { held.close() }
        let (active, dynamicPlan) = built
        let runGroup = held.runGroup
        let ticket = held.ticket
        let prelock = held.prelock
        let parentInterrupt = held.parentInterrupt

        let binary = FleetRunner.selfBinaryPath()
        let lockMarkers = held.lockMarkers
        let (stream, continuation) = AsyncStream<ChildEvent>.makeStream()
        let groupMachines = active.map { $0.group.machine }

        // 拡張のキャンセル(SIGTERM/SIGINT)・stdin EOF のどちらでも全子へ SIGTERM を送る。
        // 子(単発の `fleetest api run --runner <label>`)は自分ではシグナルを捕まえないので既定の
        // 即時終了になり、リモート子はその内部の ssh(-tt 付き)が親の死で SIGHUP を孫プロセスへ
        // 伝える(RemoteRunDispatcher.sshRunBase の宣言と同じ機構)。単発 `api run --runner` は
        // 自分自身が拡張の直接の子なので OS がこの経路で保護するが、ここは**この fanout が
        // 増やした孫プロセス**を対象にする(既存の保護の外側)
        let registry = ChildProcessRegistry()

        // 動的な割り振り: 子ごとの stdin 書き込み口(キーは groups の添字 = 配り手のエントリ番号)と配り手。
        // 中断は親が受けて全要求へ none を返す(子も自分の待ちを解く = ScenarioPullSource.stopWaiting)
        let writers: [Int: ChildStdinWriter] = dynamicPlan == nil ? [:]
            : Dictionary(uniqueKeysWithValues: active.map { ($0.index, ChildStdinWriter()) })
        let dispatcher: DynamicDispatcher? = dynamicPlan.map { plan in
            DynamicDispatcher(scenarios: plan.scenarios, estimateMs: plan.estimate, lpt: !options.noLPT,
                              send: { entry, reply in writers[entry]?.write(line: WorkQueueProtocol.encode(reply)) })
        }

        // assignedScenarioIDs は active と同じ並び(下の taskGroup が position をそのまま
        // childIndex として runChild へ渡すのと同じ基準)。isCancelled はキャンセル後の
        // 合成 failed を抑止する(キャンセルで子は非0終了するため、抑止しないと中断した
        // シナリオが failed として赤く出る。キャンセル≠失敗)
        async let multiplexed = consume(
            stream: stream, groupMachines: groupMachines, assignedScenarioIDs: active.map { $0.ids },
            isCancelled: { registry.isCancelled })
        // 中断(拡張のキャンセル = SIGTERM・端末の SIGINT)で子を止めて配るのをやめる。catchUp: ロックの取得中
        // (DispatchPrelock の購読が受けた)の中断も、ここで伝える = 自前のシグナルソースは過去の中断を知らない。
        // **stdin の EOF を打ち切りの合図に使わない** —— api run は --debug 以外 stdin を読まず、拡張は stdio[0] を
        // "ignore"(= /dev/null)で起動する。EOF を見ると起動と同時に全子を殺す(実際に exit=15 で全滅した)
        let cancelRelay = InterruptRelay.observing(catchUp: true) {
            registry.terminateAll()
            dispatcher?.interrupt()
        }
        defer { cancelRelay.stop() }
        // 購読の登録より前の中断は子を起こす前に抜ける(DeviceMachineRunner.run の同じ箇所)
        try held.exitIfInterruptedBeforeLaunch(log: { logStderr($0) })

        let isInterrupted = parentInterrupt.isSet
        let interruptedAtLastExit = LockedValue(false)
        let outcomes = await withTaskGroup(of: (Int, FleetEntryOutcome).self) { taskGroup in
            for (position, entry) in active.enumerated() {
                let (groupIndex, group, ids) = entry
                taskGroup.addTask {
                    let args = buildArgs(
                        project: project.name, profileName: profileName, group: group,
                        scenarioIDs: ids, options: options, runGroup: runGroup,
                        workQueue: dispatcher != nil)
                    var childDispatch: (dispatcher: DynamicDispatcher, entry: Int, writer: ChildStdinWriter)?
                    if let dispatcher, let writer = writers[groupIndex] {
                        childDispatch = (dispatcher, groupIndex, writer)
                    }
                    let start = Date()
                    let exitCode = await runChild(
                        index: position, binary: binary, args: args, machineLabel: group.machineLabel,
                        ticket: ticket, lockMarker: lockMarkers[group.machineLabel],
                        healCollection: healCollection,
                        continuation: continuation, registry: registry,
                        dispatch: childDispatch)
                    return (position, FleetEntryOutcome(
                        host: group.machineLabel, profile: profileName, exitCode: exitCode,
                        duration: Date().timeIntervalSince(start)))
                }
            }
            var collected: [Int: FleetEntryOutcome] = [:]
            for await (position, outcome) in taskGroup {
                // ロックの解放(ssh で秒単位)より前に取る = 最後の子が終わった時点の値(MultiTargetRunner と同じ時点)
                interruptedAtLastExit.withLock { $0 = isInterrupted() }
                collected[position] = outcome
                prelock.release(afterChildOf: outcome.host, exitCode: outcome.exitCode)
            }
            return (0..<active.count).compactMap { collected[$0] }
        }
        // 子が全員終わった時点の値で仕分ける(後の解放・多重化の待ちの間に来た中断で、本物の欠落を中断に読み替えない。
        // DeviceMachineRunner.run と同じ)。配り手の印・registry の取り消しを立てるのも中断の購読だけ
        let interruptedWhileChildrenRan = interruptedAtLastExit.value
        // 残りの安全網(各機械は子の終了時に解放済み。理由は DeviceMachineRunner.run と同じ)
        prelock.releaseAll(exitCodes: Dictionary(
            outcomes.map { ($0.host, $0.exitCode) }, uniquingKeysWith: { first, _ in first }))
        // 全部の子が終わっても誰にも渡せなかった分は失敗として報告する(中断なら失敗にしない)
        var neverHandedFailure = false
        var interruptedWithWorkLeft = false
        if let dispatcher {
            let ids = dispatcher.unhandedIDs
            if !ids.isEmpty {
                let interrupted = interruptedWhileChildrenRan
                interruptedWithWorkLeft = interrupted
                logStderr(DeviceMachineRunner.neverHandedLine(ids: ids, interrupted: interrupted))
                if !interrupted {
                    neverHandedFailure = true
                    continuation.yield(.neverHanded(ids))
                }
            }
        }
        // 全子が最後の .exited を継続へ渡し終えたあとでのみ finish してよい(withTaskGroup は
        // 各子タスクの return を待つので、この時点で runChild は必ず .exited を yield 済み)
        continuation.finish()

        let (totalPassed, totalFailed, totalSkipped, runID, testSeconds, unfinishedTotal) = await multiplexed
        // 配ったのに子が終わりを知らせなかった分(子が受け取る前の中断など)。中断なら 130・それ以外は 1
        if unfinishedTotal > 0 {
            if interruptedWhileChildrenRan {
                interruptedWithWorkLeft = true
            } else {
                neverHandedFailure = true
            }
        }
        // finished の前(単機の api run と同じ。拡張は finished で通知を出す)
        healCollection.finish(project: project) { logStderr($0) }
        writeLine(encode(ApiRunFinishedEvent(
            passed: totalPassed, failed: totalFailed, skipped: totalSkipped,
            testSeconds: testSeconds, scenarioTotalSeconds: nil,
            runID: runID)))

        logStderr("")
        logStderr("=== profile \"\(profileName)\" across machines ===")
        for outcome in outcomes {
            let mark = outcome.exitCode == 0 ? "✅" : "❌"
            logStderr(String(format: "%@ %-20@ exit=%d  %.1fs", mark, outcome.host as NSString,
                             outcome.exitCode, outcome.duration))
        }
        return DeviceMachineRunner.parentExitCode(
            childCodes: outcomes.map(\.exitCode), neverHandedFailure: neverHandedFailure,
            interruptedWithWorkLeft: interruptedWithWorkLeft)
    }

    // MARK: - 子プロセスの引数

    /// internal: 束ね鍵の中継を RunGroupPlumbingTests が等号で固定する
    static func buildArgs(
        project: String, profileName: String, group: DeviceMachineRunner.Group,
        scenarioIDs: [String], options: Options, runGroup: String, workQueue: Bool = false
    ) -> [String] {
        let machineLabel = group.machineLabel
        var args = ["api", "run", "--project", project, "--profile", profileName]
        // **常に --runner を渡す**(FleetRunner.buildArgs と同じ理由: 省略すると子が自分でマシン
        // プロファイルの host を再解決してしまう。"local" は MachineDispatch.resolve が
        // 明示指定として止める)
        args += ["--runner", machineLabel]
        // **--skip-build はローカル子だけ**(dispatchToRemoteHost が .explicitHost origin では
        // "--skip-build is not supported with --runner" で拒否する。RemoteDispatchFlagPolicy.skipBuild
        // の宣言参照。リモートは自前でビルドするので、渡す必要も無い)
        if machineLabel == DeviceMachineGrouping.localDisplayName {
            args += ["--skip-build"]
        } else {
            if let remoteDir = options.remoteDir { args += ["--remote-dir", remoteDir] }
            if let remoteTimeout = options.remoteTimeout { args += ["--remote-timeout", String(remoteTimeout)] }
            // **`--wait-lock` は子へ渡さない** —— 待つのは親(DispatchPrelock)の役目。
            // 親が取れた機械では子はロックを取りに行かず、取れなかった機械では親が既に
            // 上限まで待ったあとなので、渡すと同じ上限をもう一度払う(最悪で待ちが2倍)
        }
        // **ホストも渡す**(一意なのは (host, name)。ApiRunCommand.deviceMachine の宣言参照)
        args += ["--device"] + group.deviceNames
        args += ["--device-machine", machineLabel]
        args += ["--scenario"] + scenarioIDs
        // 動的な割り振り(RR-8.1)の子だけ。--scenario は全候補で、回すのは親が1本ずつ渡した分
        if workQueue { args += ["--work-queue"] }
        // 中継しないと黙って無視される(子はプロファイルの既定で走る。FleetRunner.buildArgs と同じ理由)
        for key in options.setOverrides.keys.sorted() {
            args += ["--set", "\(key)=\(options.setOverrides[key]!.token)"]
        }
        if options.noLPT { args += ["--no-lpt"] }
        if let lptHistoryRuns = options.lptHistoryRuns { args += ["--lpt-history-runs", String(lptHistoryRuns)] }
        if options.performanceMode { args += ["--performance"] }
        if let defaultTimeout = options.defaultTimeout { args += ["--default-timeout", String(defaultTimeout)] }
        if let scenarioTimeout = options.scenarioTimeout { args += ["--scenario-timeout", String(scenarioTimeout)] }
        args += ["--run-group", runGroup]
        return args
    }

    // MARK: - 子プロセス

    private enum ChildEvent {
        case line(index: Int, text: String)
        /// assigned = 動的な割り振りで実際に渡したシナリオ(静的は nil = 起動時の担当)
        case exited(index: Int, status: Int32, assigned: [String]?)
        /// 全部の子が終わっても誰にも渡せなかったシナリオ(失敗として合成する)
        case neverHanded([String])
    }

    /// 子1体ぶん。stdout(NDJSON)は行単位で continuation へ、stderr(診断)はホスト名を前置して
    /// そのまま親の stderr へ流す(stdout は NDJSON 専用の契約なので混ぜない)
    /// `ticket` は dispatch.lock の待機列の鍵。**親が1回だけ採ったものを受け取るだけ**で、
    /// ここで採り直さない(DispatchTicketIssuer の宣言)。`lockMarker` は親がこの機械の
    /// ロックを取れたときだけ非 nil(DispatchPrelock)
    private static func runChild(
        index: Int, binary: String, args: [String], machineLabel: String, ticket: DispatchTicket,
        lockMarker: String?, healCollection: HealSourceWriteBack.Collection,
        continuation: AsyncStream<ChildEvent>.Continuation, registry: ChildProcessRegistry,
        dispatch: (dispatcher: DynamicDispatcher, entry: Int, writer: ChildStdinWriter)? = nil
    ) async -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.environment = DispatchTicketIssuer.childEnvironment(ticket: ticket,
                                                                    lockHeldTarget: lockMarker,
                                                                    healCollection: healCollection)
        process.arguments = args
        let stdinPipe: Pipe? = dispatch == nil ? nil : Pipe()
        process.standardInput = stdinPipe ?? FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let exitStream = ProcessExitWait.prepare(process)
        // 起こす直前に中断を見る(FleetRunner.runEntry と同じ)。起こさなかった子は起動の失敗と同じ形で終わりを知らせる
        if InterruptRelay.hasReceivedInterrupt {
            logStderr("[\(machineLabel)] interrupted — this sub-run was not started")
            dispatch?.dispatcher.childExited(entry: dispatch?.entry ?? index)
            continuation.yield(.exited(index: index, status: 130,
                                       assigned: dispatch.map { $0.dispatcher.assignedIDs(entry: $0.entry) }))
            return 130
        }
        do {
            try process.run()
        } catch {
            logStderr("[\(machineLabel)] error: failed to launch subprocess: \(error.localizedDescription)")
            dispatch?.dispatcher.childExited(entry: dispatch?.entry ?? index)
            continuation.yield(.exited(index: index, status: 127,
                                       assigned: dispatch.map { $0.dispatcher.assignedIDs(entry: $0.entry) }))
            return 127
        }
        if let dispatch, let stdinPipe {
            // 親側の読み端を閉じる(子が死んだら書き込みが EPIPE で返る)
            try? stdinPipe.fileHandleForReading.close()
            dispatch.writer.attach(stdinPipe.fileHandleForWriting)
        }
        defer { dispatch?.writer.close() }
        registry.register(process)

        // `{"ftWork"` の行は NDJSON へ流さず、配り手が消費する(classify の前)
        let consumed: @Sendable (String) -> Bool = { line in
            guard let dispatch else { return false }
            return dispatch.dispatcher.intercept(line: line, entry: dispatch.entry, writer: dispatch.writer)
        }
        let stdoutPump = PipeLinePump(handle: stdoutPipe.fileHandleForReading) { line in
            if consumed(line) { return }
            continuation.yield(.line(index: index, text: line))
        }
        let stderrPump = PipeLinePump(handle: stderrPipe.fileHandleForReading) { line in
            logStderr("[\(machineLabel)] \(line)")
        }
        stdoutPump.start()
        stderrPump.start()

        for await _ in exitStream {}
        if let remaining = await stdoutPump.drain(), !consumed(remaining) {
            continuation.yield(.line(index: index, text: remaining))
        }
        if let remaining = await stderrPump.drain() { logStderr("[\(machineLabel)] \(remaining)") }
        dispatch?.dispatcher.childExited(entry: dispatch?.entry ?? index)
        continuation.yield(.exited(index: index, status: process.terminationStatus,
                                   assigned: dispatch.map { $0.dispatcher.assignedIDs(entry: $0.entry) }))
        return process.terminationStatus
    }

    // MARK: - キャンセル(孤児の ssh/子 run を残さない)

    /// 生きている子プロセスの集合。register() より前に cancel 済みなら、その場で即終了させる
    /// (シグナル到着とプロセス起動が競合しても取りこぼさない)
    private final class ChildProcessRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var processes: [Process] = []
        private var cancelled = false

        func register(_ process: Process) {
            lock.lock()
            let alreadyCancelled = cancelled
            if !alreadyCancelled { processes.append(process) }
            lock.unlock()
            if alreadyCancelled, process.isRunning { process.terminate() }
        }

        func terminateAll() {
            lock.lock()
            cancelled = true
            let toKill = processes
            lock.unlock()
            for process in toKill where process.isRunning { process.terminate() }
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    // MARK: - 多重化(I/O 側。純粋な状態機械は MachineFanoutMultiplexer)

    private static func consume(
        stream: AsyncStream<ChildEvent>, groupMachines: [String?], assignedScenarioIDs: [[String]],
        isCancelled: @escaping @Sendable () -> Bool
    ) async -> (passed: Int, failed: Int, skipped: Int, runID: String?, testSeconds: Double?, unfinished: Int) {
        var multiplexer = MachineFanoutMultiplexer(groupMachines: groupMachines, assignedScenarioIDs: assignedScenarioIDs)
        for await event in stream {
            switch event {
            case .line(let index, let text):
                for line in multiplexer.ingest(childIndex: index, line: text) { writeLine(line) }
            case .exited(let index, let status, let assigned):
                // キャンセルで殺された子の未完了は合成しない(キャンセル≠失敗)。数だけは控える(終了コードに載せる)
                guard !isCancelled() else {
                    _ = multiplexer.noteExit(index, assigned: assigned)
                    continue
                }
                for line in multiplexer.childExited(index, exitCode: status, assigned: assigned) { writeLine(line) }
            case .neverHanded(let ids):
                guard !isCancelled() else { continue }
                for line in multiplexer.neverHanded(ids) { writeLine(line) }
            }
        }
        return (multiplexer.totalPassed, multiplexer.totalFailed, multiplexer.totalSkipped,
                multiplexer.runID, multiplexer.testSeconds, multiplexer.unfinishedTotal)
    }

    // MARK: - 出力(FleetRunner.log/logLine と同じ規律。stdout は NDJSON 専用・行単位で lock)

    private static let stdoutLock = NSLock()

    private static func writeLine(_ line: String) {
        stdoutLock.lock()
        defer { stdoutLock.unlock() }
        ConsoleOut.out(line)
    }

    private static let stderrLock = NSLock()

    private static func logStderr(_ message: String) {
        stderrLock.lock()
        defer { stderrLock.unlock() }
        ConsoleOut.err(message)
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return #"{"kind":"log","message":"(encode error)"}"#
        }
        return text
    }
}

/// 子の NDJSON を1本へ多重化する状態機械(純粋・プロセス非依存。ApiRunMachineFanoutMultiplexerTests が
/// 直接叩く)。runStarted/runFinished は集計して捨てる。workersReady は**子ごとに届くたび**、
/// それまでに判明している全ワーカー(子 index 順の累積)で合成して出し直す —— 拡張側の
/// レーン構成は全置換だが同一 id のログは維持されるため、再送は増分の追加として映る
/// (vscode-fleetest/src/runLaneModel.ts applyWorkers と対)。他のイベントはバッファせず
/// 即時中継する(貯めると複数マシン実行の進行表示が最後に一括更新になる)。
/// 子が担当シナリオを残して終了したら、そのシナリオを failed の合成イベントで報告する
/// (沈黙のまま「走っていない」を作らない)。
struct MachineFanoutMultiplexer {
    private let groupMachines: [String?]
    /// 子 index → 担当シナリオ ID(合成 failed の対象を知るため)
    private var assignedScenarioIDs: [[String]]
    private var workersByIndex: [[ApiWorkerInfo]]
    private var finishedByIndex: [Set<String>]
    private(set) var totalPassed = 0
    private(set) var totalFailed = 0
    private(set) var totalSkipped = 0
    /// 担当していたのに終わりの知らせが来ないまま子が終わったシナリオの数(キャンセルで合成しなかった分も数える)。
    /// 親の終了コードに載せる(子が 0 で終わっても 0 にしない = 配ったのに子が受け取らなかった分を成功に化けさせない)
    private(set) var unfinishedTotal = 0
    /// 子の runFinished が運んだ runID のうち最初の1つ。子は同じ runGroup を共有するので
    /// どれでも束ねたセッション全体に届く(ApiRunFinishedEvent.runID の宣言参照)
    private(set) var runID: String?
    /// 子から中継した最初の scenarioStarted / 最後の scenarioFinished の時刻(親の時計)。
    /// 単機の `runFinished.testSeconds`(ScenarioTimingTracker = 最初のシナリオ開始〜最後の完了。
    /// ビルド・ロック待ち・供給・転送は含まない)と同じ意味の値を `testSeconds` で出すための材料。
    /// 子の testSeconds の最大値にしない: 子の起動時刻は機械ごとにずれる(ロック・ssh・ビルド)ので
    /// 区間が重ならず、最大値は全体の区間より短くなる
    private(set) var firstScenarioStart: Date?
    private(set) var lastScenarioFinish: Date?
    /// 単機の testSeconds と同じ定義。シナリオが1本も走っていなければ nil(単機も nil)
    var testSeconds: Double? {
        guard let first = firstScenarioStart, let last = lastScenarioFinish else { return nil }
        return last.timeIntervalSince(first)
    }
    /// recordingFinalizing は子ごとに来るので**全部の子がテストを終えた時点で1回だけ**出す
    /// (1台目の子の分をそのまま流すと、他の機械がまだテスト中なのに「録画を編集中」になる)。
    /// 終えた = 自分の recordingFinalizing を出したか、プロセスが終わったか(録画しない子は後者だけ)
    private var finalizingIndices: Set<Int> = []
    private var exitedIndices: Set<Int> = []
    private var finalizingRelayed = false

    init(groupMachines: [String?], assignedScenarioIDs: [[String]] = []) {
        self.groupMachines = groupMachines
        self.assignedScenarioIDs = assignedScenarioIDs.isEmpty
            ? Array(repeating: [], count: groupMachines.count)
            : assignedScenarioIDs
        self.workersByIndex = Array(repeating: [], count: groupMachines.count)
        self.finishedByIndex = Array(repeating: [], count: groupMachines.count)
    }

    /// 子(childIndex)からの1行。バッファせず、relay してよい行をそのまま返す
    /// now は時刻の注入点(テスト用。既定は実時刻)
    mutating func ingest(childIndex: Int, line: String, now: Date = Date()) -> [String] {
        switch Self.classify(line, host: groupMachines[childIndex]) {
        case .runStarted:
            return []
        case .runFinished(let passed, let failed, let skipped, let childRunID):
            totalPassed += passed
            totalFailed += failed
            totalSkipped += skipped
            if runID == nil { runID = childRunID }
            return []
        case .workersReady(let workers):
            workersByIndex[childIndex] = workers
            let merged = groupMachines.indices.flatMap { workersByIndex[$0] }
            return [Self.encode(ApiWorkersReadyEvent(workers: merged))]
        case .recordingFinalizing(let line):
            finalizingIndices.insert(childIndex)
            return relayFinalizingIfAllDone(line)
        case .other(let rewritten, let finishedScenario, let kind):
            // 合成の failed(childExited)は走った時間ではないので数えない
            if kind == "scenarioStarted" {
                firstScenarioStart = min(firstScenarioStart ?? now, now)
            } else if kind == "scenarioFinished" {
                lastScenarioFinish = max(lastScenarioFinish ?? now, now)
            }
            if let scenario = finishedScenario { finishedByIndex[childIndex].insert(scenario) }
            return [rewritten]
        }
    }

    /// 子プロセスの終了。担当していたが scenarioFinished が来ないまま終わったシナリオを
    /// failed として合成する(正常に全部完了していれば空配列)
    /// assigned = 動的な割り振りで実際に渡したシナリオ(渡した分だけが「担当」。nil は初期の担当のまま)
    mutating func childExited(_ index: Int, exitCode: Int32, assigned: [String]? = nil) -> [String] {
        let unfinished = noteExit(index, assigned: assigned)
        guard !unfinished.isEmpty else {
            return relayFinalizingIfAllDone(ScenarioEvent(kind: "recordingFinalizing").encodedLine())
        }
        totalFailed += unfinished.count
        let machineLabel = DeviceMachineGrouping.display(groupMachines[index])
        var log = ScenarioEvent(kind: "log")
        log.message = "[\(machineLabel)] sub-run exited (status \(exitCode)) — marking "
            + "\(unfinished.count) unfinished scenario(s) as failed"
        var lines = [log.encodedLine()]
        for scenario in unfinished {
            var step = ScenarioEvent(kind: "step")
            step.scenario = scenario
            step.status = "failed"
            step.description = "the sub-run on \(machineLabel) exited (status \(exitCode)) before this "
                + "scenario finished — see the fleetest OUTPUT panel for the dispatch error"
            lines.append(step.encodedLine())

            var finished = ScenarioEvent(kind: "scenarioFinished")
            finished.scenario = scenario
            finished.passed = false
            lines.append(finished.encodedLine())
        }
        return lines + relayFinalizingIfAllDone(ScenarioEvent(kind: "recordingFinalizing").encodedLine())
    }

    /// 子の終了を控え、終わりの知らせが来なかった担当を返す(数は unfinishedTotal へ)。キャンセルで合成しないときもこれだけは呼ぶ
    mutating func noteExit(_ index: Int, assigned: [String]? = nil) -> [String] {
        exitedIndices.insert(index)
        if let assigned { assignedScenarioIDs[index] = assigned }
        let unfinished = assignedScenarioIDs[index].filter { !finishedByIndex[index].contains($0) }
        unfinishedTotal += unfinished.count
        return unfinished
    }

    /// 全部の子が終わっても誰にも渡せなかったシナリオ(動的な割り振り)を failed として合成する
    mutating func neverHanded(_ ids: [String]) -> [String] {
        guard !ids.isEmpty else { return [] }
        totalFailed += ids.count
        var log = ScenarioEvent(kind: "log")
        log.message = "\(ids.count) scenario(s) were never handed to a device — marking them as failed"
        var lines = [log.encodedLine()]
        for scenario in ids {
            var step = ScenarioEvent(kind: "step")
            step.scenario = scenario
            step.status = "failed"
            step.description = "no device took this scenario before every sub-run exited"
            lines.append(step.encodedLine())

            var finished = ScenarioEvent(kind: "scenarioFinished")
            finished.scenario = scenario
            finished.passed = false
            lines.append(finished.encodedLine())
        }
        return lines
    }

    /// 1つでも子が recordingFinalizing を出し、かつ全部の子が「出した or 終わった」なら1回だけ line を返す
    private mutating func relayFinalizingIfAllDone(_ line: String) -> [String] {
        guard !finalizingRelayed, !finalizingIndices.isEmpty,
              groupMachines.indices.allSatisfy({ finalizingIndices.contains($0) || exitedIndices.contains($0) })
        else { return [] }
        finalizingRelayed = true
        return [line]
    }

    private enum ClassifiedLine {
        case runStarted
        case runFinished(passed: Int, failed: Int, skipped: Int, runID: String?)
        case recordingFinalizing(String)
        case workersReady([ApiWorkerInfo])
        /// finishedScenario: kind == scenarioFinished のときだけシナリオ ID(childExited の
        /// 未完了判定に使う)
        /// kind: 時刻の採取(scenarioStarted / scenarioFinished)に使う。読めない行は nil
        case other(String, finishedScenario: String?, kind: String?)
    }

    /// **worker フィールドの書き換えは JSON を構造として読み書きする**(文字列置換にすると、
    /// worker のラベルにエンコーダごと違う slash エスケープ規則(ScenarioEvent は
    /// withoutEscapingSlashes・ApiScenarioRequeuedEvent は既定)が混在し、パターンを外して
    /// 書き換え漏れになる)。worker を持たない・kind が未知の行はそのまま素通しする
    /// (壊れた形で再構築しない = 安全側に倒す)
    private static func classify(_ line: String, host: String?) -> ClassifiedLine {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = obj["kind"] as? String else {
            return .other(line, finishedScenario: nil, kind: nil)
        }
        switch kind {
        case "runStarted":
            return .runStarted
        case "runFinished":
            let runID = (obj["runID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // skipped は必須(契約 = ProtocolVersion 45)。欠けた runFinished は集計せず素通しする
            // (0 に倒すと passed + failed + skipped が実行本数に合わない集計を黙って作る)
            guard let skipped = obj["skipped"] as? Int else {
                return .other(line, finishedScenario: nil, kind: kind)
            }
            return .runFinished(passed: obj["passed"] as? Int ?? 0, failed: obj["failed"] as? Int ?? 0,
                                skipped: skipped, runID: runID)
        case "recordingFinalizing":
            return .recordingFinalizing(line)
        case "workersReady":
            let raw = obj["workers"] as? [[String: Any]] ?? []
            let workers = raw.compactMap { entry -> ApiWorkerInfo? in
                guard let name = entry["name"] as? String,
                      let platform = entry["platform"] as? String else { return nil }
                let detail = entry["detail"] as? String ?? ""
                return ApiWorkerInfo(
                    id: DeviceMachineGrouping.workerID(platform: platform, machine: host, name: name),
                    name: name, platform: platform, detail: detail, machine: host)
            }
            return .workersReady(workers)
        default:
            let finishedScenario = kind == "scenarioFinished" ? obj["scenario"] as? String : nil
            guard let worker = obj["worker"] as? String,
                  let colon = worker.firstIndex(of: ":") else {
                // **worker を持たない log は機械を名乗らせる**(中継する側が machine を埋める規律。
                // RemoteMonitorFanout.ingest / RemoteDeviceFanout.machineStamped と同じ)——
                // 供給フェーズの進行(ApiRunCommand.logSupply)はレーンに属さないので、
                // 3機ぶんの「Reviving 8 dead lane(s)」がどの機械のものか分からなくなる
                let stamped = machineStampedLog(obj, host: host) ?? machineStampedWipeStatus(obj, host: host)
                return .other(stamped ?? line, finishedScenario: finishedScenario, kind: kind)
            }
            let platform = String(worker[..<colon])
            let name = String(worker[worker.index(after: colon)...])
            let rehosted = DeviceMachineGrouping.workerID(platform: platform, machine: host, name: name)
            // 手元(host == nil)は常に無変化 —— 既存の id を1バイトも変えない契約をここで満たす
            guard rehosted != worker else { return .other(line, finishedScenario: finishedScenario, kind: kind) }
            var mutated = obj
            mutated["worker"] = rehosted
            guard let out = try? JSONSerialization.data(withJSONObject: mutated, options: [.sortedKeys]),
                  let text = String(data: out, encoding: .utf8) else {
                return .other(line, finishedScenario: finishedScenario, kind: kind)
            }
            return .other(text, finishedScenario: finishedScenario, kind: kind)
        }
    }

    /// kind == "log" かつ worker を持たない行の message に `[<機械名>] ` を付ける。
    /// **手元の子も名乗る**(fanout は必ず複数機械なので、無印の行があると「親のものか手元のものか」
    /// が読めない。用語は登録簿と同じ machine で、手元は "local")。
    /// 対象外・組み立てに失敗したら nil を返して素通しさせる(壊れた形で再構築しない)
    private static func machineStampedLog(_ obj: [String: Any], host: String?) -> String? {
        guard obj["kind"] as? String == "log", obj["worker"] == nil,
              let message = obj["message"] as? String else { return nil }
        var mutated = obj
        mutated["message"] = "[\(MachineDispatch.normalize(host) ?? "local")] \(message)"
        guard let data = try? JSONSerialization.data(withJSONObject: mutated, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// wipeStatus(worker を持たないデバイス単位の行)に `machine` を足す —— 子は `--device-machine local`
    /// 相当で自分のデバイスを無印で名乗るので、そのまま流すと拡張が**同名の手元のタイル**に Wipe の
    /// 進行を出す(拡張は machine 省略を手元と読む。vscode-fleetest/src/model.ts の WipeStatusEvent)。
    /// **手元の子は省いたまま**(「省略 = 手元」の綴り)。対象外・組み立て失敗は nil = 素通し
    private static func machineStampedWipeStatus(_ obj: [String: Any], host: String?) -> String? {
        guard obj["kind"] as? String == "wipeStatus", obj["machine"] == nil,
              let machine = MachineDispatch.normalize(host) else { return nil }
        var mutated = obj
        mutated["machine"] = machine
        guard let data = try? JSONSerialization.data(withJSONObject: mutated, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    private static func encode(_ event: ApiWorkersReadyEvent) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(event), let text = String(data: data, encoding: .utf8) else {
            return #"{"kind":"workersReady","workers":[]}"#
        }
        return text
    }
}
