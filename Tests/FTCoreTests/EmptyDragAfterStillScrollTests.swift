// 探索の動きが慣性を残さなかった(Flutter の in-app の送りだけ)ときは、見つけた後の空打ちを撃たない
// (StepExecutor.swipeLeavesNoInertia)。空打ち自身が慣性を作り、流れている間 Flutter は一覧の中の操作を塞ぐ(FD-2.2)

import XCTest
@testable import FTCore

final class EmptyDragAfterStillScrollTests: XCTestCase {

    private func row() -> ElementInfo {
        ElementInfo(ref: 1, type: "button", identifier: "row_40", label: "行 40", value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 16, y: 300, width: 370, height: 56), depth: 3)
    }

    /// 探索の終端で撃った空打ちの数(1回送ると見つかる)
    private func emptyDrags(uiFramework: AppUIFramework, inAppPrimary: Bool, swipesFallBackToXCUITest: Bool = false) async -> Int {
        let primary = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[], [], [row()]])
        let executor = StepExecutor(driver: primary, primaryCaptureOmitsSystemUI: inAppPrimary,
                                    typeDriver: swipesFallBackToXCUITest ? primary : nil,
                                    typeDriverGestures: swipesFallBackToXCUITest ? ["swipe"] : [],
                                    releasesScrollTouch: true, isAndroid: false, tunables: RunTunables(),
                                    uiFramework: uiFramework)
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "row_40"), direction: "up", maxSwipes: 2)
        guard case .passed = await executor.execute(step).status else {
            XCTFail("スワイプ後の snapshot で見つかるので pass のはず"); return -1
        }
        return primary.dragCalls.count
    }

    func testFlutterInAppScrollsSkipTheEmptyDrag() async {
        let n = await emptyDrags(uiFramework: .flutter, inAppPrimary: true)
        XCTAssertEqual(n, 0)
    }

    func testFlutterSwipesThatFellBackToXCUITestKeepTheEmptyDrag() async {
        let n = await emptyDrags(uiFramework: .flutter, inAppPrimary: true, swipesFallBackToXCUITest: true)
        XCTAssertEqual(n, 1)
    }

    func testFlutterInXCUITestModeKeepsTheEmptyDrag() async {
        let n = await emptyDrags(uiFramework: .flutter, inAppPrimary: false)
        XCTAssertEqual(n, 1)
    }

    func testComposeInAppScrollsKeepTheEmptyDrag() async {
        let n = await emptyDrags(uiFramework: .compose, inAppPrimary: true)
        XCTAssertEqual(n, 1)
    }

    func testThePredicate() {
        func make(_ app: AppUIFramework, inApp: Bool) -> StepExecutor {
            StepExecutor(driver: FakeAppDriver(name: "p", log: CallLog()), primaryCaptureOmitsSystemUI: inApp,
                         isAndroid: false, tunables: RunTunables(), uiFramework: app)
        }
        XCTAssertTrue(make(.flutter, inApp: true).swipeLeavesNoInertia(swipedViaXCUITest: false))
        XCTAssertFalse(make(.flutter, inApp: true).swipeLeavesNoInertia(swipedViaXCUITest: true))
        XCTAssertFalse(make(.flutter, inApp: false).swipeLeavesNoInertia(swipedViaXCUITest: false))
        XCTAssertFalse(make(.compose, inApp: true).swipeLeavesNoInertia(swipedViaXCUITest: false))
    }
}
