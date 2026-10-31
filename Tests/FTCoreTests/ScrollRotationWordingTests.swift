// 回転で打ち切った探索の文言は実際に払った数を言う・scrollToEdge は途中の回転を言って止める。

import XCTest
@testable import FTCore

private final class RotatesAfterFirstSwipeDriver: AppDriver {
    private(set) var swipes = 0
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func terminate() async throws {}
    func screenshot() async throws -> Data { Data() }
    func type(ref: Int?, text: String) async throws {}
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws { swipes += 1 }
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws {}
    func snapshot() async throws -> SnapshotResponse {
        let screen = swipes == 0 ? FTRect(x: 0, y: 0, width: 400, height: 800) : FTRect(x: 0, y: 0, width: 800, height: 400)
        let elements = [ElementInfo(ref: 1, type: "button", identifier: "row_\(swipes)", label: nil, value: nil,
                                    placeholder: nil, enabled: true,
                                    frame: FTRect(x: 16, y: 40, width: 100, height: 56), depth: 0)]
        return SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements, truncatedCount: 0)
    }
}

final class ScrollRotationWordingTests: XCTestCase {
    func testResizedSearchNamesTheSwipesActuallySent() {
        var result = StepExecutor.ScrollSearchResult(found: false, fallback: nil, viaXCUITest: false,
                                                     hintJumps: 0, swipes: 2, maxTruncatedDuringSearch: 0)
        result.screenResized = true
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "x"), direction: "up", maxSwipes: 8)
        let message = StepExecutor.scrollNotFoundMessage(step, result, defaultMaxSwipes: 8)
        XCTAssertTrue(message.contains("after 2 scroll(s)"), message)
        XCTAssertFalse(message.contains("after 8 scroll(s)"), message)
    }

    func testScrollToEdgeStopsAndSaysWhenTheScreenIsRotatedMidway() async throws {
        let driver = RotatesAfterFirstSwipeDriver()
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        let outcome = await executor.execute(FlowStep(action: "scrollToEdge", direction: "up", maxSwipes: 20))
        guard case .failed(let message) = outcome.status else { return XCTFail("回転したのに ok を返した: \(outcome.status)") }
        XCTAssertTrue(message.contains("screen size changed"), message)
        XCTAssertLessThan(driver.swipes, 5, "回転した後も払い続けた")
    }
}
