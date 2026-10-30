// 探索の途中で前面を奪われたとき、木が変わらないのを「端に着いた」と言い切らない。

import XCTest
@testable import FTCore

final class ScrollAppLeftForegroundWordingTests: XCTestCase {

    private let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "missing"), direction: "up", maxSwipes: 8)

    func testLeftForegroundDoesNotClaimTheEnd() {
        var r = StepExecutor.ScrollSearchResult(found: false, fallback: nil, viaXCUITest: false,
                                                hintJumps: 0, swipes: 3)
        r.appLeftForeground = "com.apple.Preferences"
        let m = StepExecutor.scrollNotFoundMessage(step, r, defaultMaxSwipes: 8)
        XCTAssertTrue(m.contains("com.apple.Preferences was in front"), m)
        XCTAssertTrue(m.contains("after 3 scroll(s)"), m)
        XCTAssertFalse(m.contains("reached its end"), m)
    }

    func testFailFastMessageNamesTheFrontWhenTheAppLeft() {
        var scrollFrameStep = step
        scrollFrameStep.scrollFrame = FlowLocator(id: "list")
        var r = StepExecutor.ScrollSearchResult(found: false, fallback: nil, viaXCUITest: false,
                                                hintJumps: 0, swipes: 2, scrollFrameMissing: true)
        r.appLeftForeground = "com.android.systemui"
        let m = StepExecutor.scrollNotFoundMessage(scrollFrameStep, r, defaultMaxSwipes: 8)
        XCTAssertTrue(m.contains("disappeared from the tree"), m)
        XCTAssertTrue(m.contains("com.android.systemui was in front"), m)
    }
}
