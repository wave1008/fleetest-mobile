// ActionCountingDriver(モニターの「アクション/分」の元)の検証。
// 守るもの: ①数える操作は正常に返ったときだけ増える(throw は数えない)②読み取り・設定は増えない
// ③全要件が中のドライバへ転送される(既定実装へ落ちない)④take() は差分を返して 0 に戻る
// ⑤AppDriver の全要件を包みが宣言している(要件を足して転送を書き忘れたら落ちる)。

import XCTest
@testable import FTCore

private final class RecordingDriver: AppDriver {
    struct Boom: Error {}
    var calls: [String] = []
    var failing = false

    private func record(_ name: String) throws {
        calls.append(name)
        if failing { throw Boom() }
    }

    func status() async throws -> StatusResponse {
        try record("status")
        return StatusResponse(ready: true, device: "-", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws -> String? { try record("install"); return nil }
    func uninstall(bundleID: String) async throws { try record("uninstall") }
    func launch(bundleID: String) async throws { try record("launch") }
    func activate(bundleID: String) async throws { try record("activate") }
    func attach(bundleID: String) async throws { try record("attach") }
    func openAppSwitcher() async throws { try record("openAppSwitcher") }
    func home() async throws { try record("home") }
    func back() async throws { try record("back") }
    func snapshot() async throws -> SnapshotResponse {
        try record("snapshot")
        return SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 0, height: 0),
                                elements: [], truncatedCount: 0)
    }
    func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse {
        try record("snapshot(bypassingCache)")
        return try await snapshot()
    }
    func hitTest(ref: Int) async throws -> HitTestAnswer { try record("hitTest"); return .hittable(true) }
    func tap(ref: Int) async throws { try record("tap(ref)") }
    func tap(x: Double, y: Double) async throws { try record("tap(xy)") }
    func type(ref: Int?, text: String) async throws { try record("type") }
    func clearInput(ref: Int?) async throws { try record("clearInput") }
    func hideKeyboard() async throws { try record("hideKeyboard") }
    func pressEnter() async throws { try record("pressEnter") }
    func swipe(_ direction: FTSwipeDirection) async throws { try record("swipe") }
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {
        try record("swipe(intent)")
    }
    func screenshot() async throws -> Data { try record("screenshot"); return Data() }
    func press(ref: Int, duration: Double) async throws { try record("press(ref)") }
    func terminate() async throws { try record("terminate") }
    func isAppForeground(bundleID: String) async throws -> Bool { try record("isAppForeground"); return true }
    func foregroundAppID() async throws -> String? { try record("foregroundAppID"); return nil }
    func restoreOrientationIfNeeded() async throws { try record("restoreOrientationIfNeeded") }
    func clearAppData(bundleID: String) async throws { try record("clearAppData") }
    func openURL(_ url: String, bundleID: String?) async throws { try record("openURL") }
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws { try record("drag") }
    func doubleTap(x: Double, y: Double) async throws { try record("doubleTap") }
    func pinch(frame: FTRect?, identifier: String?, scale: Double, durationSeconds: Double) async throws {
        try record("pinch")
    }
    func gesture(_ request: GestureRequest) async throws { try record("gesture") }
    func press(x: Double, y: Double, duration: Double) async throws { try record("press(xy)") }
    func hold(x: Double, y: Double, duration: Double) async throws { try record("hold") }
    func rotate(to orientation: FTOrientation) async throws -> FTOrientation {
        try record("rotate")
        return orientation
    }
    func setHingeAngle(degrees: Double) async throws { try record("setHingeAngle") }
    var pointScale: Double { 3 }
}

final class ActionCountingDriverTests: XCTestCase {

    private func make() -> (ActionCountingDriver, RecordingDriver, ActionCounter) {
        let base = RecordingDriver()
        let counter = ActionCounter()
        return (ActionCountingDriver(base: base, counter: counter), base, counter)
    }

    func testOperationsThatSendInputAreCounted() async throws {
        let (driver, base, counter) = make()
        try await driver.launch(bundleID: "a")
        try await driver.terminate()
        try await driver.openAppSwitcher()
        try await driver.home()
        try await driver.back()
        try await driver.tap(ref: 1)
        try await driver.tap(x: 1, y: 2)
        try await driver.type(ref: nil, text: "x")
        try await driver.clearInput(ref: nil)
        try await driver.hideKeyboard()
        try await driver.openURL("https://example.com", bundleID: nil)
        try await driver.pressEnter()
        try await driver.swipe(.up)
        try await driver.swipe(.up, intent: .search, path: nil)
        try await driver.drag(fromX: 0, fromY: 0, toX: 1, toY: 1, pressSeconds: 0, durationSeconds: 0.1)
        try await driver.doubleTap(x: 1, y: 2)
        try await driver.pinch(frame: nil, identifier: nil, scale: 2, durationSeconds: 0.1)
        try await driver.gesture(GestureRequest(fingers: []))
        try await driver.press(ref: 1, duration: 1)
        try await driver.press(x: 1, y: 2, duration: 1)
        try await driver.hold(x: 1, y: 2, duration: 1)
        _ = try await driver.rotate(to: .portrait)
        try await driver.setHingeAngle(degrees: 90)
        XCTAssertEqual(counter.take(), 23)
        XCTAssertEqual(base.calls.count, 23, "数えた操作は全部中のドライバへ転送されている")
    }

    func testReadsAndSettingsAreNotCounted() async throws {
        let (driver, base, counter) = make()
        _ = try await driver.status()
        _ = try await driver.snapshot()
        _ = try await driver.snapshot(bypassingCache: true)
        _ = try await driver.hitTest(ref: 1)
        _ = await driver.tapProbe(x: 0, y: 0)
        _ = try await driver.screenshot()
        _ = try await driver.isAppForeground(bundleID: "a")
        _ = try await driver.foregroundAppID()
        _ = try await driver.systemAlert()
        _ = try await driver.systemUICovering()
        try await driver.activate(bundleID: "a")
        try await driver.attach(bundleID: "a")
        try await driver.uninstall(bundleID: "a")
        _ = try await driver.install(packagePath: "/x")
        try await driver.clearAppData(bundleID: "a")
        try await driver.restoreOrientationIfNeeded()
        await driver.acknowledgeOpenURLConsentIfPresent(bundleID: "a")
        driver.captureKeyboardStateOnNextSnapshot()
        driver.raiseElementLimitOnNextSnapshot(10)
        XCTAssertEqual(counter.take(), 0)
        XCTAssertTrue(base.calls.contains("hitTest") && base.calls.contains("snapshot(bypassingCache)"),
                      "既定実装を持つ要件も中のドライバへ届く: \(base.calls)")
    }

    func testThrowingOperationsAreNotCounted() async {
        let (driver, base, counter) = make()
        base.failing = true
        await XCTAssertThrowsErrorAsync { try await driver.tap(ref: 1) }
        await XCTAssertThrowsErrorAsync { try await driver.swipe(.down) }
        await XCTAssertThrowsErrorAsync { try await driver.launch(bundleID: "a") }
        XCTAssertEqual(counter.take(), 0)
        XCTAssertEqual(base.calls, ["tap(ref)", "swipe", "launch"], "撃ってはいる(数えないだけ)")
    }

    func testSwipeWithIntentReachesTheInnerIntentOverload() async throws {
        let (driver, base, counter) = make()
        try await driver.swipe(.up, intent: .edge, path: nil)
        XCTAssertEqual(base.calls, ["swipe(intent)"], "既定実装(用途を落として swipe(_:))へ倒れていない")
        XCTAssertEqual(counter.take(), 1, "1回の呼び出しは1回だけ数える")
    }

    func testPropertiesAreForwarded() {
        let (driver, _, _) = make()
        XCTAssertEqual(driver.pointScale, 3)
    }

    func testTakeReturnsTheDeltaAndResets() {
        let counter = ActionCounter()
        XCTAssertEqual(counter.take(), 0)
        counter.increment()
        counter.increment()
        XCTAssertEqual(counter.take(), 2)
        XCTAssertEqual(counter.take(), 0)
        counter.increment()
        XCTAssertEqual(counter.take(), 1)
    }

    /// AppDriver の要件を足したのに包みへ転送を書き忘れると、既定実装へ静的ディスパッチされて中のドライバに届かない
    func testWrapperDeclaresEveryProtocolRequirement() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let protocolSource = try String(
            contentsOf: root.appendingPathComponent("Sources/FTCore/AppDriver.swift"), encoding: .utf8)
        let wrapperSource = try String(
            contentsOf: root.appendingPathComponent("Sources/FTCore/ActionCountingDriver.swift"), encoding: .utf8)
        let start = try XCTUnwrap(protocolSource.range(of: "public protocol AppDriver {"))
        let end = try XCTUnwrap(protocolSource.range(of: "\n}\n", range: start.upperBound..<protocolSource.endIndex))
        let body = String(protocolSource[start.upperBound..<end.lowerBound])
        let names = body.split(separator: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("//") else { return nil }
            for prefix in ["func ", "var "] where t.hasPrefix(prefix) {
                let rest = t.dropFirst(prefix.count)
                return String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
            }
            return nil
        }
        XCTAssertGreaterThan(names.count, 40, "走査が壊れている")
        let missing = names.filter { name in
            !wrapperSource.contains("func \(name)(") && !wrapperSource.contains("var \(name):")
        }
        XCTAssertTrue(missing.isEmpty, "ActionCountingDriver が転送していない要件: \(missing)")
    }
}

private func XCTAssertThrowsErrorAsync(_ body: () async throws -> Void,
                                       file: StaticString = #filePath, line: UInt = #line) async {
    do {
        try await body()
        XCTFail("expected a throw", file: file, line: line)
    } catch {}
}
