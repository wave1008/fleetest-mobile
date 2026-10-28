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
        overhead: [Int: Double] = [:], join: [String: [Int: Double]] = [:], lpt: Bool = true
    ) -> JobSchedule.Decision {
        JobSchedule.decide(
            for: machine, now: now, unstarted: unstarted, running: running,
            hasPending: { pending?.contains($0) ?? true }, machines: machines,
            aloneMs: { alone[$0]?[$1] }, overheadMs: { overhead[$0] ?? 0 }, joinGainMs: { join[$0]?[$1] }, lpt: lpt)
    }

    /// `--no-lpt`: 見込みの長さではなく宣言の順に試す
    func testNoLPTTriesJobsInDeclarationOrder() {
        let alone: [String: [Int: Double]] = ["a": [0: 100, 1: 100], "b": [0: 300, 1: 300]]
        XCTAssertEqual(
            decide(0, unstarted: ["a", "b"], machines: [idle(0), idle(1)], alone: alone, lpt: false), .start("a"))
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

    func testSlowMachineStartsWhenFastMachineHasBacklog() {
        // 機械1(速い)は 1050 に空く。j1 は機械1 で 1150 に終わる → 機械1へ積む。j2 は機械1 だと 1250・機械0 だと 1200 → 機械0 が始める
        let alone: [String: [Int: Double]] = ["j1": [0: 200, 1: 100], "j2": [0: 200, 1: 100]]
        let machines = [idle(0), busy(1, until: 1050)]
        XCTAssertEqual(decide(0, unstarted: ["j1", "j2"], machines: machines, alone: alone), .start("j2"))
        XCTAssertEqual(decide(0, unstarted: ["j1"], machines: machines, alone: alone), .hold(reconsiderAt: 1050))
    }

    func testJobOnlyOtherMachineCanRunCountsAsItsBacklog() {
        // x は機械1 だけ(2000)。先に積むと機械1 は 3000 まで塞がる → j は機械0 で 2000 < 機械1 で 3100 → 始める
        let alone: [String: [Int: Double]] = ["j": [0: 1000, 1: 100], "x": [1: 2000]]
        XCTAssertEqual(
            decide(0, unstarted: ["j", "x"], machines: [idle(0), idle(1)], alone: alone), .start("j"))
    }

    func testOverdueReconsiderTimeCountsBacklog() {
        // 機械1 は見込み 900 を超過(freeAt 1100)。a → 機械1(1200)・b → 機械1(1300)で待つ。
        // b の反転は 900 + 1000 - 100 - (1200 - 1100) = 1700。now=1700: freeAt 2500・a → 機械1(2600)・b は 2700 で同着 → 始める
        let alone: [String: [Int: Double]] = ["a": [0: 1000, 1: 100], "b": [0: 1000, 1: 100]]
        let machines = [idle(0), busy(1, until: 900)]
        XCTAssertEqual(
            decide(0, now: 1000, unstarted: ["a", "b"], machines: machines, alone: alone), .hold(reconsiderAt: 1700))
        XCTAssertEqual(decide(0, now: 1700, unstarted: ["a", "b"], machines: machines, alone: alone), .start("b"))
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
        // 未着手が無ければ join
        XCTAssertEqual(
            decide(0, running: ["r": [1]], machines: [idle(0), busy(1, "r", until: 5000)], alone: alone,
                   join: ["r": [0: 500]]),
            .join("r"))
    }

    func testJoinChoosesLargestGain() {
        let alone: [String: [Int: Double]] = [
            "r1": [0: 1000, 1: 1000], "r2": [0: 1000, 2: 4000],
        ]
        XCTAssertEqual(
            decide(
                0, running: ["r1": [1], "r2": [2]],
                machines: [idle(0), busy(1, "r1", until: nil), busy(2, "r2", until: nil)], alone: alone,
                join: ["r1": [0: 500], "r2": [0: 3200]]),
            .join("r2"))
    }

    func testJoinRejectedWhenGainIsNotPositive() {
        // 早まらない(0)・1本ももらえない(nil)→ 加わらない・走っている仕事があるので待つ
        let alone: [String: [Int: Double]] = ["r": [0: 1000, 1: 1000]]
        for join: [String: [Int: Double]] in [["r": [0: 0]], [:]] {
            XCTAssertEqual(
                decide(0, running: ["r": [1]], machines: [idle(0), busy(1, "r", until: nil)], alone: alone, join: join),
                .hold(reconsiderAt: nil))
        }
    }

    private func joinLane(_ entry: Int, devices: Int, at t: Double, _ platforms: Set<String> = ["ios"]) -> JobSchedule.JoinLane {
        JobSchedule.JoinLane(entry: entry, devices: devices, platforms: platforms, availableAt: t)
    }

    private func scenarios(_ ids: String...) -> [DynamicSplit.Scenario] {
        ids.map { DynamicSplit.Scenario(id: $0, platform: "ios") }
    }

    func testJoinGainIsNilWhenFastMembersTakeEverythingBeforeJoinerArrives() {
        // 担当 2 台が a・b を 10 で終える。加わる側は固定費の後 30 に空く → 1本も積まれない
        XCTAssertNil(JobSchedule.joinGain(
            pending: scenarios("a", "b"), members: [joinLane(0, devices: 2, at: 0)], joiner: joinLane(1, devices: 1, at: 30),
            estimateMs: { _, _ in 10 }))
    }

    func testJoinGainIgnoresScenariosNeitherSideCanRun() {
        // x は android(担当にも加わる側にも回せない = 他のマシンの担当分)。積まずに ios の4本だけで見る → 15 早まる
        let pending = scenarios("a", "b", "c", "d") + [DynamicSplit.Scenario(id: "x", platform: "android")]
        XCTAssertEqual(JobSchedule.joinGain(
            pending: pending, members: [joinLane(0, devices: 1, at: 0)],
            joiner: joinLane(1, devices: 1, at: 5), estimateMs: { _, _ in 10 }), 15)
    }

    func testJoinGainCountsDiscreteScenarios() {
        // 担当 1 台(0 に空く)・加わる側 1 台(5 に空く)・各 10。a → 担当 10・b → 加わる側 15・c → 担当 20・d → 加わる側 25
        // 加わると 25・加わらないと 40 → 15 早まる
        XCTAssertEqual(JobSchedule.joinGain(
            pending: scenarios("a", "b", "c", "d"), members: [joinLane(0, devices: 1, at: 0)],
            joiner: joinLane(1, devices: 1, at: 5), estimateMs: { _, _ in 10 }), 15)
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
