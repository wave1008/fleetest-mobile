// 動的な割り振りの親の配り手(DynamicDispatcher。RR-8.1)の規律を固定する。デバイス不要(偽の時計・見積り・タイマー)。
// 破ると: 速いマシンが空いているのに遅いマシンが長いシナリオを取って全体が延びる / 供給中のレーンを空きと数えて
// 誰にも渡らない / 返事待ちの子が中断を見られず止まる / 落ちた子へ渡した分が二重に走る。

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
        // ロックの取得中の中断(子を1つも起こしていない)も 130。ValidationError の 64 にしない
        XCTAssertEqual(DeviceMachineRunner.interruptedWhileLocking.rawValue, 130)
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
            XCTAssertTrue(text.contains("throw interruptedWhileLocking") || text.contains("throw DeviceMachineRunner.interruptedWhileLocking"),
                          "\(file) がロックの取得中の中断を共有の出口(130)で抜けていない")
            XCTAssertFalse(text.contains("ValidationError(\"interrupted while acquiring"),
                           "\(file) がロックの取得中の中断を ValidationError(64)で投げている")
        }
        // 渡したのに結果が無い分(子が受け取る前の中断など)も終了コードへ載せる
        for (file, marker) in [("Sources/fleetest/DeviceMachineRunner.swift", "if missing > 0 {"),
                               ("Sources/fleetest/MultiTargetRunner.swift", "if missing > 0 {"),
                               ("Sources/fleetest/ApiRunMachineFanout.swift", "if unfinishedTotal > 0 {")] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains(marker), "\(file) が結果の無いシナリオを終了コードへ載せていない")
        }
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
