// ステップ実行器が撃つ ref に、解決に使った木の要素を期待として添える(RefExpectationScope)ことの固定。
// 照合はドライバ(BridgeClient・AndroidDriver)が自分の最新の表とで行い、食い違えば撃たずに staleRef を投げる。

import XCTest
@testable import FTCore

final class RefExpectationScopeTests: XCTestCase {

    private func expectation(_ id: String?, _ type: String) -> RefExpectation {
        RefExpectation(identifier: id, type: type)
    }

    func testIdentifierMismatchContradicts() {
        XCTAssertTrue(RefExpectationScope.contradicts(expectation("send", "button"), latest: expectation("cancel", "button")))
    }

    func testTypeMismatchContradicts() {
        XCTAssertTrue(RefExpectationScope.contradicts(expectation(nil, "button"), latest: expectation(nil, "textField")))
        XCTAssertTrue(RefExpectationScope.contradicts(expectation("a", "button"), latest: expectation("a", "staticText")))
    }

    func testSameElementDoesNotContradictAcrossTypeCase() {
        XCTAssertFalse(RefExpectationScope.contradicts(expectation("a", "Button"), latest: expectation("a", "button")))
    }

    /// ホストの正規化(wrapperScrollMerge)が other を容器の型へ書き換えるので、other はどちら側でも照合しない
    func testOtherOnEitherSideIsNotCompared() {
        XCTAssertFalse(RefExpectationScope.contradicts(expectation("list", "scrollView"), latest: expectation("list", "other")))
        XCTAssertFalse(RefExpectationScope.contradicts(expectation("list", "other"), latest: expectation("list", "scrollView")))
        XCTAssertTrue(RefExpectationScope.contradicts(expectation("list", "other"), latest: expectation("row", "other")),
                      "other でも identifier の食い違いは断る")
    }

    func testMissingSideNeverContradicts() {
        XCTAssertFalse(RefExpectationScope.contradicts(nil, latest: expectation("a", "button")))
        XCTAssertFalse(RefExpectationScope.contradicts(expectation("a", "button"), latest: nil))
        XCTAssertFalse(RefExpectationScope.contradicts(expectation(nil, "button"), latest: expectation("a", "button")))
        XCTAssertFalse(RefExpectationScope.contradicts(expectation("", "button"), latest: expectation("a", "button")))
    }

    /// 包んだ中だけで見え、外では nil(次の操作へ持ち越さない)
    func testExpectationIsScopedToTheFiringClosure() async {
        let element = ElementInfo(ref: 3, type: "button", identifier: "go", label: "Go", value: nil, placeholder: nil,
                                  enabled: true, frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 1)
        let seen = await RefExpectationScope.firing(element) { RefExpectationScope.expected }
        XCTAssertEqual(seen, RefExpectation(identifier: "go", type: "button"))
        XCTAssertNil(RefExpectationScope.expected)
    }
}

/// ref を撃つたびに、その時点の期待を控える
private final class ExpectationRecordingDriver: AppDriver {
    private(set) var tapped: [RefExpectation?] = []
    private(set) var pressed: [RefExpectation?] = []
    private(set) var typed: [RefExpectation?] = []
    private(set) var cleared: [RefExpectation?] = []

    static let field = ElementInfo(ref: 7, type: "textField", identifier: "name", label: "Name", value: nil,
                                   placeholder: nil, enabled: true,
                                   frame: FTRect(x: 16, y: 200, width: 300, height: 44), depth: 1)
    static let button = ElementInfo(ref: 4, type: "button", identifier: "go", label: "Go", value: nil,
                                    placeholder: nil, enabled: true,
                                    frame: FTRect(x: 16, y: 300, width: 200, height: 44), depth: 1)

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
    func type(ref: Int?, text: String) async throws { typed.append(RefExpectationScope.expected) }
    func clearInput(ref: Int?) async throws { cleared.append(RefExpectationScope.expected) }
    func tap(ref: Int) async throws { tapped.append(RefExpectationScope.expected) }
    func tap(x: Double, y: Double) async throws {}
    func press(ref: Int, duration: Double) async throws { pressed.append(RefExpectationScope.expected) }
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                         elements: [Self.field, Self.button], truncatedCount: 0)
    }
}

final class RefExpectationScopeWiringTests: XCTestCase {

    private func execute(_ step: FlowStep, on driver: ExpectationRecordingDriver) async {
        _ = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables()).execute(step)
    }

    func testTapCarriesTheResolvedElement() async {
        let driver = ExpectationRecordingDriver()
        await execute(FlowStep(action: "tap", locator: FlowLocator(id: "go"), timeout: 1), on: driver)
        XCTAssertEqual(driver.tapped.first, RefExpectation(ExpectationRecordingDriver.button))
    }

    func testLongPressCarriesTheResolvedElement() async {
        let driver = ExpectationRecordingDriver()
        await execute(FlowStep(action: "tap", locator: FlowLocator(id: "go"), timeout: 1, duration: 1), on: driver)
        XCTAssertEqual(driver.pressed.first, RefExpectation(ExpectationRecordingDriver.button))
    }

    func testTypeCarriesTheResolvedElement() async {
        let driver = ExpectationRecordingDriver()
        await execute(FlowStep(action: "type", locator: FlowLocator(id: "name"), text: "abc", timeout: 1), on: driver)
        XCTAssertEqual(driver.typed.first, RefExpectation(ExpectationRecordingDriver.field))
    }

    func testClearCarriesTheResolvedElement() async {
        let driver = ExpectationRecordingDriver()
        await execute(FlowStep(action: "clearInput", locator: FlowLocator(id: "name"), timeout: 1), on: driver)
        XCTAssertEqual(driver.cleared.first, RefExpectation(ExpectationRecordingDriver.field))
    }
}
