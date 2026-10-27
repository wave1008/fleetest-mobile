// 複数対象の1回実行(RR-8.2)の配り手と CLI の口。デバイスもプロセスも使わない
// (子の起動は偽物・時計とタイマーは手動)。

import XCTest
import ArgumentParser
import FTCore
@testable import fleetest

final class MultiTargetRunnerTests: XCTestCase {

    // MARK: - 偽の環境

    private final class Harness: @unchecked Sendable {
        // @unchecked の根拠: 可変状態は全部 LockedValue の中
        let clock = LockedValue(0.0)
        let timers = LockedValue<[(afterMs: Double, fire: @Sendable () -> Void)]>([])
        let launches = LockedValue<[(job: String, machine: Int)]>([])
        let finishers = LockedValue<[String: @Sendable (Int32) -> Void]>([:])
        let pending = LockedValue<[String: [DynamicSplit.Scenario]]>([:])
        let exited = LockedValue<[(job: String, entry: Int)]>([])
        let interrupted = LockedValue<[String]>([])
        var coordinator: MultiTargetCoordinator!

        static func key(_ job: String, _ machine: Int) -> String { "\(job)#\(machine)" }

        /// lanes: 仕事 → そのマシンの添字の集合(entry はマシンの添字と同じにする)。scenarios: 仕事 → 本数(1本 1000ms)
        init(machines: Int, lanes: [String: Set<Int>], scenarios: [String: Int], order: [String]) {
            for (job, count) in scenarios {
                pending.withLock {
                    $0[job] = (0..<count).map { DynamicSplit.Scenario(id: "\(job).s\($0)", platform: "ios") }
                }
            }
            let specs = order.map { id -> MultiTargetCoordinator.Job in
                var laneMap: [Int: MultiTargetCoordinator.Lane] = [:]
                for machine in lanes[id] ?? [] {
                    laneMap[machine] = .init(entry: machine, devices: 1, platforms: ["ios"])
                }
                return MultiTargetCoordinator.Job(
                    id: id, lanes: laneMap,
                    pending: { [self] in pending.withLock { $0[id] ?? [] } },
                    estimateMs: { _, _ in 1000 },
                    childExited: { [self] entry in exited.withLock { $0.append((id, entry)) } },
                    interrupt: { [self] in interrupted.withLock { $0.append(id) } })
            }
            coordinator = MultiTargetCoordinator(
                jobs: specs, machineCount: machines, overheadMs: Array(repeating: 0, count: machines),
                nowMs: { [self] in clock.withLock { $0 } },
                timer: { [self] afterMs, fire in
                    timers.withLock { $0.append((afterMs, fire)) }
                    return {}
                },
                launch: { [self] job, machine, finished in
                    launches.withLock { $0.append((job, machine)) }
                    finishers.withLock { $0[Self.key(job, machine)] = finished }
                })
        }

        var launched: [String] { launches.withLock { $0.map { "\($0.job)@\($0.machine)" } } }

        /// 仕事の残りを配り切った状態にしてから、その子を終わらせる
        func finish(_ job: String, _ machine: Int, code: Int32 = 0, drain: Bool = true) {
            if drain { pending.withLock { $0[job] = [] } }
            let finisher = finishers.withLock { $0[Self.key(job, machine)] }
            XCTAssertNotNil(finisher, "\(job)@\(machine) の子が起こされていない")
            finisher?(code)
        }
    }

    // MARK: - 配り手

    func testTwoJobsTwoMachinesStartAtOnceLongestFirst() {
        let h = Harness(machines: 2, lanes: ["A": [0, 1], "B": [0, 1]],
                        scenarios: ["A": 10, "B": 2], order: ["B", "A"])
        h.coordinator.start()
        XCTAssertEqual(h.launched.count, 2, "空いている2台が両方すぐ仕事を取る: \(h.launched)")
        XCTAssertEqual(h.launched.first, "A@0", "見込みの長い仕事から取る(宣言順 B,A に依らない)")
        XCTAssertEqual(Set(h.launched), ["A@0", "B@1"])
    }

    func testThirdMachineJoinsTheLongestRunningJobWhenNothingIsUnstarted() {
        let h = Harness(machines: 3, lanes: ["A": [0, 1, 2], "B": [0, 1, 2]],
                        scenarios: ["A": 10, "B": 2], order: ["A", "B"])
        h.coordinator.start()
        XCTAssertTrue(h.launched.contains("A@2"), "未開始が無い終わり際は残りの多い仕事に加わる: \(h.launched)")
    }

    func testMachineWithoutALaneNeverGetsTheJob() {
        let h = Harness(machines: 2, lanes: ["C": [0], "D": [0, 1]],
                        scenarios: ["C": 10, "D": 4], order: ["C", "D"])
        h.coordinator.start()
        h.finish("D", 1)
        h.finish("C", 0)
        XCTAssertFalse(h.launched.contains("C@1"), "レーンの無いマシンへ配った: \(h.launched)")
        XCTAssertTrue(h.launched.allSatisfy { !$0.hasPrefix("C@") || $0 == "C@0" })
    }

    func testChildExitStartsTheNextJobOnThatMachine() {
        let h = Harness(machines: 1, lanes: ["A": [0], "B": [0]],
                        scenarios: ["A": 5, "B": 1], order: ["A", "B"])
        h.coordinator.start()
        XCTAssertEqual(h.launched, ["A@0"], "マシンは同時に1つの子だけ")
        h.finish("A", 0)
        XCTAssertEqual(h.launched, ["A@0", "B@0"])
        XCTAssertEqual(h.exited.withLock { $0.map { "\($0.job):\($0.entry)" } }, ["A:0"],
                       "子が終わったら仕事の配り手へ知らせる")
        h.finish("B", 0)
        XCTAssertEqual(h.coordinator.statuses, [.finished])
    }

    func testWaitUntilFinishedReturnsAfterEverythingEnds() async {
        let h = Harness(machines: 1, lanes: ["A": [0]], scenarios: ["A": 1], order: ["A"])
        h.coordinator.start()
        h.finish("A", 0)
        await h.coordinator.waitUntilFinished()
        XCTAssertTrue(h.coordinator.unstartedJobs.isEmpty)
    }

    func testInterruptStopsStartingAndWaitsForRunningChildren() async {
        let h = Harness(machines: 1, lanes: ["A": [0], "B": [0]],
                        scenarios: ["A": 5, "B": 5], order: ["A", "B"])
        h.coordinator.start()
        h.coordinator.interrupt()
        XCTAssertEqual(Set(h.interrupted.withLock { $0 }), ["A", "B"], "全仕事の配り手へ中断を伝える")
        h.finish("A", 0, drain: false)
        await h.coordinator.waitUntilFinished()
        XCTAssertEqual(h.launched, ["A@0"], "中断後は子を起こさない")
        XCTAssertEqual(h.coordinator.unstartedJobs, ["B"])
        XCTAssertTrue(h.coordinator.isInterrupted)
    }

    func testAbnormalExitRetiresTheMachine() {
        let h = Harness(machines: 2, lanes: ["A": [0, 1], "B": [0, 1]],
                        scenarios: ["A": 10, "B": 10], order: ["A", "B"])
        h.coordinator.start()
        h.finish("A", 0, code: 137, drain: false)
        XCTAssertEqual(h.coordinator.statuses[0], .finished, "異常終了したマシンには以後配らない")
        XCTAssertTrue(h.coordinator.deadMachines.contains(0))
        XCTAssertEqual(h.launched.filter { $0.hasSuffix("@0") }, ["A@0"])
    }

    func testExitCodeOneIsAScenarioFailureNotACrash() {
        let h = Harness(machines: 1, lanes: ["A": [0], "B": [0]],
                        scenarios: ["A": 1, "B": 1], order: ["A", "B"])
        h.coordinator.start()
        h.finish("A", 0, code: 1)
        XCTAssertEqual(h.launched, ["A@0", "B@0"], "シナリオの失敗(1)でマシンを外さない")
        XCTAssertTrue(h.coordinator.deadMachines.isEmpty)
    }

    // MARK: - CLI の口

    private func rejected<C: ParsableCommand>(_ type: C.Type, _ arguments: [String]) -> Bool {
        (try? type.parse(arguments)) == nil
    }

    func testRepeatedProfileBecomesTargetsOfTheSameProject() throws {
        let command = try RunScenarios.parse(["--project", "A", "--profile", "p1", "--profile", "p2"])
        XCTAssertEqual(try command.multiTargets(), [
            .init(project: "A", profile: "p1"), .init(project: "A", profile: "p2")])
        XCTAssertEqual(command.common.profile, "p1", "単一経路が読む profile は先頭")
    }

    func testTargetFlagParsesProjectAndProfile() throws {
        let command = try RunScenarios.parse(["--target", "A:p1", "--target", "B:p2"])
        XCTAssertEqual(try command.multiTargets(), [
            .init(project: "A", profile: "p1"), .init(project: "B", profile: "p2")])
    }

    func testSingleProfileIsNotMultiTarget() throws {
        XCTAssertEqual(try RunScenarios.parse(["--profile", "p"]).multiTargets(), [])
        XCTAssertEqual(try RunScenarios.parse([]).multiTargets(), [])
        // --target 1個は通常の経路へ読み替える(対象として返る)
        XCTAssertEqual(try RunScenarios.parse(["--target", "A:p"]).multiTargets(),
                       [.init(project: "A", profile: "p")])
    }

    func testTargetParsingRejectsMalformedSpecs() {
        for spec in ["A", ":p", "A:", ""] {
            XCTAssertThrowsError(try MultiTargetRunner.parse(spec), "\(spec)")
        }
        XCTAssertEqual(try MultiTargetRunner.parse("A:p:q"), .init(project: "A", profile: "p:q"))
    }

    func testRunRejectsUnsupportedCombinationsWithSeveralTargets() {
        let two = ["--profile", "p", "--profile", "q"]
        for extra in [["--broadcast"], ["--fleet", "f"], ["--runner", "m1"], ["--dry-run"],
                      ["--scenario", "K.m"], ["--folder", "x"], ["--failed"], ["--port", "8123"],
                      ["--platform", "ios"], ["--serial", "R58M"], ["--device", "d"]] {
            XCTAssertTrue(rejected(RunScenarios.self, two + extra), "\(extra) は複数対象と併用できない")
        }
        XCTAssertFalse(rejected(RunScenarios.self, two + ["--set", "record=false", "--no-lpt", "--quiet",
                                                          "--junit", NSTemporaryDirectory() + "mt.xml",
                                                          "--wait-lock", "30", "--performance"]),
                       "引き渡す側のオプションは通る")
    }

    func testTargetCannotBeCombinedWithProjectOrProfileOrDuplicates() {
        XCTAssertTrue(rejected(RunScenarios.self, ["--target", "A:p", "--profile", "q"]))
        XCTAssertTrue(rejected(RunScenarios.self, ["--target", "A:p", "--project", "A"]))
        XCTAssertTrue(rejected(RunScenarios.self, ["--target", "A:p", "--target", "A:p"]))
        XCTAssertTrue(rejected(RunScenarios.self, ["--profile", "p", "--profile", "p"]))
        XCTAssertTrue(rejected(RunScenarios.self, ["--target", "nocolon"]))
    }

    func testApiRunRejectsSeveralProfilesAndHasNoTargetFlag() {
        XCTAssertTrue(rejected(ApiRunCommand.self, ["--scenario", "K.m", "--profile", "p", "--profile", "q"]))
        XCTAssertTrue(rejected(ApiRunCommand.self, ["--scenario", "K.m", "--target", "A:p"]))
        XCTAssertFalse(rejected(ApiRunCommand.self, ["--scenario", "K.m", "--profile", "p"]))
    }

    func testFirstRejectionNamesTheFirstSetFlagInTheGivenOrder() {
        XCTAssertNil(MultiTargetRunner.firstRejection(flags: [("--a", false), ("--b", false)]))
        XCTAssertEqual(MultiTargetRunner.firstRejection(flags: [("--a", false), ("--b", true), ("--c", true)]),
                       "--b cannot be combined with several targets (repeated --profile or --target)")
    }
}
