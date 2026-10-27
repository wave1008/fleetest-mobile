// MultiTargetRunner.swift
// 複数の対象(プロジェクト × 実行プロファイル)を1回の `fleetest run` で回す親(RR-8.2)。
// 空いたマシンが次の対象を取り(`JobSchedule.decide`)、終わり際はシナリオ単位で同じ対象に加わる。
// 子はマシン × 対象ごとに `--work-queue` で起こし、対象ごとの `DynamicDispatcher` がシナリオを1本ずつ配る(RR-8.1)。
//
// - 仕事(job)の ID は "<project>/<profile>"、マシンは全対象のグループから作る一覧の添字(Int)
// - マシンは同時に1つの子だけ。dispatch.lock は使う全マシンを最初に `DispatchPrelock` で取り、最後まで手放さない
// - 同じ (仕事, マシン) の子は1回だけ起こす(DynamicDispatcher は終わったエントリの要求を無視するので、起こし直すと返事が来ない)

import ArgumentParser
import FTCore
import FTRemote
import Foundation

enum MultiTargetRunner {

    // MARK: - 対象の指定

    struct Target: Equatable {
        /// nil = 既定のプロジェクト
        let project: String?
        let profile: String
    }

    /// `--project`/`--profile`(繰り返し)/`--target A:p` から対象を作る。**単一(0 または 1 個の --profile)は空を返す =
    /// 既存の経路**。`--target` は1個でも返す(run() が通常の経路へ読み替える)
    static func targets(project: String?, profiles: [String], targetSpecs: [String]) throws -> [Target] {
        if !targetSpecs.isEmpty {
            if project != nil || !profiles.isEmpty {
                throw ValidationError("--target cannot be combined with --project/--profile")
            }
            let parsed = try targetSpecs.map(parse)
            try rejectDuplicates(parsed)
            return parsed
        }
        guard profiles.count >= 2 else { return [] }
        let parsed = profiles.map { Target(project: project, profile: $0) }
        try rejectDuplicates(parsed)
        return parsed
    }

    /// `<project>:<profile>`(最初の `:` で割る)
    static func parse(_ spec: String) throws -> Target {
        guard let colon = spec.firstIndex(of: ":") else {
            throw ValidationError("--target must be <project>:<profile> (got \"\(spec)\")")
        }
        let project = String(spec[spec.startIndex..<colon])
        let profile = String(spec[spec.index(after: colon)...])
        guard !project.isEmpty, !profile.isEmpty else {
            throw ValidationError("--target must be <project>:<profile> (got \"\(spec)\")")
        }
        return Target(project: project, profile: profile)
    }

    private static func rejectDuplicates(_ targets: [Target]) throws {
        var seen: Set<String> = []
        for target in targets where !seen.insert("\(target.project ?? "")\u{1}\(target.profile)").inserted {
            throw ValidationError("duplicate target: \(target.project.map { "\($0):" } ?? "")\(target.profile)")
        }
    }

    /// 2つ以上の対象と併用できないフラグの最初の1つ(純粋関数。順序は利用者に見せたい順)
    static func firstRejection(flags: [(name: String, isSet: Bool)]) -> String? {
        flags.first(where: { $0.isSet }).map {
            "\($0.name) cannot be combined with several targets (repeated --profile or --target)"
        }
    }

    // MARK: - 実行

    /// 1つの仕事(対象)の実行時の束
    private struct Job {
        let id: String
        let project: TestProject
        let profile: String
        let groups: [DeviceMachineRunner.Group]
        /// 全マシン一覧の添字 → groups の添字
        let entryByMachine: [Int: Int]
        let resolved: [DynamicSplit.Scenario]
        let dispatcher: DynamicDispatcher
        let estimate: @Sendable (DynamicSplit.Scenario, Int) -> Double
        let healCollection: HealSourceWriteBack.Collection
        let infos: [ScenarioInfo]
    }

    private static func writerKey(_ job: String, _ entry: Int) -> String { "\(job)\u{1}\(entry)" }

    private struct ChildOutcome {
        let job: String
        let machine: Int
        let exitCode: Int32
        let duration: TimeInterval
    }

    static func run(
        targets: [Target], setOverrides: [String: RunProfileSetValue], noLPT: Bool, lptHistoryRuns: Int?,
        performanceMode: Bool, forceLock: Bool, waitLock: Int?, remoteDir: String?, remoteTimeout: Int?,
        quiet: Bool, junit: String?, skipBuild: Bool, reportDir: String?
    ) async throws -> Int32 {
        let junitTempDir = try FleetRunner.makeJUnitTempDir(requested: junit)
        defer { if let junitTempDir { try? FileManager.default.removeItem(at: junitTempDir) } }

        // 1. 対象の解決(プロジェクト・グループ)。読むだけで、デバイスにもビルドにも触らない
        let disabled = MachineEnablement.disabledMachines(config: LocalConfig.load())
        struct Resolved {
            let project: TestProject
            let profile: String
            let groups: [DeviceMachineRunner.Group]
        }
        var resolvedTargets: [Resolved] = []
        var seenIDs: Set<String> = []
        for target in targets {
            let project = try ScenarioHost.project(named: target.project)
            let id = "\(project.name)/\(target.profile)"
            guard seenIDs.insert(id).inserted else { throw ValidationError("duplicate target: \(id)") }
            let (groups, _) = try DeviceMachineRunner.resolveGroups(
                project: project, profileName: target.profile, deviceFilter: [],
                disabledMachines: disabled, overrides: setOverrides)
            guard !groups.isEmpty else {
                throw ValidationError("run profile \"\(target.profile)\" of \(project.name) has no devices")
            }
            // 計測の反復(responseRepeat)は子だけが展開し、親は同じ ID を1回しか配らない = 指定の回数を回さずに成功する
            if ProfileResolver.declaresResponseMeasurement(project: project, runName: target.profile, overrides: setOverrides) {
                throw ValidationError("run profile \"\(target.profile)\" of \(project.name) measures response times;"
                    + " run it on its own (not together with other targets)")
            }
            resolvedTargets.append(Resolved(project: project, profile: target.profile, groups: groups))
        }
        // マシン一覧(全対象のグループのラベル。初出の順)
        var machineLabels: [String] = []
        for target in resolvedTargets {
            for group in target.groups where !machineLabels.contains(group.machineLabel) {
                machineLabels.append(group.machineLabel)
            }
        }

        let runGroup = RunRecorder.makeRunGroupID()
        // チケットは1回だけ採って環境へ書く(DeviceMachineRunner.run の同じ箇所の宣言)
        let ticket = DispatchTicketIssuer.issue(runGroup: runGroup)
        setenv(DispatchTicket.environmentKey, ticket.environmentValue, 1)
        FleetRunner.log("==> \(resolvedTargets.count) target(s) on \(machineLabels.count) machine(s)"
            + " — each free machine takes the next target; the last targets are shared scenario by scenario")

        // build を直列化するための先取り。配分が確定したら必ず手放し、本取得は DispatchPrelock が全順序で行う
        var localLock = try LocalDispatchLock(
            runGroup: runGroup, waitLock: waitLock, forceLock: forceLock,
            log: { FleetRunner.log($0) }).acquire()
        defer { localLock?.release() }

        // 2. 手元で1回ずつビルドして一覧を出す(プロジェクトごと)
        var built: Set<String> = []
        var listed: [String: [ScenarioInfo]] = [:]
        var healByProject: [String: HealSourceWriteBack.Collection] = [:]
        for target in resolvedTargets where built.insert(target.project.name).inserted {
            if !skipBuild { try ScenarioHost.build(project: target.project, log: { FleetRunner.log($0) }) }
            // 通常の入口と同じ選択(`@Draft` / `@Deleted` を外す)。子へは完全一致の ID で渡すので、子の側では外れない
            let all = try ScenarioSelection.resolve(
                [], from: ScenarioHost.listForRun(project: target.project, dryRun: false, compilesOCR: false))
            guard !all.isEmpty else {
                throw ValidationError(
                    "no scenarios (add a @TestClass under TestProjects/\(target.project.name)/scenarios/)")
            }
            listed[target.project.name] = all
            healByProject[target.project.name] = HealSourceWriteBack.Collection()
        }

        // 3. 仕事ごとの配り手
        let clock = DynamicDispatcher.monotonicClock()
        let writers = LockedValue<[String: ChildStdinWriter]>([:])
        var jobs: [Job] = []
        for target in resolvedTargets {
            let id = "\(target.project.name)/\(target.profile)"
            let all = listed[target.project.name] ?? []
            let (runnable, notApplicable) = DeviceMachineRunner.splitApplicable(selected: all, groups: target.groups)
            if !notApplicable.isEmpty { FleetRunner.log("==> \(id)") }
            for line in DeviceMachineRunner.notApplicableLines(notApplicable, groups: target.groups) {
                FleetRunner.log(line)
            }
            let resolved = DynamicDispatcher.resolve(
                runnable.map { (id: $0.id, platform: $0.platform) },
                defaultPlatform: DynamicDispatcher.undeclaredPlatform(groups: target.groups))
            guard !resolved.isEmpty else {
                FleetRunner.log("==> \(id): no scenario applies to this profile's devices; skipping")
                continue
            }
            var entryByMachine: [Int: Int] = [:]
            for (index, group) in target.groups.enumerated() {
                if let machine = machineLabels.firstIndex(of: group.machineLabel) { entryByMachine[machine] = index }
            }
            let inputs = DeviceMachineRunner.estimationInputs(
                project: target.project, groups: target.groups, lptHistoryRuns: lptHistoryRuns)
            let estimate = DeviceMachineRunner.dynamicEstimator(inputs: inputs, groups: target.groups)
            let jobID = id
            let dispatcher = DynamicDispatcher(
                scenarios: resolved, estimateMs: estimate, nowMs: clock, lpt: !noLPT,
                send: { entry, reply in
                    writers.withLock { $0[MultiTargetRunner.writerKey(jobID, entry)] }?.write(line: WorkQueueProtocol.encode(reply))
                })
            jobs.append(Job(
                id: id, project: target.project, profile: target.profile, groups: target.groups,
                entryByMachine: entryByMachine, resolved: resolved, dispatcher: dispatcher, estimate: estimate,
                healCollection: healByProject[target.project.name] ?? HealSourceWriteBack.Collection(),
                infos: runnable))
        }
        guard !jobs.isEmpty else {
            FleetRunner.log("==> no target has a scenario to run; nothing to run")
            return 0
        }

        // 手元のデバイスの二重使用はどの機械へも配る前に断る(DeviceMachineRunner.run と同じ位置・同じ理由)
        for job in jobs {
            guard let local = job.groups.first(where: { $0.machine == nil }) else { continue }
            let ids = Set(DynamicDispatcher.candidateIDs(for: local, in: job.resolved))
            try ProfileRunner.rejectIfLocalDevicesLeasedBeforeDispatch(
                project: job.project, profileName: job.profile, setOverrides: setOverrides,
                localDeviceNames: local.deviceNames,
                localScenarios: job.infos.filter { ids.contains($0.id) }, broadcast: false,
                waitLock: waitLock, log: { FleetRunner.log($0) })
        }
        localLock?.release()
        localLock = nil

        // 4. 使う全マシンの dispatch.lock を最初に取り、全部の仕事が終わるまで持つ
        let binary = FleetRunner.selfBinaryPath()
        let prelock = DispatchPrelock(actions: DispatchPrelock.live(
            project: jobs[0].project, remoteDir: remoteDir, forceLock: forceLock, waitLock: waitLock,
            runGroup: runGroup, mode: .cliRun, log: { FleetRunner.log($0) }))
        defer { prelock.releaseAll() }
        guard prelock.acquireInOrder(machines: DispatchPrelock.machinesToLock(machineLabels)) else {
            throw ValidationError("interrupted while acquiring dispatch locks — starting no sub-run")
        }
        let lockMarkers = prelock.markers
        let dispatchStart = Date()

        // 5. 配り手
        let overheadByMachine = overheadsMs(project: jobs[0].project, labels: machineLabels)
        var specs: [MultiTargetCoordinator.Job] = []
        for job in jobs {
            var lanes: [Int: MultiTargetCoordinator.Lane] = [:]
            for (machine, entry) in job.entryByMachine {
                let group = job.groups[entry]
                lanes[machine] = .init(entry: entry, devices: group.deviceNames.count, platforms: group.platforms)
            }
            let dispatcher = job.dispatcher
            specs.append(.init(
                id: job.id, lanes: lanes, pending: { dispatcher.pendingScenarios }, estimateMs: job.estimate,
                childExited: { dispatcher.childExited(entry: $0) }, interrupt: { dispatcher.interrupt() }))
        }
        let jobByID = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
        let childCounter = LockedValue(0)
        let childHosts = LockedValue<[(host: String, index: Int)]>([])
        let outcomes = LockedValue<[ChildOutcome]>([])
        let launch: MultiTargetCoordinator.Launch = { jobID, machine, finished in
            guard let job = jobByID[jobID], let entry = job.entryByMachine[machine] else { finished(127); return }
            let group = job.groups[entry]
            let label = "\(group.machineLabel):\(job.id)"
            let writer = ChildStdinWriter()
            writers.withLock { $0[MultiTargetRunner.writerKey(jobID, entry)] = writer }
            let index = childCounter.withLock { value -> Int in value += 1; return value }
            childHosts.withLock { $0.append((host: label, index: index)) }
            let args = DeviceMachineRunner.childArgs(
                project: job.project.name, host: group.machineLabel, profile: job.profile,
                deviceNames: group.deviceNames, deviceMachine: group.machineLabel,
                scenarios: DynamicDispatcher.candidateIDs(for: group, in: job.resolved), folders: [],
                setOverrides: setOverrides, noLPT: noLPT, lptHistoryRuns: lptHistoryRuns,
                performanceMode: performanceMode, forceLock: forceLock,
                remoteDir: remoteDir, remoteTimeout: remoteTimeout, quiet: quiet,
                junitPath: FleetRunner.entryJUnitPath(tempDir: junitTempDir, index: index),
                runGroup: runGroup, reportDir: reportDir, workQueue: true)
            let dispatcher = job.dispatcher
            let marker = lockMarkers[group.machineLabel]
            let heal = job.healCollection
            Task {
                let started = Date()
                let code = await FleetRunner.runEntry(
                    binary: binary, args: args, hostLabel: label, ticket: ticket, lockMarker: marker,
                    healCollection: heal, stdin: writer,
                    lineInterceptor: { line in dispatcher.intercept(line: line, entry: entry, writer: writer) })
                outcomes.withLock {
                    $0.append(ChildOutcome(job: jobID, machine: machine, exitCode: code,
                                           duration: Date().timeIntervalSince(started)))
                }
                finished(code)
            }
        }
        let coordinator = MultiTargetCoordinator(
            jobs: specs, machineCount: machineLabels.count, overheadMs: overheadByMachine,
            nowMs: clock, lpt: !noLPT, launch: launch, log: { FleetRunner.log($0) })
        let relay = InterruptRelay.observing { coordinator.interrupt() }
        defer { relay.stop() }
        let wallStart = clock()
        coordinator.start()
        await coordinator.waitUntilFinished()
        let wallMs = clock() - wallStart

        // 6. 後始末と集計
        let results = outcomes.withLock { $0 }
        var lastExit: [String: Int32] = [:]
        for outcome in results { lastExit[machineLabels[outcome.machine]] = outcome.exitCode }
        prelock.releaseAll(exitCodes: lastExit)

        var neverHandedFailure = false
        let interrupted = coordinator.isInterrupted
        for job in jobs {
            let ids = job.dispatcher.unhandedIDs
            guard !ids.isEmpty else { continue }
            FleetRunner.log("[\(job.id)] " + DeviceMachineRunner.neverHandedLine(
                ids: ids, interrupted: job.dispatcher.isInterrupted))
            if !job.dispatcher.isInterrupted {
                neverHandedFailure = true
                for id in ids {
                    LastResultsStore.record(project: job.project, scenarioID: id, passed: false, profile: job.profile)
                }
            }
        }
        let neverStarted = coordinator.unstartedJobs
        for id in neverStarted {
            FleetRunner.log("⚠️ \(interrupted ? "interrupted: " : "")\(id) was never started on any machine")
            if !interrupted { neverHandedFailure = true }
        }

        printSummary(jobs: jobs, machineLabels: machineLabels, outcomes: results, wallSeconds: wallMs / 1000)
        for (name, collection) in healByProject.sorted(by: { $0.key < $1.key }) {
            if let project = jobs.first(where: { $0.project.name == name })?.project {
                collection.finish(project: project) { FleetRunner.log($0) }
            }
        }
        for job in jobs {
            let assigned: [(Int, DeviceMachineRunner.Group, [String])] = job.entryByMachine
                .sorted(by: { $0.key < $1.key })
                .map { ($0.value, job.groups[$0.value], job.dispatcher.assignedIDs(entry: $0.value)) }
            reportMissingResults(job: job, runGroup: runGroup, since: dispatchStart, assigned: assigned,
                                 outcomes: results, machineLabels: machineLabels)
        }
        if let junit, let junitTempDir {
            let names = Array(Set(jobs.map(\.project.name))).sorted().joined(separator: "+")
            FleetRunner.mergeAndWriteJUnit(
                junit: junit, project: names, tempDir: junitTempDir, entries: childHosts.withLock { $0 })
        }
        return FleetProfile.aggregateExitCode(results.map(\.exitCode) + (neverHandedFailure ? [1] : []))
    }

    /// 全マシンの送りの固定費[ms]。リモートは facts の dispatchOverheadSeconds(DeviceMachineRunner.assign と同じ出どころ)、手元は 0
    private static func overheadsMs(project: TestProject, labels: [String]) -> [Double] {
        let factsDir = RemoteHostFactsStore.dir(project: project)
        let registry = LocalConfig.load().remoteHosts ?? []
        let localHost = RunRecorder.currentMachine()
        return labels.map { label in
            guard label != DeviceMachineGrouping.localDisplayName else { return 0 }
            let facts = RemoteHostFactsStore.load(
                dir: factsDir,
                host: RemoteHostFactsStore.hostKey(machine: label, entries: registry, localHost: localHost))
            return (facts?.dispatchOverheadSeconds ?? 0) * 1000
        }
    }

    /// 仕事ごとの「結果の無いシナリオ」。DeviceMachineRunner.reportMissingResults と同じ文言・同じ記録で、
    /// 走査を **profile でも絞る**(同じプロジェクトの別プロファイルが同じシナリオ ID を記録して欠落を隠さない)
    private static func reportMissingResults(
        job: Job, runGroup: String, since: Date, assigned: [(Int, DeviceMachineRunner.Group, [String])],
        outcomes: [ChildOutcome], machineLabels: [String]
    ) {
        guard assigned.contains(where: { !$0.2.isEmpty }) else { return }
        let resultsDir = RunResultsStore.resultsDir(projectRoot: job.project.rootURL)
        let metas = RunResultsStore.scanRuns(resultsDir: resultsDir, since: since.addingTimeInterval(-5 * 60))
            .filter { $0.runGroup == runGroup && $0.profile == job.profile }
        var recorded = DeviceMachineRunner.RecordedScenarios()
        for meta in metas {
            for record in RunResultsStore.records(runDir: RunResultsStore.runDir(resultsDir: resultsDir, runID: meta.runID)) {
                recorded.all.insert(record.scenarioID)
                if record.interrupted == true { recorded.interrupted.insert(record.scenarioID) }
            }
        }
        for (_, group, ids) in assigned {
            let machine = machineLabels.firstIndex(of: group.machineLabel)
            let exitCode = outcomes.last(where: { $0.job == job.id && $0.machine == machine })?.exitCode ?? -1
            let label = "\(group.machineLabel):\(job.id)"
            let missing = DeviceMachineRunner.unrecordedScenarioIDs(assigned: ids, recorded: recorded.all)
            if !missing.isEmpty {
                FleetRunner.log(DeviceMachineRunner.missingResultsLine(machineLabel: label, exitCode: exitCode, ids: missing))
                for id in missing {
                    LastResultsStore.record(project: job.project, scenarioID: id, passed: false, profile: job.profile)
                }
            }
            guard exitCode != 0 else { continue }
            let interruptedIDs = ids.filter { recorded.interrupted.contains($0) }
            if !interruptedIDs.isEmpty {
                FleetRunner.log(DeviceMachineRunner.interruptedResultsLine(
                    machineLabel: label, exitCode: exitCode, ids: interruptedIDs))
            }
        }
    }

    private static func printSummary(jobs: [Job], machineLabels: [String], outcomes: [ChildOutcome], wallSeconds: Double) {
        FleetRunner.log("")
        FleetRunner.log("=== \(jobs.count) target(s) across \(machineLabels.count) machine(s) ===")
        for job in jobs {
            let mine = outcomes.filter { $0.job == job.id }
            let code = FleetProfile.aggregateExitCode(mine.map(\.exitCode))
            let used = Dictionary(grouping: mine, by: \.machine).keys.sorted().map { machine -> String in
                let entry = job.entryByMachine[machine]
                return "\(machineLabels[machine])(\(entry.map { job.dispatcher.assignedIDs(entry: $0).count } ?? 0))"
            }.joined(separator: ", ")
            let result = mine.isEmpty ? "not run" : (code == 0 ? "✅ pass" : "❌ fail (exit \(code))")
            FleetRunner.log("\(job.id): \(result)  machines(scenarios): \(used.isEmpty ? "-" : used)")
        }
        for (machine, label) in machineLabels.enumerated() {
            let busy = outcomes.filter { $0.machine == machine }.reduce(0) { $0 + $1.duration }
            FleetRunner.log(String(format: "machine %@: busy=%.1fs idle=%.1fs", label as NSString, busy,
                                   max(wallSeconds - busy, 0)))
        }
    }
}

// MARK: - 配り手(仕事 × マシンの割り当て)

/// 空いたマシンごとに `JobSchedule.decide` を呼び、子の起動を指示する。状態は全部 LockedValue の中。
/// 子の終了・タイマー・中断のどれが来ても空いているマシンを全部判定し直す(固定周期では回さない)。
/// ロックの順序は 配り手 → 仕事のクロージャ(DynamicDispatcher のロック)の一方向。DynamicDispatcher は配り手を呼ばない
final class MultiTargetCoordinator: Sendable {

    struct Lane: Sendable {
        /// 仕事のグループ(= DynamicDispatcher のエントリ)の添字
        let entry: Int
        let devices: Int
        let platforms: Set<String>
    }

    struct Job: Sendable {
        let id: String
        /// 全マシン一覧の添字 → この仕事のレーン。載っていないマシンは回せない
        let lanes: [Int: Lane]
        let pending: @Sendable () -> [DynamicSplit.Scenario]
        let estimateMs: @Sendable (DynamicSplit.Scenario, Int) -> Double
        let childExited: @Sendable (Int) -> Void
        let interrupt: @Sendable () -> Void
    }

    /// 子を起こす。起こしたら戻り、子が終わったら `finished(終了コード)` を1回呼ぶ(テストは偽物を渡す)
    typealias Launch = @Sendable (_ job: String, _ machine: Int, _ finished: @escaping @Sendable (Int32) -> Void) -> Void

    enum Status: Equatable, Sendable {
        case idle, busy(String), finished
    }

    private struct Pair: Hashable { let job: String; let machine: Int }

    private struct State {
        var status: [Status]
        var unstarted: [String]
        var running: [String: Set<Int>] = [:]
        var launched: Set<Pair> = []
        /// 仕事ごとの「終わる見込みの時刻」の記憶[ms]。始めた・加わったときの見込みの早いほう(expectedFreeAt を見よ)
        var anchor: [String: Double] = [:]
        var dead: Set<Int> = []
        var active = 0
        var interrupted = false
        var cancelTimer: DynamicDispatcher.Cancel?
        var finished = false
        var continuation: CheckedContinuation<Void, Never>?
    }

    private let state: LockedValue<State>
    private let jobs: [String: Job]
    private let overheadMs: [Double]
    private let nowMs: @Sendable () -> Double
    private let timer: DynamicDispatcher.Timer
    private let launch: Launch
    private let log: @Sendable (String) -> Void
    /// false = `--no-lpt`(未着手の仕事を宣言の順に試す)
    private let lpt: Bool

    init(jobs: [Job], machineCount: Int, overheadMs: [Double],
         nowMs: @escaping @Sendable () -> Double = DynamicDispatcher.monotonicClock(),
         timer: @escaping DynamicDispatcher.Timer = DynamicDispatcher.dispatchTimer,
         lpt: Bool = true,
         launch: @escaping Launch, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.lpt = lpt
        self.jobs = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.overheadMs = overheadMs
        self.nowMs = nowMs
        self.timer = timer
        self.launch = launch
        self.log = log
        state = LockedValue(State(status: Array(repeating: .idle, count: machineCount),
                                  unstarted: jobs.map(\.id)))
    }

    // MARK: - 入口

    func start() { reconsider() }

    /// 中断: 以後は子を起こさず、各仕事の配り手が保留中も以後の要求も none で答える。走っている子は待つ
    func interrupt() {
        state.withLock { $0.interrupted = true }
        for job in jobs.values { job.interrupt() }
        reconsider()
    }

    func waitUntilFinished() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            state.withLock { s in
                if s.finished { continuation.resume() } else { s.continuation = continuation }
            }
        }
    }

    // MARK: - 読み出し

    var isInterrupted: Bool { state.withLock { $0.interrupted } }
    /// 一度もどのマシンでも起こさなかった仕事(担当が抜けて未着手へ戻った仕事は含めない = その残りは仕事ごとの「配られなかった」が言う)
    var unstartedJobs: [String] {
        state.withLock { s in s.unstarted.filter { id in !s.launched.contains { $0.job == id } } }
    }
    var deadMachines: Set<Int> { state.withLock { $0.dead } }
    var statuses: [Status] { state.withLock { $0.status } }

    // MARK: - 判定

    private func childFinished(job: String, machine: Int, exitCode: Int32) {
        if let spec = jobs[job], let lane = spec.lanes[machine] { spec.childExited(lane.entry) }
        let pendingLeft = !(jobs[job]?.pending().isEmpty ?? true)
        state.withLock { s in
            s.active -= 1
            s.running[job]?.remove(machine)
            if s.running[job]?.isEmpty == true {
                s.running.removeValue(forKey: job)
                // **担当が0台になっても誰にも渡していない分が残っていれば、未着手へ戻す**(ほかのマシンが始める)。
                // 戻さないと「走っている」でも「未着手」でもなくなり、落ちた1台の残りが誰にも配られず赤で残った。
                // 渡し済みは回し直さない(配り手が持たない)・抜けたマシンは同じ仕事を起こし直さない(launched)
                if pendingLeft, !s.unstarted.contains(job) {
                    s.unstarted.append(job)
                    s.anchor[job] = nil   // 始め直す側の見込みで覚え直す(古い時刻のままだと始めた直後から期限切れに見える)
                }
            }
            // 0(全緑)と 1(シナリオの失敗)以外は子が異常終了した印。そのマシンには以後配らない
            if exitCode != 0 && exitCode != 1 {
                s.dead.insert(machine)
                s.status[machine] = .finished
            } else {
                s.status[machine] = .idle
            }
        }
        if exitCode != 0 && exitCode != 1 {
            log("⚠️ machine #\(machine) ended abnormally (exit \(exitCode)) while running \(job); no further work goes to it")
        }
        reconsider()
    }

    private func reconsider() {
        let starts: [(job: String, machine: Int)] = state.withLock { s in
            var out: [(job: String, machine: Int)] = []
            let now = nowMs()
            s.cancelTimer?()
            s.cancelTimer = nil
            if s.interrupted {
                for m in s.status.indices where s.status[m] == .idle { s.status[m] = .finished }
            } else {
                var earliest: Double?
                var progressed = true
                while progressed {
                    progressed = false
                    earliest = nil
                    for m in s.status.indices where s.status[m] == .idle {
                        switch decide(&s, machine: m, now: now) {
                        case .start(let id), .join(let id):
                            guard jobs[id] != nil, !s.launched.contains(Pair(job: id, machine: m)) else {
                                s.status[m] = .finished
                                break
                            }
                            if let finish = expectedFinish(job: id, adding: m, state: s, now: now) {
                                s.anchor[id] = min(s.anchor[id] ?? .infinity, finish)
                            }
                            s.unstarted.removeAll { $0 == id }
                            s.running[id, default: []].insert(m)
                            s.status[m] = .busy(id)
                            s.launched.insert(Pair(job: id, machine: m))
                            s.active += 1
                            out.append((id, m))
                            progressed = true
                        case .hold(let at):
                            if let at, at < (earliest ?? .infinity) { earliest = at }
                        case .done:
                            s.status[m] = .finished
                        }
                        if progressed { break }
                    }
                }
                if let earliest {
                    s.cancelTimer = timer(max(earliest - now, 0)) { [weak self] in self?.reconsider() }
                }
                // 何も走っておらず、待つ時刻も無いなら、待っていても状況は変わらない(判定が時刻の無い保留を返し続ける)
                if s.active == 0, out.isEmpty, s.cancelTimer == nil {
                    for m in s.status.indices where s.status[m] == .idle { s.status[m] = .finished }
                }
            }
            if s.active == 0, !s.status.contains(.idle), s.cancelTimer == nil || s.interrupted {
                s.cancelTimer?()
                s.cancelTimer = nil
                s.finished = true
                s.continuation?.resume()
                s.continuation = nil
            }
            return out
        }
        for (job, machine) in starts {
            // **予約したあとに中断が来ていたら起こさない**(予約はロックの中・起動は外なので、その間の中断を見落とすと
            // 中断のあとに子が起きる)。予約を戻して終わりの判定をし直す
            let cancelled = state.withLock { s -> Bool in
                guard s.interrupted else { return false }
                s.active -= 1
                s.running[job]?.remove(machine)
                if s.running[job]?.isEmpty == true { s.running.removeValue(forKey: job) }
                s.status[machine] = .finished
                return true
            }
            if cancelled {
                reconsider()
                continue
            }
            launch(job, machine) { [self] code in childFinished(job: job, machine: machine, exitCode: code) }
        }
    }

    private func decide(_ s: inout State, machine: Int, now: Double) -> JobSchedule.Decision {
        let states: [JobSchedule.MachineState] = s.status.indices.map { m in
            if case .busy(let id) = s.status[m] {
                return JobSchedule.MachineState(machine: m, currentJob: id,
                                                expectedFreeAt: expectedFreeAt(job: id, running: s, now: now))
            }
            return JobSchedule.MachineState(machine: m, currentJob: nil, expectedFreeAt: nil)
        }
        let snapshot = s
        return JobSchedule.decide(
            for: machine, now: now, unstarted: s.unstarted, running: s.running,
            hasPending: { id in !(jobs[id]?.pending().isEmpty ?? true) },
            machines: states,
            aloneMs: { id, m in aloneMs(job: id, machine: m, state: snapshot) },
            overheadMs: { m in m < overheadMs.count ? overheadMs[m] : 0 }, lpt: lpt)
    }

    /// その仕事を、このマシンのこの仕事のデバイスだけで、まだ配っていない分を全部回す時間[ms]。
    /// 回せない(レーンが無い・死んだ・一度起こして抜けた・残りにこのマシンで回せるものが無い)なら nil。
    /// **今その仕事を回しているマシンは nil にしない** —— 加わる判定(JobSchedule)は回しているマシンの速さの和で
    /// 「加わらないときの終わり」を出すので、nil だと速さ 0 になり、終わり際に1台も加わらなかった。
    /// 抜けたマシンを外すのは、配り手が終わったエントリの要求を受けない(起こし直せない)ため
    private func aloneMs(job id: String, machine: Int, state s: State) -> Double? {
        let leftAlready = s.launched.contains(Pair(job: id, machine: machine))
            && !(s.running[id]?.contains(machine) ?? false)
        guard let job = jobs[id], let lane = job.lanes[machine], !s.dead.contains(machine),
              !leftAlready else { return nil }
        let fitting = job.pending().filter { lane.platforms.contains($0.platform) }
        guard !fitting.isEmpty else { return nil }
        let total = fitting.reduce(0.0) { $0 + job.estimateMs($1, lane.entry) }
        return total / Double(max(lane.devices, 1))
    }

    /// 走っている仕事が終わる見込みの時刻 = min(記憶した時刻, 今 + 残りの見込み)。
    /// **「今 + 残り」だけにしない** —— 毎回いまから作り直すので、見込みより遅れても期限を過ぎた側へ一度も倒れず、
    /// JobSchedule の安全弁が効かない(FM が落ちて遅くなった手元を「もうすぐ空く速いマシン」と見続け、空いた2台が
    /// 未着手の仕事を取らずに10分以上待った)。記憶した時刻は遅れを覚え、残りの見込みは早く進んだ分を拾う
    private func expectedFreeAt(job id: String, running s: State, now: Double) -> Double {
        let rest = remainingFinish(job: id, members: s.running[id] ?? [], now: now)
        return min(s.anchor[id] ?? .infinity, rest ?? now)
    }

    /// その仕事を members で回したときの「今 + 残り」。速さはマシンごとの 1/見込み の和。残りが無ければ nil
    private func remainingFinish(job id: String, members: Set<Int>, now: Double) -> Double? {
        guard let job = jobs[id] else { return nil }
        var rate = 0.0
        for m in members {
            guard let lane = job.lanes[m] else { continue }
            let fitting = job.pending().filter { lane.platforms.contains($0.platform) }
            let total = fitting.reduce(0.0) { $0 + job.estimateMs($1, lane.entry) } / Double(max(lane.devices, 1))
            if total > 0 { rate += 1 / total }
        }
        return rate > 0 ? now + 1 / rate : nil
    }

    /// machine が始める・加わるときの終わる見込み(固定費の後から加わった速さで回る近似)
    private func expectedFinish(job id: String, adding machine: Int, state s: State, now: Double) -> Double? {
        let overhead = machine < overheadMs.count ? overheadMs[machine] : 0
        guard let rest = remainingFinish(job: id, members: (s.running[id] ?? []).union([machine]), now: now + overhead)
        else { return nil }
        return rest
    }
}
