// マシンをまたぐ親の `--wait-lock` は入口で期限を1つに決め、各段へ残りを渡す。
import XCTest
@testable import fleetest

final class MachineFanoutFrontHalfTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// 経過した分だけ減る(手元のロック・使用中の待ち・機械ごとの Prelock が同じ期限を共有する)
    func testRemainingShrinksWithElapsedTime() {
        let deadline = WaitLockDeadline(limitSeconds: 900, start: start)
        XCTAssertEqual(deadline.remaining(now: start), 900)
        XCTAssertEqual(deadline.remaining(now: start.addingTimeInterval(300)), 600)
        XCTAssertEqual(deadline.remaining(now: start.addingTimeInterval(300.9)), 600, "秒未満は切り捨て = 経過に数える")
    }

    /// 尽きたら 0(負にしない)。0 は各段で「待たずに断る」と同じ経路(上限に達した断り)に落ちる
    func testRemainingNeverGoesBelowZero() {
        let deadline = WaitLockDeadline(limitSeconds: 60, start: start)
        XCTAssertEqual(deadline.remaining(now: start.addingTimeInterval(60)), 0)
        XCTAssertEqual(deadline.remaining(now: start.addingTimeInterval(10_000)), 0)
    }

    /// `--wait-lock` が無ければ期限も無い(nil = 待たずに断る)。時計が戻っても上限を超えない
    /// 待ちでない区間(ビルド)を外すと、その分だけ残りが戻る
    func testExcludingMovesTheDeadlineByTheNonWaitingTime() {
        let deadline = WaitLockDeadline(limitSeconds: 60, start: start).excluding(40)
        XCTAssertEqual(deadline.remaining(now: start.addingTimeInterval(50)), 50)
    }

    func testNoLimitStaysNilAndBackwardsClockIsClamped() {
        XCTAssertNil(WaitLockDeadline(limitSeconds: nil, start: start).remaining(now: start.addingTimeInterval(5)))
        XCTAssertEqual(WaitLockDeadline(limitSeconds: 30, start: start).remaining(now: start.addingTimeInterval(-50)), 30)
    }

    /// 配線: 前段の各段は `deadline.remaining()` を渡す。`settings.waitLock` を段へ直に渡すと段ごとに N を払い直す
    func testEveryStageReceivesTheRemainingTimeNotTheFullLimit() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/fleetest/MachineFanoutFrontHalf.swift"),
                              encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "settings.waitLock").count - 1, 1,
                       "期限の初期化以外で settings.waitLock を使っている(段ごとに N を払い直す)")
        XCTAssertTrue(text.contains("LocalDispatchLock(\n                runGroup: runGroup, waitLock: deadlineAtEntry.remaining(),"),
                      "手元のロックの先取りが残りを渡していない")
        // ビルドの後の段は、ビルドにかかった時間を外した期限から残りを取る(上限は待ちの合計 = 利用者向けの docs)
        XCTAssertTrue(text.contains("let deadline = deadlineAtEntry.excluding(Date().timeIntervalSince(buildStart))"),
                      "ビルドの時間を待ちの期限に数えている")
        XCTAssertTrue(text.contains("broadcast: check.broadcast, waitLock: deadline.remaining(),"),
                      "手元のデバイスの使用中の待ちが残りを渡していない")
        XCTAssertTrue(text.contains("waitLockProvider: { deadline.remaining() },"),
                      "機械ごとの Prelock が残りを渡していない")
        // 呼び手は段へ waitLock を直に渡さない(前段の Settings だけ)
        for file in ["DeviceMachineRunner", "ApiRunMachineFanout", "MultiTargetRunner"] {
            let caller = try String(contentsOf: root.appendingPathComponent("Sources/fleetest/\(file).swift"),
                                    encoding: .utf8)
            XCTAssertFalse(caller.contains("waitLock: waitLock,\n                interruptCheck"), file)
            XCTAssertFalse(caller.contains("DispatchPrelock.live("), "\(file): Prelock を前段の外で作っている")
        }
    }
}
