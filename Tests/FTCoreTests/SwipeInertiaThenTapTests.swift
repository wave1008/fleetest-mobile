// swipe の直後の tap は、swipe が残した慣性を空打ちで吸ってから撃つ(CMP / Flutter の iOS。
// 負荷テスト 2026-10-30 c F6: tap が ok なのに慣性を止めただけで押せていない)。
// 吸うのは自前描画の iOS で、直前のステップの swipe が慣性を残したときだけ

import XCTest
@testable import FTCore

final class SwipeInertiaThenTapTests: XCTestCase {

    private func row() -> ElementInfo {
        ElementInfo(ref: 1, type: "button", identifier: "row_12", label: "row 12", value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 16, y: 300, width: 370, height: 56), depth: 3)
    }

    private func list() -> ElementInfo {
        ElementInfo(ref: 2, type: "scrollView", identifier: "list", label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 0, y: 100, width: 402, height: 600), depth: 1, scrollable: true)
    }

    private func make(_ app: AppUIFramework, inAppPrimary: Bool = false, releases: Bool = true,
                      inList: Bool = true) -> (StepExecutor, FakeAppDriver) {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [inList ? [list(), row()] : [row()]])
        let executor = StepExecutor(driver: driver, primaryCaptureOmitsSystemUI: inAppPrimary,
                                    releasesScrollTouch: releases, isAndroid: !releases, tunables: RunTunables(),
                                    uiFramework: app)
        return (executor, driver)
    }

    private let swipe = FlowStep(action: "swipe", direction: "up")
    private let tap = FlowStep(action: "tap", locator: FlowLocator(id: "row_12"))

    func testTapAfterSwipeAbsorbsTheMomentumOnCompose() async {
        let (executor, driver) = make(.compose)
        _ = await executor.execute(swipe)
        XCTAssertEqual(driver.dragCalls.count, 0, "swipe 自身は空打ちを撃たない")
        _ = await executor.execute(tap)
        XCTAssertEqual(driver.dragCalls.count, 1)
    }

    func testTheMomentumIsAbsorbedOnlyOnce() async {
        let (executor, driver) = make(.compose)
        _ = await executor.execute(swipe)
        _ = await executor.execute(tap)
        _ = await executor.execute(tap)
        XCTAssertEqual(driver.dragCalls.count, 1)
    }

    func testTapWithoutAPriorSwipeDoesNotDrag() async {
        let (executor, driver) = make(.compose)
        _ = await executor.execute(tap)
        XCTAssertEqual(driver.dragCalls.count, 0)
    }

    func testUIKitAndAndroidDoNotDrag() async {
        let (uikit, uikitDriver) = make(.uikit)
        _ = await uikit.execute(swipe)
        _ = await uikit.execute(tap)
        XCTAssertEqual(uikitDriver.dragCalls.count, 0)
        let (android, androidDriver) = make(.compose, releases: false)
        _ = await android.execute(swipe)
        _ = await android.execute(tap)
        XCTAssertEqual(androidDriver.dragCalls.count, 0)
    }

    func testButtonOutsideAnyListDoesNotPayForTheDrag() async {
        let (executor, driver) = make(.compose, inList: false)
        _ = await executor.execute(swipe)
        _ = await executor.execute(tap)
        XCTAssertEqual(driver.dragCalls.count, 0)
    }

    func testFlutterIsNotDraggedEvenAfterARealFinger() async {
        let (executor, driver) = make(.flutter)
        _ = await executor.execute(swipe)
        _ = await executor.execute(tap)
        XCTAssertEqual(driver.dragCalls.count, 0)
    }

    func testFlutterInAppSwipeLeavesNoInertiaToAbsorb() async {
        let (executor, driver) = make(.flutter, inAppPrimary: true)
        _ = await executor.execute(swipe)
        _ = await executor.execute(tap)
        XCTAssertEqual(driver.dragCalls.count, 0)
    }
}
