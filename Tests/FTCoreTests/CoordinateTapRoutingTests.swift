// 座標タップの経路(`StepExecutor.executeDirectCoordinateTap`)。
// witness: E2EX-CMP のメニュー(Compose の DropdownMenu)。開いている間は木にメニューしか居らず、
// 外側の点への in-app の合成タッチは Popup に届かないまま成功を返していた(XCUITest では閉じる)。
// 自前描画(か判定不明)で、木のどの要素も含まない点は最初から XCUITest で撃つ。

import XCTest
@testable import FTCore

final class CoordinateTapRoutingTests: XCTestCase {

    private let menuItem = ElementInfo(ref: 1, type: "button", identifier: "menu_item_copy", label: "コピー",
                                       value: nil, placeholder: nil, enabled: true,
                                       frame: FTRect(x: 16, y: 190, width: 112, height: 48), depth: 1)

    private func run(uiFramework: AppUIFramework?, x: Double, y: Double,
                     withTypeDriver: Bool = true) async -> (StepOutcome, CoordinateTapStub, CoordinateTapStub) {
        let primary = CoordinateTapStub(elements: [menuItem])
        let xcuitest = CoordinateTapStub(elements: [])
        let executor = StepExecutor(driver: primary, typeDriver: withTypeDriver ? xcuitest : nil,
                                    isAndroid: false, tunables: RunTunables(), uiFramework: uiFramework)
        let outcome = await executor.execute(FlowStep(action: "tap", x: x, y: y))
        return (outcome, primary, xcuitest)
    }

    /// **witness**: Compose で要素の無い点 → XCUITest で撃つ(in-app には触らない)
    func testSelfRenderedPointWithoutAnElementGoesToXCUITest() async {
        let (outcome, primary, xcuitest) = await run(uiFramework: .compose, x: 200, y: 600)
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "\(outcome.status)")
        XCTAssertEqual(xcuitest.taps.count, 1)
        XCTAssertTrue(primary.taps.isEmpty)
        XCTAssertEqual(outcome.driverFallback, "sent via XCUITest (no element at this point in the tree)")
    }

    /// 判定不明も安全側(XCUITest)
    func testUnknownFrameworkIsTreatedLikeSelfRendered() async {
        let (_, primary, xcuitest) = await run(uiFramework: nil, x: 200, y: 600)
        XCTAssertEqual(xcuitest.taps.count, 1)
        XCTAssertTrue(primary.taps.isEmpty)
    }

    /// 要素がある点は今までどおり in-app
    func testPointOnAnElementStaysInApp() async {
        let (_, primary, xcuitest) = await run(uiFramework: .compose, x: 50, y: 200)
        XCTAssertEqual(primary.taps.count, 1)
        XCTAssertTrue(xcuitest.taps.isEmpty)
    }

    /// 自前描画でないと分かっているアプリは今までどおり in-app(hitTest で実体へ撃てる)
    func testUIKitStaysInApp() async {
        let (_, primary, xcuitest) = await run(uiFramework: .uikit, x: 200, y: 600)
        XCTAssertEqual(primary.taps.count, 1)
        XCTAssertTrue(xcuitest.taps.isEmpty)
    }

    /// XCUITest が無い構成(in-app 単独・Android)は今までどおり
    func testWithoutXCUITestTheTapStaysOnTheDriver() async {
        let (_, primary, _) = await run(uiFramework: .compose, x: 200, y: 600, withTypeDriver: false)
        XCTAssertEqual(primary.taps.count, 1)
    }

    private func runDoubleTap(uiFramework: AppUIFramework?, x: Double, y: Double,
                              primaryError: Error? = nil, settle: Bool? = nil)
        async -> (StepOutcome, CoordinateTapStub, CoordinateTapStub) {
        let primary = CoordinateTapStub(elements: [menuItem])
        primary.doubleTapError = primaryError
        let xcuitest = CoordinateTapStub(elements: [])
        let executor = StepExecutor(driver: primary, typeDriver: xcuitest,
                                    isAndroid: false, tunables: RunTunables(), uiFramework: uiFramework)
        let outcome = await executor.execute(FlowStep(action: "doubleTap", settle: settle, x: x, y: y))
        return (outcome, primary, xcuitest)
    }

    /// 座標の doubleTap は x/y のまま届く(`gestureActions` の対象未指定経路 = 画面中心へ化けない)
    func testCoordinateDoubleTapReachesTheDriverWithItsCoordinates() async {
        let (outcome, primary, xcuitest) = await runDoubleTap(uiFramework: .uikit, x: 50, y: 200)
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "\(outcome.status)")
        XCTAssertEqual(primary.doubleTaps.count, 1)
        XCTAssertEqual(primary.doubleTaps.first?.0, 50)
        XCTAssertEqual(primary.doubleTaps.first?.1, 200)
        XCTAssertTrue(xcuitest.doubleTaps.isEmpty)
    }

    /// 自前描画で要素の無い点は最初から XCUITest
    func testCoordinateDoubleTapOnEmptyPointOfSelfRenderedAppGoesToXCUITest() async {
        let (outcome, primary, xcuitest) = await runDoubleTap(uiFramework: .compose, x: 200, y: 600)
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "\(outcome.status)")
        XCTAssertEqual(xcuitest.doubleTaps.count, 1)
        XCTAssertEqual(xcuitest.doubleTaps.first?.0, 200)
        XCTAssertEqual(xcuitest.doubleTaps.first?.1, 600)
        XCTAssertTrue(primary.doubleTaps.isEmpty)
        XCTAssertEqual(outcome.driverFallback, "sent via XCUITest (no element at this point in the tree)")
    }

    /// in-app が撃てない(501)なら XCUITest へ回す
    func testCoordinateDoubleTap501FallsBackToXCUITest() async {
        let (outcome, _, xcuitest) = await runDoubleTap(
            uiFramework: .uikit, x: 50, y: 200,
            primaryError: DriverError.badResponse(status: 501, body: "not supported"))
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "\(outcome.status)")
        XCTAssertEqual(xcuitest.doubleTaps.count, 1)
        XCTAssertEqual(outcome.driverFallback, "fell back to XCUITest")
    }

    /// 撃った後に整定を待つ(セレクタ形・画面中心形と同じ)。`settle: false` なら待たない。
    /// uikit の点は撃つ前に木を読まないので、読んだ回数がそのまま整定の読みになる
    func testCoordinateDoubleTapSettlesUnlessToldNotTo() async {
        let (settledOutcome, settledDriver, _) = await runDoubleTap(uiFramework: .uikit, x: 50, y: 200)
        XCTAssertTrue(StepExecutor.isSuccess(settledOutcome.status), "\(settledOutcome.status)")
        XCTAssertGreaterThan(settledDriver.snapshotCount, 0)
        let (_, unsettledDriver, _) = await runDoubleTap(uiFramework: .uikit, x: 50, y: 200, settle: false)
        XCTAssertEqual(unsettledDriver.snapshotCount, 0)
    }

    func testFrameContainmentIncludesTheEdges() {
        let frame = FTRect(x: 10, y: 20, width: 30, height: 40)
        XCTAssertTrue(StepExecutor.frame(frame, containsX: 10, y: 20))
        XCTAssertTrue(StepExecutor.frame(frame, containsX: 40, y: 60))
        XCTAssertFalse(StepExecutor.frame(frame, containsX: 40.5, y: 60))
    }
}

private final class CoordinateTapStub: AppDriver {
    private let elements: [ElementInfo]
    private(set) var taps: [(Double, Double)] = []
    init(elements: [ElementInfo]) { self.elements = elements }

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func launch(bundleID: String) async throws {}
    private(set) var snapshotCount = 0
    func snapshot() async throws -> SnapshotResponse {
        snapshotCount += 1
        return SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                         elements: elements, truncatedCount: 0)
    }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws { taps.append((x, y)) }
    var doubleTapError: Error?
    private(set) var doubleTaps: [(Double, Double)] = []
    func doubleTap(x: Double, y: Double) async throws {
        if let doubleTapError { throw doubleTapError }
        doubleTaps.append((x, y))
    }
    func type(ref: Int?, text: String) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}
