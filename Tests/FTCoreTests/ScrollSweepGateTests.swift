// 入れ子で外側の一覧が動いた失敗の案内(scrollFrame の軸の違い)を固定する。

import XCTest
@testable import FTCore

final class ScrollSweepGateTests: XCTestCase {

    /// 入れ子で外側が動いた失敗(stoppedUnmoving でない)も、軸の違いと対処を言う。「swept-back position」の後に対象を直結しない
    func testNestedOuterMovedMessage() {
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "card"), direction: "down", maxSwipes: 3)
        var r = StepExecutor.ScrollSearchResult(found: false, fallback: nil, viaXCUITest: false, hintJumps: 0, swipes: 3)
        r.scrollFrameOtherAxis = true
        r.reverseSweepRan = true
        let m = StepExecutor.scrollNotFoundMessage(step, r, defaultMaxSwipes: 8)
        XCTAssertTrue(m.contains("scrolls horizontally"), m)
        XCTAssertTrue(m.contains("up to \(StepExecutor.reverseSweepMaxSwipes) slow drags"), m)
        XCTAssertFalse(m.contains("position: "), m)
    }
}
