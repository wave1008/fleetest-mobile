// 逆走査の門(contentShifted)・本数の上限(reverseSweepDragBudget)・入れ子の軸の案内を固定する。

import XCTest
@testable import FTCore

final class ScrollSweepGateTests: XCTestCase {

    private func el(_ id: String?, label: String? = nil, y: Double = 0, x: Double = 0) -> ElementInfo {
        ElementInfo(ref: 1, type: "other", identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: 100, height: 50), depth: 3)
    }

    /// 位置表示の文字だけが変わった・数 pt のバウンスは「中身がずれた」ではない(端から動かなかった探索が逆走査へ入っていた)
    func testLabelChangeAndBounceAreNotAShift() {
        let a = [el("row_1", y: 100), el("status", label: "at_bottom=true")]
        let b = [el("row_1", y: 101), el("status", label: "at_bottom=false")]
        XCTAssertFalse(ScrollGeometry.contentShifted(before: a, after: b, vertical: true))
    }

    func testRealMoveAndRowChurnAreAShift() {
        XCTAssertTrue(ScrollGeometry.contentShifted(before: [el("row_1", y: 100)], after: [el("row_1", y: 20)], vertical: true))
        XCTAssertTrue(ScrollGeometry.contentShifted(before: [el("row_1", y: 100)], after: [el("row_9", y: 100)], vertical: true))
        // 軸が違う動きは数えない
        XCTAssertFalse(ScrollGeometry.contentShifted(before: [el("c", x: 0)], after: [el("c", x: 50)], vertical: true))
    }

    func testIdlessTreeFallsBackToSignature() {
        XCTAssertTrue(ScrollGeometry.contentShifted(before: [el(nil, label: "a")], after: [el(nil, label: "b")], vertical: true))
    }

    /// 戻す本数は最後に動いた1本の移動量から(8 本の払いで進んだ分を全部は戻さない)
    func testBudgetFollowsLastSwipe() {
        let c = FTRect(x: 0, y: 0, width: 400, height: 600)
        XCTAssertEqual(StepExecutor.reverseSweepDragBudget(lastSwipeTravel: 600, container: c, vertical: true), 3)
        XCTAssertEqual(StepExecutor.reverseSweepDragBudget(lastSwipeTravel: 10, container: c, vertical: true), 2)
        XCTAssertEqual(StepExecutor.reverseSweepDragBudget(lastSwipeTravel: nil, container: c, vertical: true),
                       StepExecutor.reverseSweepMaxSwipes)
        XCTAssertEqual(StepExecutor.reverseSweepDragBudget(lastSwipeTravel: 99999, container: c, vertical: true),
                       StepExecutor.reverseSweepMaxSwipes)
    }

    /// 入れ子で外側が動いた失敗(stoppedUnmoving でない)も、軸の違いと対処を言う。「swept-back position」の後に対象を直結しない
    func testNestedOuterMovedMessage() {
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "card"), direction: "down", maxSwipes: 3)
        var r = StepExecutor.ScrollSearchResult(found: false, fallback: nil, viaXCUITest: false, hintJumps: 0, swipes: 3)
        r.scrollFrameOtherAxis = true
        r.reverseSweepRan = true
        r.reverseSweepBudget = 2
        let m = StepExecutor.scrollNotFoundMessage(step, r, defaultMaxSwipes: 8)
        XCTAssertTrue(m.contains("scrolls horizontally"), m)
        XCTAssertTrue(m.contains("up to 2 slow drags"), m)
        XCTAssertFalse(m.contains("position: "), m)
    }
}
