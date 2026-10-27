// 動的な割り振りの親の配り手(DynamicDispatcher。RR-8.1)の規律を固定する。デバイス不要(偽の時計・見積り・タイマー)。
// 破ると: 速いマシンが空いているのに遅いマシンが長いシナリオを取って全体が延びる / 供給中のレーンを空きと数えて
// 誰にも渡らない / 返事待ちの子が中断を見られず止まる / 落ちた子へ渡した分が二重に走る。

import ArgumentParser
import XCTest
import FTCore
@testable import fleetest

final class DynamicDispatcherTests: XCTestCase {

    private typealias Scenario = DynamicSplit.Scenario

    /// 見込み = 基準[ms] × エントリの係数
    private struct Harness {
        let dispatcher: DynamicDispatcher
        let clock: LockedValue<Double>
        let sent: LockedValue<[String]>
        let timers: LockedValue<[Double]>
        let fires: LockedValue<[@Sendable () -> Void]>
    }

    private func harness(scenarios: [Scenario], base: [String: Double], factors: [Double], lpt: Bool = true) -> Harness {
        let clock = LockedValue<Double>(0)
        let sent = LockedValue<[String]>([])
        let timers = LockedValue<[Double]>([])
        let fires = LockedValue<[@Sendable () -> Void]>([])
        let dispatcher = DynamicDispatcher(
            scenarios: scenarios,
            estimateMs: { scenario, entry in (base[scenario.id] ?? 1000) * factors[entry] },
            nowMs: { clock.value },
            timer: { afterMs, fire in
                timers.withLock { $0.append(afterMs) }
                fires.withLock { $0.append(fire) }
                return {}
            },
            lpt: lpt,
            send: { entry, reply in sent.withLock { $0.append("\(entry):\(WorkQueueProtocol.encode(reply))") } })
        return Harness(dispatcher: dispatcher, clock: clock, sent: sent, timers: timers, fires: fires)
    }

    private func want(_ req: Int, lane: String, platform: String = "ios") -> WorkQueueProtocol.Want {
        WorkQueueProtocol.Want(req: req, lane: lane, platform: platform)
    }

    private func ios(_ id: String) -> Scenario { Scenario(id: id, platform: "ios") }

    private func none(_ req: Int) -> WorkQueueProtocol.Reply { .init(req: req, none: true) }

    /// 遅いマシンは速いマシンが終わる見込みのほうが早ければ待たされ、速いマシンが戻ると渡されず none で終わる
    func testSlowMachineHeldThenAnsweredNoneWhenPendingEmpties() {
        let h = harness(scenarios: [ios("L"), ios("S")], base: ["L": 10_000, "S": 1_000], factors: [1, 20])
        XCTAssertEqual(h.dispatcher.handle(want(1, lane: "a"), fromEntry: 0), .init(req: 1, id: "L"))
        XCTAssertNil(h.dispatcher.handle(want(1, lane: "b"), fromEntry: 1))
        XCTAssertEqual(h.timers.value, [10_000], "速いレーンが空く見込みの時刻に1回だけ張る")
        h.clock.value = 10_000
        XCTAssertEqual(h.dispatcher.handle(want(2, lane: "a"), fromEntry: 0), .init(req: 2, id: "S"))
        XCTAssertEqual(h.sent.value, ["1:" + WorkQueueProtocol.encode(none(1))])
    }

    /// 遅いマシンでも、速いマシンの見込みより早く終わる短いシナリオは今渡される(長いほうは残る)
    func testSlowMachineGetsShortScenarioWhileFastIsBusy() {
        let h = harness(scenarios: [ios("L"), ios("S"), ios("T")],
                        base: ["L": 10_000, "S": 1_000, "T": 500], factors: [1, 20])
        XCTAssertEqual(h.dispatcher.handle(want(1, lane: "a"), fromEntry: 0), .init(req: 1, id: "L"))
        XCTAssertEqual(h.dispatcher.handle(want(1, lane: "b"), fromEntry: 1), .init(req: 1, id: "T"))
        XCTAssertEqual(h.dispatcher.unhandedIDs, ["S"])
    }

    /// `--no-lpt` は親の配る順に効く(子のカタログの並びでは変わらない)
    func testNoLPTHandsOutInIDOrder() {
        let h = harness(scenarios: [ios("Z.long"), ios("A.short")], base: ["Z.long": 10_000, "A.short": 1_000],
                        factors: [1], lpt: false)
        XCTAssertEqual(h.dispatcher.handle(want(1, lane: "a"), fromEntry: 0), .init(req: 1, id: "A.short"))
    }

    /// 要求を出していないレーン(供給中)は空きと数えない
    func testLaneThatNeverJoinedIsNotCounted() {
        let h = harness(scenarios: [ios("X")], base: ["X": 10_000], factors: [10, 0.1])
        XCTAssertEqual(h.dispatcher.handle(want(1, lane: "a"), fromEntry: 0), .init(req: 1, id: "X"))
    }

    /// 子が落ちたらそのレーンと保留を捨てる。渡し済みは回し直さず、残りは他のマシンへ配る
    func testChildExitDropsLanesAndDoesNotRedispatch() {
        let h = harness(scenarios: [ios("L"), ios("S")], base: ["L": 10_000, "S": 1_000], factors: [1, 20])
        XCTAssertEqual(h.dispatcher.handle(want(1, lane: "a"), fromEntry: 0), .init(req: 1, id: "L"))
        XCTAssertNil(h.dispatcher.handle(want(1, lane: "b"), fromEntry: 1))
        h.dispatcher.childExited(entry: 0)
        XCTAssertEqual(h.sent.value, ["1:" + WorkQueueProtocol.encode(.init(req: 1, id: "S"))])
        XCTAssertEqual(h.dispatcher.assignedIDs(entry: 0), ["L"])
        XCTAssertEqual(h.dispatcher.unhandedIDs, [])
        // 落ちた子の遅れた要求には答えない(書き込み先が無い)
        XCTAssertNil(h.dispatcher.handle(want(2, lane: "a"), fromEntry: 0))
    }

    /// 渡せるレーンが全部いなくなったシナリオは残る(呼び手が失敗として報告する)
    func testPendingRemainsWhenEveryChildExited() {
        let h = harness(scenarios: [ios("L"), ios("S")], base: ["L": 10_000, "S": 1_000], factors: [1, 1])
        _ = h.dispatcher.handle(want(1, lane: "a"), fromEntry: 0)
        h.dispatcher.childExited(entry: 0)
        XCTAssertEqual(h.dispatcher.unhandedIDs, ["S"])
    }

    /// platform: 未宣言は run の既定。レーンの platform と違うシナリオは渡さない(none)
    func testPlatformResolutionAndFiltering() {
        let iosGroup = DeviceMachineRunner.Group(machine: nil, deviceNames: ["i"], platforms: ["ios"])
        let androidGroup = DeviceMachineRunner.Group(machine: "M", deviceNames: ["a"], platforms: ["android"])
        XCTAssertEqual(DynamicDispatcher.undeclaredPlatform(groups: [iosGroup, androidGroup]), "ios")
        XCTAssertEqual(DynamicDispatcher.undeclaredPlatform(groups: [androidGroup]), "android")

        let resolved = DynamicDispatcher.resolve(
            [(id: "U", platform: nil), (id: "D", platform: "android")], defaultPlatform: "ios")
        XCTAssertEqual(resolved, [Scenario(id: "U", platform: "ios"), Scenario(id: "D", platform: "android")])
        XCTAssertEqual(DynamicDispatcher.candidateIDs(for: iosGroup, in: resolved), ["U"])
        XCTAssertEqual(DynamicDispatcher.candidateIDs(for: androidGroup, in: resolved), ["D"])

        let h = harness(scenarios: resolved, base: [:], factors: [1, 1])
        XCTAssertEqual(h.dispatcher.handle(want(1, lane: "a", platform: "android"), fromEntry: 1),
                       .init(req: 1, id: "D"))
        XCTAssertEqual(h.dispatcher.handle(want(2, lane: "a", platform: "android"), fromEntry: 1), none(2))
        XCTAssertEqual(h.dispatcher.handle(want(1, lane: "i"), fromEntry: 0), .init(req: 1, id: "U"))
    }

    /// 中断: 保留中の要求にも以後の要求にも none。渡していない分は残る(呼び手が「中断」として報告する)
    func testInterruptAnswersHeldAndFutureWantsWithNone() {
        let h = harness(scenarios: [ios("L"), ios("S")], base: ["L": 10_000, "S": 1_000], factors: [1, 20])
        _ = h.dispatcher.handle(want(1, lane: "a"), fromEntry: 0)
        XCTAssertNil(h.dispatcher.handle(want(1, lane: "b"), fromEntry: 1))
        h.dispatcher.interrupt()
        XCTAssertEqual(h.sent.value, ["1:" + WorkQueueProtocol.encode(none(1))])
        XCTAssertEqual(h.dispatcher.handle(want(2, lane: "a"), fromEntry: 0), none(2))
        XCTAssertEqual(h.dispatcher.handle(want(3, lane: "c"), fromEntry: 2), none(3))
        XCTAssertTrue(h.dispatcher.isInterrupted)
        XCTAssertEqual(h.dispatcher.unhandedIDs, ["S"])
    }

    /// タイマーが鳴っても状況が変わらなければ保留のまま(見込み通りに空かないなら次の時刻へ張り直す)
    func testTimerFireWithoutChangeKeepsHolding() {
        let h = harness(scenarios: [ios("L"), ios("S")], base: ["L": 10_000, "S": 1_000], factors: [1, 20])
        _ = h.dispatcher.handle(want(1, lane: "a"), fromEntry: 0)
        XCTAssertNil(h.dispatcher.handle(want(1, lane: "b"), fromEntry: 1))
        h.clock.value = 10_500   // 速いレーンが見込みを 500ms 過ぎても戻らない
        h.fires.value.last?()
        XCTAssertTrue(h.sent.value.isEmpty)
        // 超過分だけ空く時刻を後ろへ倒した規則が反転する時刻 = 10000 + 20000 - 1000 = 29000 → あと 18500ms
        XCTAssertEqual(h.timers.value, [10_000, 18_500])
    }

    // MARK: - 引数・環境・書き込み口

    func testWorkQueueFlagOnlyWhenRequested() {
        func args(_ workQueue: Bool) -> [String] {
            DeviceMachineRunner.childArgs(
                project: "E2E", host: "M1Ultra", profile: "p", deviceNames: ["iPhone-01"],
                deviceMachine: "M1Ultra", scenarios: ["A.b"], folders: [],
                noLPT: false, lptHistoryRuns: nil, performanceMode: false,
                forceLock: false, remoteDir: nil, remoteTimeout: nil,
                quiet: true, junitPath: nil, workQueue: workQueue)
        }
        XCTAssertFalse(args(false).contains("--work-queue"))
        XCTAssertTrue(args(true).contains("--work-queue"))
    }

    func testDynamicSplitSwitch() {
        XCTAssertTrue(DeviceMachineRunner.dynamicSplitEnabled(broadcast: false, measuresResponse: false, environment: [:]))
        XCTAssertFalse(DeviceMachineRunner.dynamicSplitEnabled(
            broadcast: false, measuresResponse: false, environment: ["FT_STATIC_SPLIT": "1"]))
        XCTAssertFalse(DeviceMachineRunner.dynamicSplitEnabled(broadcast: true, measuresResponse: false, environment: [:]))
    }

    /// マシンをまたぐ親の終了コード: 子が全員 0 でも、中断で残りがあれば 0 にしない(未実行を含む回帰を検証済みにさせない)
    func testParentExitCodeIsNonZeroWhenAnInterruptLeftWork() {
        XCTAssertEqual(DeviceMachineRunner.parentExitCode(childCodes: [0, 0], neverHandedFailure: false,
                                                          interruptedWithWorkLeft: false), 0)
        XCTAssertEqual(DeviceMachineRunner.parentExitCode(childCodes: [0, 0], neverHandedFailure: false,
                                                          interruptedWithWorkLeft: true), 130)
        XCTAssertEqual(DeviceMachineRunner.parentExitCode(childCodes: [0], neverHandedFailure: true,
                                                          interruptedWithWorkLeft: false), 1)
        XCTAssertEqual(DeviceMachineRunner.parentExitCode(childCodes: [143, 0], neverHandedFailure: false,
                                                          interruptedWithWorkLeft: true), 143)
        // 子を1つも起こす前の中断(ロックの待ち・ビルド)も 130。ValidationError の 64 にしない
        XCTAssertEqual(DeviceMachineRunner.interruptedBeforeAnySubRun.rawValue, 130)
    }

    /// **`--fleet` もほかの3経路と同じ規則で終了コードを決める**(中断なら 130。ロックの取得中の中断を使い方の誤り 64 にしない・
    /// 途中の中断で子が返した 1 などに埋もれさせない)
    func testFleetUsesTheSharedInterruptExitCode() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fleet = try String(contentsOf: root.appendingPathComponent("Sources/fleetest/FleetRunner.swift"), encoding: .utf8)
        XCTAssertFalse(fleet.contains("ValidationError(\"interrupted while acquiring"),
                       "--fleet がロックの取得中の中断を ValidationError(64)で投げている")
        XCTAssertEqual(fleet.components(separatedBy: "throw DeviceMachineRunner.interruptedBeforeAnySubRun").count - 1, 2,
                       "--fleet の2つのロックの取得が共有の出口(130)で抜けていない")
        XCTAssertTrue(fleet.contains("interruptedWithWorkLeft: InterruptRelay.hasReceivedInterrupt"),
                      "--fleet の終了コードが中断を見ていない")
        XCTAssertFalse(fleet.contains("FleetProfile.aggregateExitCode("), "--fleet が子の終了コードだけで終了コードを決めている")
    }

    /// 3経路(run の機械分担・api run の機械分担・複数対象)が同じ関数で終了コードを決める(ソース走査)
    func testAllParentPathsUseTheSharedExitCode() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Sources/fleetest/DeviceMachineRunner.swift", "Sources/fleetest/ApiRunMachineFanout.swift",
                     "Sources/fleetest/MultiTargetRunner.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains("interruptedWithWorkLeft: interruptedWithWorkLeft)"),
                          "\(file) が中断で残った分を終了コードへ載せていない")
            XCTAssertFalse(text.contains("ValidationError(\"interrupted while acquiring"),
                           "\(file) がロックの取得中の中断を ValidationError(64)で投げている")
        }
        // ロックの取得中の中断は前段(MachineFanoutFrontHalf)の共有の出口(130)で抜ける
        let front = try String(contentsOf: root.appendingPathComponent("Sources/fleetest/MachineFanoutFrontHalf.swift"),
                               encoding: .utf8)
        XCTAssertTrue(front.contains("throw DeviceMachineRunner.interruptedBeforeAnySubRun"),
                      "前段がロックの取得中の中断を共有の出口(130)で抜けていない")
        // 渡したのに結果が無い分(子が受け取る前の中断など)も終了コードへ載せる
        for (file, marker) in [("Sources/fleetest/DeviceMachineRunner.swift", "if missing > 0 {"),
                               ("Sources/fleetest/MultiTargetRunner.swift", "if missing > 0 {"),
                               ("Sources/fleetest/ApiRunMachineFanout.swift", "if unfinishedTotal > 0 {")] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains(marker), "\(file) が結果の無いシナリオを終了コードへ載せていない")
        }
    }

    /// 前段(MachineFanoutFrontHalf。3経路の親が共有する1箇所)は入口の中断の印(ParentInterrupt)を手元のロックの先取りより前に立て、
    /// そのロックの待ちにも渡す。後ろにあると、先取りが自前の購読を外して既定動作へ戻した後、ビルドの間の SIGTERM で親が
    /// 後始末なしに死ぬ(ソース走査)。3経路は前段を通り、購読の登録の後に出口を見る
    func testFrontHalfRegistersTheInterruptBeforeTheLocalLock() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/fleetest/MachineFanoutFrontHalf.swift"),
                              encoding: .utf8)
        guard let watch = text.range(of: "ParentInterrupt()\n"),
              let lock = text.range(of: "LocalDispatchLock(\n") else {
            return XCTFail("前段に入口の印か手元のロックの先取りが無い")
        }
        XCTAssertLessThan(watch.lowerBound, lock.lowerBound, "入口の印をロックの先取りより後で立てている")
        XCTAssertTrue(text.contains(".acquire(interruptCheck: parentInterrupt.isSet)"),
                      "手元のロックの待ちに入口の印を渡していない")
        XCTAssertTrue(text.contains("try parentInterrupt.acquireLocalLock("),
                      "手元のロックの待ちの中断を 130 へ読み替えていない")
        XCTAssertTrue(text.contains("interruptCheck: parentInterrupt.isSet,"),
                      "手元のデバイスの使用中の待ちに入口の印を渡していない")
        // 先取りのロックは使用中の待ちより前に手放す(握ったまま待つとこの Mac の他の run を待たせる)
        let release = try XCTUnwrap(text.range(of: "localLock?.release()\n        localLock = nil"))
        let leaseWait = try XCTUnwrap(text.range(of: "try ProfileRunner.rejectIfLocalDevicesLeasedBeforeDispatch("))
        XCTAssertLessThan(release.lowerBound, leaseWait.lowerBound, "ロックを握ったまま使用中を待っている")
        // 使用中の待ちは Prelock の取得より前(読み取りだけの先読み。取ってから降りると他人を待たせた挙句に何も走らない)
        let prelock = try XCTUnwrap(text.range(of: "lock.acquireInOrder("))
        XCTAssertLessThan(leaseWait.lowerBound, prelock.lowerBound)
        for file in ["Sources/fleetest/DeviceMachineRunner.swift", "Sources/fleetest/ApiRunMachineFanout.swift",
                     "Sources/fleetest/MultiTargetRunner.swift"] {
            let caller = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let relay = try XCTUnwrap(caller.range(of: "InterruptRelay.observing(catchUp: true)"), file)
            let exit = try XCTUnwrap(caller.range(of: "held.exitIfInterruptedBeforeLaunch("), file)
            XCTAssertLessThan(relay.lowerBound, exit.lowerBound, "\(file): 購読の登録より前に出口を見ている")
        }
    }

    // MARK: - 入口の中断の印(ParentInterrupt)の段の振る舞い

    /// 中断済みなら手元のロックを取りに行かない(列に並ばない・--force-lock で奪わない)
    func testAnInterruptedParentDoesNotGoForTheLocalLock() {
        let watch = DeviceMachineRunner.ParentInterrupt(isSetForTesting: { true })
        let attempted = LockedValue(false)
        XCTAssertThrowsError(try watch.acquireLocalLock(log: { _ in }) {
            attempted.withLock { $0 = true }
            return nil
        }) { error in XCTAssertEqual((error as? ExitCode)?.rawValue, 130, "\(error)") }
        XCTAssertFalse(attempted.value, "中断済みなのにロックを取りに行った")
    }

    /// 待ちの最後の周で取れても、その間に来た中断を見て、取ったロックを外してから 130 で抜ける
    /// (外さないと、呼び手の defer が張られる前に投げるのでプロセスの終わりまで握る)
    func testALockTakenWhileTheInterruptArrivedIsReleasedBeforeExiting() {
        let interrupted = LockedValue(false)
        let released = LockedValue(false)
        let watch = DeviceMachineRunner.ParentInterrupt(isSetForTesting: { interrupted.value })
        XCTAssertThrowsError(try watch.acquireLocalLock(log: { _ in }) {
            interrupted.withLock { $0 = true }
            return LocalDispatchLock.Holder { released.withLock { $0 = true } }
        }) { error in XCTAssertEqual((error as? ExitCode)?.rawValue, 130, "\(error)") }
        XCTAssertTrue(released.value, "取ったロックを外さずに抜けた")
    }

    /// 段の中で中断に落ちた誤り(端末の Ctrl-C でビルドが落ちた)は 130。中断でない誤りはそのまま投げる
    func testAStageMapsAnInterruptedFailureTo130AndPassesOtherFailuresThrough() {
        struct BuildFailed: Error {}
        let interrupted = LockedValue(false)
        let watch = DeviceMachineRunner.ParentInterrupt(isSetForTesting: { interrupted.value })
        XCTAssertThrowsError(try watch.stage("the scenario build", log: { _ in }) { () throws -> Int in throw BuildFailed() }) {
            XCTAssertTrue($0 is BuildFailed, "中断でない誤りを読み替えた: \($0)")
        }
        XCTAssertThrowsError(try watch.stage("the scenario build", log: { _ in }) { () throws -> Int in
            interrupted.withLock { $0 = true }
            throw BuildFailed()
        }) { XCTAssertEqual(($0 as? ExitCode)?.rawValue, 130, "\($0)") }
    }

    /// レスポンス計測の run は動的にしない(反復は子だけが展開し、親は同じ ID を1回しか配らない)
    func testResponseMeasurementNeverUsesDynamicSplit() {
        XCTAssertFalse(DeviceMachineRunner.dynamicSplitEnabled(broadcast: false, measuresResponse: true, environment: [:]))
    }

    func testNeverHandedLineWording() {
        XCTAssertTrue(DeviceMachineRunner.neverHandedLine(ids: ["A", "B"], interrupted: false)
            .contains("2 scenario(s) were never handed to a device: A, B"))
        XCTAssertTrue(DeviceMachineRunner.neverHandedLine(ids: ["A"], interrupted: true).contains("interrupted"))
    }

    /// 子が死んで読み手の無いパイプへ書いても落ちない・閉じた後の書き込みは何もしない
    func testChildStdinWriterIgnoresBrokenPipe() {
        let pipe = Pipe()
        let writer = ChildStdinWriter()
        writer.attach(pipe.fileHandleForWriting)
        try? pipe.fileHandleForReading.close()
        writer.write(line: "x")
        writer.close()
        writer.write(line: "y")
    }

    /// 動的な割り振りでは、子が終わったときの「未完了」は渡したシナリオだけで数える
    func testMultiplexerUsesAssignedIDsAndSynthesizesNeverHanded() {
        var mux = MachineFanoutMultiplexer(groupMachines: [nil], assignedScenarioIDs: [["A.a", "A.b", "A.c"]])
        let lines = mux.childExited(0, exitCode: 1, assigned: ["A.a"])
        XCTAssertEqual(mux.totalFailed, 1)
        XCTAssertTrue(lines.contains { $0.contains("A.a") })
        XCTAssertFalse(lines.contains { $0.contains("A.b") })
        let more = mux.neverHanded(["A.b", "A.c"])
        XCTAssertEqual(mux.totalFailed, 3)
        XCTAssertTrue(more.contains { $0.contains("scenarioFinished") })
    }
}
