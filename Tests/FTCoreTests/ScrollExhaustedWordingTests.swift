// 弾切れ(動き続けたまま上限)と回転の失敗文、容器の中だけで比べる署名、払いの回数の上限を固定する。

import XCTest
@testable import FTCore

final class ScrollExhaustedWordingTests: XCTestCase {

    private func step() -> FlowStep {
        FlowStep(action: "scrollTo", locator: FlowLocator(id: "missing"), direction: "up", maxSwipes: 8)
    }

    func testExhaustedWhileMovingSaysRaiseMaxSwipes() {
        var r = StepExecutor.ScrollSearchResult(found: false, fallback: nil, viaXCUITest: false, hintJumps: 0, swipes: 8)
        r.exhaustedWhileMoving = true
        let m = StepExecutor.scrollNotFoundMessage(step(), r, defaultMaxSwipes: 8)
        XCTAssertTrue(m.contains("raise maxSwipes (now 8)"), m)
        XCTAssertFalse(m.contains("will not help"), m)
    }

    func testExhaustedAtTheCeilingDoesNotSayRaise() {
        var r = StepExecutor.ScrollSearchResult(found: false, fallback: nil, viaXCUITest: false, hintJumps: 0, swipes: 100)
        r.exhaustedWhileMoving = true
        var ceiling = step()
        ceiling.maxSwipes = 100
        let m = StepExecutor.scrollNotFoundMessage(ceiling, r, defaultMaxSwipes: 8)
        XCTAssertFalse(m.contains("raise maxSwipes"), m)
        XCTAssertTrue(m.contains("100 swipes is the ceiling"), m)
    }

    func testPlainExhaustionStaysSilent() {
        let r = StepExecutor.ScrollSearchResult(found: false, fallback: nil, viaXCUITest: false, hintJumps: 0, swipes: 8)
        let m = StepExecutor.scrollNotFoundMessage(step(), r, defaultMaxSwipes: 8)
        XCTAssertFalse(m.contains("raise maxSwipes"), m)
    }

    func testScreenResizeIsNotCalledAnEnd() {
        var r = StepExecutor.ScrollSearchResult(found: false, fallback: nil, viaXCUITest: false, hintJumps: 0, swipes: 2)
        r.screenResized = true
        let m = StepExecutor.scrollNotFoundMessage(step(), r, defaultMaxSwipes: 8)
        XCTAssertTrue(m.contains("screen size changed"), m)
        XCTAssertFalse(m.contains("reached its end"), m)
    }

    func testSwipeCountCeilingIsPinned() {
        XCTAssertEqual(ArgumentBounds.swipeCountCeiling, 100)
        XCTAssertNil(ArgumentBounds.violation("maxSwipes", 100))
        XCTAssertNotNil(ArgumentBounds.violation("maxSwipes", 101))
        XCTAssertNil(ArgumentBounds.violation("repeat", 100))
        XCTAssertNotNil(ArgumentBounds.violation("repeat", 101))
    }
}
