// JobSchedule.decide(RR-8.2)。期待値は手計算で固定する。

import XCTest
@testable import FTCore

final class JobScheduleTests: XCTestCase {

    private typealias State = JobSchedule.MachineState

    private func idle(_ m: Int) -> State { State(machine: m, currentJob: nil, expectedFreeAt: nil) }
    private func busy(_ m: Int, _ job: String = "x", until: Double?) -> State {
        State(machine: m, currentJob: job, expectedFreeAt: until)
    }

    /// job → [machine: 見込み]。載っていないマシンでは回せない
    private func decide(
        _ machine: Int, now: Double = 1000, unstarted: [String] = [], running: [String: Set<Int>] = [:],
        pending: Set<String>? = nil, machines: [State], alone: [String: [Int: Double]],
        overhead: [Int: Double] = [:]
    ) -> JobSchedule.Decision {
        JobSchedule.decide(
            for: machine, now: now, unstarted: unstarted, running: running,
            hasPending: { pending?.contains($0) ?? true }, machines: machines,
            aloneMs: { alone[$0]?[$1] }, overheadMs: { overhead[$0] ?? 0 })
    }

    func testEqualIdleMachinesStartLongest() {
        let alone: [String: [Int: Double]] = ["a": [0: 100, 1: 100], "b": [0: 300, 1: 300]]
        XCTAssertEqual(
            decide(0, unstarted: ["a", "b"], machines: [idle(0), idle(1)], alone: alone), .start("b"))
    }

    func testTieBreaksByJobIdAscending() {
        let alone: [String: [Int: Double]] = ["b": [0: 100, 1: 100], "a": [0: 100, 1: 100]]
        XCTAssertEqual(
            decide(0, unstarted: ["b", "a"], machines: [idle(0), idle(1)], alone: alone), .start("a"))
    }

    func testSlowMachineHoldsWhenFastIdleMachineExistsButStartsJobOnlyItCanRun() {
        // 機械0は遅い(1000)・機械1は速い(100)で空いている。j は両方で回せる → 待つ。k は機械0だけ → 始める
        let both: [String: [Int: Double]] = ["j": [0: 1000, 1: 100]]
        XCTAssertEqual(
            decide(0, unstarted: ["j"], machines: [idle(0), idle(1)], alone: both), .hold(reconsiderAt: nil))
        let withK: [String: [Int: Double]] = ["j": [0: 1000, 1: 100], "k": [0: 50]]
        XCTAssertEqual(
            decide(0, unstarted: ["j", "k"], machines: [idle(0), idle(1)], alone: withK), .start("k"))
    }

    func testSlowHoldsUntilFastBusyMachineFreesSoon() {
        // 機械1は 1200 に空く見込み。alt = 1200 + 100 = 1300 < here = 2000 → 待つ・1200 に再判断
        let alone: [String: [Int: Double]] = ["j": [0: 1000, 1: 100]]
        XCTAssertEqual(
            decide(0, unstarted: ["j"], machines: [idle(0), busy(1, until: 1200)], alone: alone),
            .hold(reconsiderAt: 1200))
    }

    func testBusyMachineWithoutEstimateIsNotWaitedFor() {
        let alone: [String: [Int: Double]] = ["j": [0: 1000, 1: 100]]
        XCTAssertEqual(
            decide(0, unstarted: ["j"], machines: [idle(0), busy(1, until: nil)], alone: alone), .start("j"))
    }

    func testOverdueValveFlips() {
        // 機械1の見込み 900 は now=1000 を過ぎている(超過100)。freeAt = 1100 → alt = 1200 < here = 2000 → 待つ
        // 反転時刻 t = 900 + 1000 - 100 = 1800。now=1800 では freeAt = 1800+900=2700 → alt 2800 >= here 2800 → 始める
        let alone: [String: [Int: Double]] = ["j": [0: 1000, 1: 100]]
        let machines = [idle(0), busy(1, until: 900)]
        XCTAssertEqual(
            decide(0, now: 1000, unstarted: ["j"], machines: machines, alone: alone), .hold(reconsiderAt: 1800))
        XCTAssertEqual(
            decide(0, now: 1800, unstarted: ["j"], machines: machines, alone: alone), .start("j"))
    }

    func testOverheadIsCountedOnBothSides() {
        // here = 1000 + 500 + 100 = 1600 / alt = 1000 + 0 + 100 = 1100 → 待つ
        let alone: [String: [Int: Double]] = ["j": [0: 100, 1: 100]]
        XCTAssertEqual(
            decide(0, unstarted: ["j"], machines: [idle(0), idle(1)], alone: alone, overhead: [0: 500]),
            .hold(reconsiderAt: nil))
    }

    func testJoinOnlyWhenNoUnstartedCandidate() {
        // 未着手 u があるうちは join せず待つ(u は機械1が速く空いている)
        let alone: [String: [Int: Double]] = ["u": [0: 1000, 1: 100], "r": [0: 1000, 1: 1000]]
        XCTAssertEqual(
            decide(
                0, unstarted: ["u"], running: ["r": [1]], machines: [idle(0), busy(1, "r", until: 5000)],
                alone: alone),
            .start("u"))
        let blocked: [String: [Int: Double]] = ["u": [0: 1000, 1: 100], "r": [0: 1000, 1: 1000]]
        XCTAssertEqual(
            decide(
                0, unstarted: ["u"], running: ["r": [1]], machines: [idle(0), idle(1)], alone: blocked),
            .hold(reconsiderAt: nil))
        // 未着手が無ければ join: S={1} rS=1/1000・without = 2000・with = 1000 + 1/(0.001+0.001) = 1500 → gain 500
        XCTAssertEqual(
            decide(0, running: ["r": [1]], machines: [idle(0), busy(1, "r", until: 5000)], alone: alone),
            .join("r"))
    }

    func testJoinChoosesLargestGain() {
        // r1: without 1000・with 500 → gain 500 / r2: without 4000・with 1/(0.00025+0.001)=800 → gain 3200
        let alone: [String: [Int: Double]] = [
            "r1": [0: 1000, 1: 1000], "r2": [0: 1000, 2: 4000],
        ]
        XCTAssertEqual(
            decide(
                0, running: ["r1": [1], "r2": [2]],
                machines: [idle(0), busy(1, "r1", until: nil), busy(2, "r2", until: nil)], alone: alone),
            .join("r2"))
    }

    func testJoinRejectedWhenOverheadEatsGain() {
        // 固定費 2000 のあいだに S だけで終わる(rS*o = 2 >= 1)→ 加わらない・走っている仕事があるので待つ
        let alone: [String: [Int: Double]] = ["r": [0: 1000, 1: 1000]]
        XCTAssertEqual(
            decide(
                0, running: ["r": [1]], machines: [idle(0), busy(1, "r", until: nil)], alone: alone,
                overhead: [0: 2000]),
            .hold(reconsiderAt: nil))
    }

    func testJoinSkipsJobWithoutPendingOrAlreadyJoined() {
        let alone: [String: [Int: Double]] = ["r": [0: 1000, 1: 1000]]
        XCTAssertEqual(
            decide(
                0, running: ["r": [1]], pending: [], machines: [idle(0), busy(1, "r", until: nil)], alone: alone),
            .done)
        XCTAssertEqual(
            decide(
                0, running: ["r": [0, 1]], machines: [busy(0, "r", until: nil), busy(1, "r", until: nil)],
                alone: alone),
            .hold(reconsiderAt: nil))
    }

    func testDoneWhenNothingLeft() {
        XCTAssertEqual(decide(0, machines: [idle(0)], alone: [:]), .done)
    }

    func testMachineNeverGetsJobItCannotRun() {
        // 機械0では回せない仕事しか無い → start でも join でもない
        let alone: [String: [Int: Double]] = ["u": [1: 100], "r": [1: 100]]
        XCTAssertEqual(
            decide(
                0, unstarted: ["u"], running: ["r": [1]], machines: [idle(0), busy(1, "r", until: nil)],
                alone: alone),
            .done)
    }
}
