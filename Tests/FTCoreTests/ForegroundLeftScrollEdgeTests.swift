// 探索・端送りの終わりで「前面は対象のままか」を引く(覆い・シェード・ダイアログ・別アプリ)。
// scrollToBottom/Top が前面を離れた後に ok を返した(mxa F3)・シェードの下を「端」と言った(mxa F5)・
// ダイアログの前面に launch を勧めた(mxa F4)・iOS のスイッチャーの下で何も言わなかった(a F9)の固定。

import XCTest
@testable import FTCore

private final class ForegroundScriptedDriver: AppDriver {
    var front: String?
    var coveringMarker: String?
    var treeSession: String? = "com.example.app"
    var treeIDs: [String] = ["row_0"]
    private(set) var swipes = 0
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { swipes > 0 ? front : nil }
    func systemUICovering() async throws -> SystemUICoveringResponse? {
        coveringMarker.map { SystemUICoveringResponse(covering: true, marker: $0) }
    }
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
        let elements = treeIDs.enumerated().map { index, id in
            ElementInfo(ref: index + 1, type: "button", identifier: id, label: nil, value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 16, y: 40, width: 100, height: 56), depth: 0)
        }
        return SnapshotResponse(sessionBundleID: treeSession, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                elements: elements, truncatedCount: 0)
    }
}

final class ForegroundLeftScrollEdgeTests: XCTestCase {
    private func executor(_ driver: AppDriver) -> StepExecutor {
        StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())
    }

    func testScrollToEdgeFailsWhenAnotherAppIsInFrontAfterTheSwipes() async {
        let driver = ForegroundScriptedDriver()
        driver.front = "com.google.android.apps.nexuslauncher"
        let outcome = await executor(driver).execute(FlowStep(action: "scrollToEdge", direction: "up", maxSwipes: 6))
        guard case .failed(let message) = outcome.status else { return XCTFail("前面を離れたのに ok: \(outcome.status)") }
        XCTAssertTrue(message.contains("not in the foreground"), message)
        XCTAssertTrue(message.contains("nexuslauncher"), message)
    }

    func testScrollToEdgeStaysGreenWhenTheAppIsStillInFront() async {
        let driver = ForegroundScriptedDriver()
        driver.front = "com.example.app"
        let outcome = await executor(driver).execute(FlowStep(action: "scrollToEdge", direction: "up", maxSwipes: 6))
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "\(outcome.status)")
    }

    /// 送り始める前に前面を離れていた形(始点の木がランチャー。Android の木は前面と一緒に替わる)。起こしたアプリを基準に拾う
    func testScrollToEdgeFailsWhenTheAppAlreadyLeftBeforeTheSwipes() async {
        let driver = ForegroundScriptedDriver()
        driver.treeSession = "com.google.android.apps.nexuslauncher"
        driver.front = "com.google.android.apps.nexuslauncher"
        let exec = executor(driver)
        exec.noteAppLaunched(bundleID: "com.example.app")
        let outcome = await exec.execute(FlowStep(action: "scrollToEdge", direction: "up", maxSwipes: 6))
        guard case .failed(let message) = outcome.status else { return XCTFail("前面を離れていたのに ok: \(outcome.status)") }
        XCTAssertTrue(message.contains("not in the foreground"), message)
        XCTAssertTrue(message.contains("already com.google.android.apps.nexuslauncher, not com.example.app"), message)
    }

    /// 起こしたアプリの記録が無い(home / アプリ切替の後・起こしていない)ときは従来どおり(始点の木を基準にする)
    func testScrollToEdgeWithoutALaunchRecordKeepsTheTreeAsTheBaseline() async {
        let driver = ForegroundScriptedDriver()
        driver.treeSession = "com.google.android.apps.nexuslauncher"
        driver.front = "com.google.android.apps.nexuslauncher"
        let outcome = await executor(driver).execute(FlowStep(action: "scrollToEdge", direction: "up", maxSwipes: 6))
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "\(outcome.status)")
    }

    /// 起こしたアプリが始点の木と同じなら、何も足さない
    func testScrollToEdgeWithTheLaunchedAppInFrontStaysGreen() async {
        let driver = ForegroundScriptedDriver()
        driver.front = "com.example.app"
        let exec = executor(driver)
        exec.noteAppLaunched(bundleID: "com.example.app")
        let outcome = await exec.execute(FlowStep(action: "scrollToEdge", direction: "up", maxSwipes: 6))
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "\(outcome.status)")
    }

    func testShadeTreeIsNamedAsTheShadeNotAsAnEdge() async throws {
        let driver = ForegroundScriptedDriver()
        driver.front = "com.example.app"   // シェードの下では前面のアプリ名が下のアプリのまま
        driver.treeSession = "com.android.systemui"
        driver.treeIDs = ["notification_panel"]
        let tree = try await driver.snapshot()
        let front = await executor(driver).frontAppIfSessionAppLeft("com.example.app", tree: tree)
        XCTAssertEqual(front, "the notification shade or quick settings")
    }

    func testIOSSwitcherUnderTheAppIsNamedWithTheRunnersSuffixedMarker() async {
        let driver = ForegroundScriptedDriver()
        driver.coveringMarker = "SBSwitcherWindow:Main"
        let front = await executor(driver).frontAppIfSessionAppLeft("com.example.app")
        XCTAssertEqual(front, "the app switcher")
    }

    func testDialogInFrontIsNotAdvisedToRelaunch() {
        let dialog = "com.google.android.permissioncontroller"
        let advice = StepExecutor.bringBackAdvice(front: dialog)
        XCTAssertFalse(advice.hasPrefix("bring the app back with launch"), advice)
        XCTAssertTrue(advice.contains("dialog"), advice)
        XCTAssertTrue(StepExecutor.bringBackAdvice(front: "com.example.other").contains("launch"))
        XCTAssertTrue(StepExecutor.bringBackAdvice(front: "the notification shade or quick settings").contains("dismiss"))
    }
}
