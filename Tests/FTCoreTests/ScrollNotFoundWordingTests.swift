// scrollNotFoundMessage の文言が、ツールに言えない帰属を断定せず、逆走査(失敗経路の追加ドラッグ)を隠さないことを固定する。

import XCTest
@testable import FTCore

final class ScrollNotFoundWordingTests: XCTestCase {

    private func step(_ action: String) -> FlowStep {
        FlowStep(action: action, locator: FlowLocator(id: "missing"), direction: "up", maxSwipes: 3)
    }

    private func stopped(moved: Bool, sweepRan: Bool = false,
                         candidate: String? = nil) -> StepExecutor.ScrollSearchResult {
        var r = StepExecutor.ScrollSearchResult(found: false, fallback: nil, viaXCUITest: false,
                                                hintJumps: 0, swipes: 3, stoppedUnmoving: true,
                                                contentEverMoved: moved)
        r.reverseSweepRan = sweepRan
        r.directionMatchedScrollFrameCandidate = candidate
        return r
    }

    /// 1度も動かなかった = 「届いていない」と「既に端」をツールは区別できない。片方を断定しない
    func testNeverMovedDoesNotAssertTheSwipesMissedTheArea() {
        let m = StepExecutor.scrollNotFoundMessage(step("scrollTo"), stopped(moved: false), defaultMaxSwipes: 8)
        XCTAssertFalse(m.contains("are not reaching"), m)
        XCTAssertTrue(m.contains("already at its end in this direction"), m)
        XCTAssertTrue(m.contains("did not reach a scrolling area"), m)
    }

    /// 逆走査を撃った失敗は、数に入らない遅いドラッグが走ったことを文中で言う
    func testFailureMentionsTheReverseSweepWhenItRan() {
        let m = StepExecutor.scrollNotFoundMessage(step("scrollTo"), stopped(moved: true, sweepRan: true),
                                                   defaultMaxSwipes: 8)
        XCTAssertTrue(m.contains("reverse sweep of up to \(StepExecutor.reverseSweepMaxSwipes) slow drags"), m)
        XCTAssertTrue(m.contains("not counted in the 3 above"), m)
    }

    /// 撃っていなければ言わない
    func testFailureStaysSilentWhenNoReverseSweepRan() {
        let m = StepExecutor.scrollNotFoundMessage(step("scrollTo"), stopped(moved: true), defaultMaxSwipes: 8)
        XCTAssertFalse(m.contains("reverse sweep"), m)
    }

    /// `scrollFrame:` を取るのは scrollTo だけ。tap / exist には withScroll*(scrollFrame:) を勧める
    func testScrollFrameAdviceMatchesWhatTheCommandAccepts() {
        let r = stopped(moved: true, candidate: "#list")
        let forScrollTo = StepExecutor.scrollNotFoundMessage(step("scrollTo"), r, defaultMaxSwipes: 8)
        XCTAssertTrue(forScrollTo.contains("consider passing scrollFrame:"), forScrollTo)
        XCTAssertTrue(forScrollTo.contains("(scrollFrame: \"#list\")"), forScrollTo)
        let forTap = StepExecutor.scrollNotFoundMessage(step("tap"), r, defaultMaxSwipes: 8)
        XCTAssertFalse(forTap.contains("passing scrollFrame:"), forTap)
        // 指の向き up = 下へ送る探索 → そのまま貼れる withScrollDown を名指しする
        XCTAssertTrue(forTap.contains("withScrollDown(scrollFrame: \"#list\")"), forTap)
    }

    /// 案内のブロックはそのまま貼る行なので、セレクタは Swift の文字列リテラルとしてエスケープする
    func testWithScrollAdviceEscapesTheSelectorAsASwiftLiteral() {
        let r = stopped(moved: true, candidate: #"Say \"hi\" \ there"#)
        let forTap = StepExecutor.scrollNotFoundMessage(step("tap"), r, defaultMaxSwipes: 8)
        XCTAssertTrue(forTap.contains(#"withScrollDown(scrollFrame: "Say \\\"hi\\\" \\ there") { }"#), forTap)
    }
}
