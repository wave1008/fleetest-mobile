// DynamicSplit.decide(RR-8.1)。期待値は手計算で固定する。

import XCTest
@testable import FTCore

final class DynamicSplitTests: XCTestCase {

    private typealias S = DynamicSplit.Scenario
    private typealias L = DynamicSplit.Lane
    private typealias State = DynamicSplit.LaneState

    private func scenario(_ id: String, _ platform: String = "ios") -> S { S(id: id, platform: platform) }
    private func lane(_ entry: Int, _ name: String, _ platform: String = "ios") -> L {
        L(entry: entry, lane: name, platform: platform)
    }

    /// "id" → [entry 0 の見込み, entry 1 の見込み, ...]
    private func table(_ values: [String: [Double]]) -> (S, Int) -> Double {
        { scenario, entry in values[scenario.id]![entry] }
    }

    func testEqualMachinesBothIdleAssignsLongest() {
        let fast = lane(0, "a"), other = lane(1, "b")
        let decision = DynamicSplit.decide(
            for: fast, now: 0, pending: [scenario("short"), scenario("long")],
            lanes: [State(lane: fast, busy: nil), State(lane: other, busy: nil)],
            estimateMs: table(["short": [10_000, 10_000], "long": [60_000, 60_000]]))
        XCTAssertEqual(decision, .assign("long"))
    }

    func testSlowMachineHoldsWhileFastLaneIsIdle() {
        let fast = lane(0, "a"), slow = lane(1, "b")
        let decision = DynamicSplit.decide(
            for: slow, now: 0, pending: [scenario("s")],
            lanes: [State(lane: fast, busy: nil), State(lane: slow, busy: nil)],
            estimateMs: table(["s": [30_000, 60_000]]))
        XCTAssertEqual(decision, .hold(reconsiderAt: nil))
    }

    func testSlowMachineHoldsUntilBusyFastLaneFrees() {
        let fast = lane(0, "a"), slow = lane(1, "b")
        let running = scenario("run")
        // fast は 0 に渡した run(60s)を回していて now=50s のとき空く見込みは 60s。
        // s は fast なら 60s + 60s = 120s・slow なら 50s + 120s = 170s → 待つ。
        let decision = DynamicSplit.decide(
            for: slow, now: 50_000, pending: [scenario("s")],
            lanes: [State(lane: fast, busy: (running, 0)), State(lane: slow, busy: nil)],
            estimateMs: table(["s": [60_000, 120_000], "run": [60_000, 120_000]]))
        XCTAssertEqual(decision, .hold(reconsiderAt: 60_000))
    }

    func testSlowMachineTakesShortScenarioRatherThanWaiting() {
        let fast = lane(0, "a"), slow = lane(1, "b")
        let decision = DynamicSplit.decide(
            for: slow, now: 0, pending: [scenario("s")],
            lanes: [State(lane: fast, busy: (scenario("run"), 0)), State(lane: slow, busy: nil)],
            estimateMs: table(["s": [5_000, 10_000], "run": [30_000, 60_000]]))
        // slow なら 10s・fast を待つと 30s + 5s = 35s
        XCTAssertEqual(decision, .assign("s"))
    }

    /// 相手の見込みの時刻ちょうどでも、次に判定し直す時刻を作る(作らないとタイマーが消えて待ちが続く)
    func testReconsiderTimeIsKeptWhenNowEqualsTheExpectedFreeTime() {
        let fast = lane(0, "a"), slow = lane(1, "b")
        // fast は 0 に渡した run(60s)を回していて now = 60s = 見込み。s は fast なら 60 + 60 = 120s・slow なら 60 + 120 = 180s → 待つ。
        // 反転は t + (t - 60) + 60 >= t + 120 → t >= 120s
        let decision = DynamicSplit.decide(
            for: slow, now: 60_000, pending: [scenario("s")],
            lanes: [State(lane: fast, busy: (scenario("run"), 0)), State(lane: slow, busy: nil)],
            estimateMs: table(["s": [60_000, 120_000], "run": [60_000, 120_000]]))
        XCTAssertEqual(decision, .hold(reconsiderAt: 120_000))
    }

    /// `--no-lpt`: 候補を ID 順に試す(見込みの長さで並べ替えない)
    func testNoLPTTriesCandidatesInIDOrder() {
        let fast = lane(0, "a"), other = lane(1, "b")
        let decision = DynamicSplit.decide(
            for: fast, now: 0, pending: [scenario("Z.long"), scenario("A.short")],
            lanes: [State(lane: fast, busy: nil), State(lane: other, busy: nil)],
            estimateMs: table(["A.short": [10_000, 10_000], "Z.long": [60_000, 60_000]]), lpt: false)
        XCTAssertEqual(decision, .assign("A.short"))
    }

    func testOverdueLaneEventuallyLetsSlowLaneTake() {
        let fast = lane(0, "a"), slow = lane(1, "b")
        let lanes = [State(lane: fast, busy: (scenario("run"), 0)), State(lane: slow, busy: nil)]
        let estimate = table(["s": [60_000, 120_000], "run": [60_000, 120_000]])
        // 見込み 60s を 40s 超過 → 空く時刻を 140s と倒す。alt = 200s < here = 220s → 待つ。
        // 反転は t >= 60_000 + 120_000 - 60_000 = 120_000
        let first = DynamicSplit.decide(for: slow, now: 100_000, pending: [scenario("s")],
                                        lanes: lanes, estimateMs: estimate)
        XCTAssertEqual(first, .hold(reconsiderAt: 120_000))
        // その時刻: alt = (120s + 60s) + 60s = 240s = here → 渡す
        let second = DynamicSplit.decide(for: slow, now: 120_000, pending: [scenario("s")],
                                         lanes: lanes, estimateMs: estimate)
        XCTAssertEqual(second, .assign("s"))
    }

    func testPlatformFilter() {
        let requester = lane(0, "a", "ios")
        let lanes = [State(lane: requester, busy: nil)]
        let estimate = table(["x": [1_000]])
        XCTAssertEqual(DynamicSplit.decide(for: requester, now: 0, pending: [scenario("x", "android")],
                                           lanes: lanes, estimateMs: estimate), .none)
        XCTAssertEqual(DynamicSplit.decide(for: requester, now: 0, pending: [],
                                           lanes: lanes, estimateMs: estimate), .none)
    }

    func testTieBrokenByIDAscending() {
        let a = lane(0, "a"), b = lane(1, "b")
        let decision = DynamicSplit.decide(
            for: a, now: 0, pending: [scenario("z"), scenario("m")],
            lanes: [State(lane: a, busy: nil), State(lane: b, busy: nil)],
            estimateMs: table(["z": [5_000, 5_000], "m": [5_000, 5_000]]))
        XCTAssertEqual(decision, .assign("m"))
    }

    func testNoOtherLanesOfPlatformNeverHolds() {
        let requester = lane(1, "slow"), android = lane(0, "droid", "android")
        let decision = DynamicSplit.decide(
            for: requester, now: 0, pending: [scenario("s")],
            lanes: [State(lane: requester, busy: nil), State(lane: android, busy: nil)],
            estimateMs: table(["s": [1_000, 999_000]]))
        XCTAssertEqual(decision, .assign("s"))
    }
}
