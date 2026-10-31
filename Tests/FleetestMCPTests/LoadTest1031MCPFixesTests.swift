// 負荷テスト 2026-10-31 の MCP 側の直し: 解除画面の木の判定・ft_batch の swipePointToPoint の画面外・
// 起動し直しを見送った理由・ft_swipe の慣性の比較領域。

import XCTest
import FTCore
@testable import fleetest_mcp

final class LoadTest1031MCPFixesTests: XCTestCase {
    private let screen = FTRect(x: 0, y: 0, width: 1080, height: 2340)

    private func tree(_ ids: [String], bundle: String = "com.android.systemui") -> SnapshotResponse {
        let elements = ids.enumerated().map { index, id in
            ElementInfo(ref: index + 1, type: "other", identifier: id, label: nil, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: Double(index * 40), width: 100, height: 40), depth: 1)
        }
        return SnapshotResponse(sessionBundleID: bundle, screen: screen, elements: elements, truncatedCount: 0)
    }

    /// 実機のロック画面の木は quick_settings_container を常に持つ。解除画面の本体があればロック画面と言う
    func testBouncerTreeWithQuickSettingsElementsIsTheLockScreen() {
        let locked = tree(["quick_settings_container", "expanded_qs_scroll_view", "keyguard_pin_view", "key1"])
        XCTAssertTrue(MCPServer.isLockScreenOrAlwaysOnTree(locked))
        let note = MCPServer.switchedAppNote(launched: "com.ftester.e2e", snapshot: locked)
        XCTAssertTrue(note.contains("lock screen"), note)
        XCTAssertFalse(note.contains("closes the shade"), note)
        // 解除画面の本体が無い、クイック設定付きの木(横向きのシェード)は従来どおりロック画面ではない
        XCTAssertFalse(MCPServer.isLockScreenOrAlwaysOnTree(
            tree(["quick_settings_container", "keyguard_message_area_container"])))
    }

    /// 解除画面の本体が無いロック画面はシェードと木で分けられない。back が効かない場合の出口を言う
    func testShadeNoteNamesTheWayOutOfALockScreenItCannotTellApart() {
        let note = MCPServer.switchedAppNote(launched: "com.ftester.e2e", snapshot: tree(["quick_settings_container"]))
        XCTAssertTrue(note.contains("closes the shade"), note)
        XCTAssertTrue(note.contains("unlock the device"), note)
    }

    private func coastingServer(_ driver: FakeDriver) -> MCPServer {
        driver.statusResponse = StatusResponse(ready: true, device: "iPhone", osVersion: "26", sessionBundleID: "com.example.cmp")
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        server.uiFrameworkHints[MCPServer.sessionKey([:])] = UIFrameworkHint(bundleID: "com.example.cmp", framework: .compose)
        server.settleWaitSeconds = 0
        return server
    }

    /// 慣性待ちの読みは呼び手へ渡さない木: 操作前の木(waitForChange の比較元)と世代を動かさない
    func testCoastingReadsDoNotReplaceTheTreeOfTheCaller() async throws {
        let driver = FakeDriver()
        driver.scriptedSnapshots = [tree(["before"]), tree(["after"]), tree(["after"])]
        let server = coastingServer(driver)
        let held = try await server.freshSnapshot(driver, args: [:])
        let note = await server.selfRenderedCoastingNote(driver, args: [:], step: FlowStep(action: "swipe"))
        XCTAssertEqual(note, "", "2回続けて同じなので黙る")
        XCTAssertEqual(server.lastSnapshots[MCPServer.sessionKey([:])]?.elements.map(\.identifier),
                       held.elements.map(\.identifier), "操作前の木が払った後の木にすり替わった")
    }

    /// 読めなかった回に「読み続けて変わり続けた」と言わない
    func testCoastingNoteDoesNotClaimReadsThatFailed() async throws {
        let driver = FakeDriver()
        driver.failing = ["snapshot"]
        let note = await coastingServer(driver).selfRenderedCoastingNote(driver, args: [:], step: FlowStep(action: "swipe"))
        XCTAssertTrue(note.contains("is unknown"), note)
        XCTAssertFalse(note.contains("kept changing"), note)
    }

    func testBatchSwipePointToPointRefusesAnOffscreenStartOrEnd() {
        let area = FTRect(x: 0, y: 0, width: 400, height: 800)
        func step(_ x: Double, _ y: Double, _ toX: Double, _ toY: Double) -> FlowStep {
            var s = FlowStep(action: "swipePointToPoint")
            s.x = x; s.y = y; s.toX = toX; s.toY = toY
            return s
        }
        XCTAssertNil(MCPServer.offscreenBatchCoordinateError(step(100, 300, 200, 400), screen: area, bridge: nil))
        XCTAssertNotNil(MCPServer.offscreenBatchCoordinateError(step(5000, 5000, 100, 100), screen: area, bridge: nil), "始点が外")
        XCTAssertNotNil(MCPServer.offscreenBatchCoordinateError(step(100, 300, 5000, 5000), screen: area, bridge: nil), "終点が外")
        XCTAssertTrue(MCPServer.hasCoordinateTarget(step(1, 1, 2, 2)))
        var scroll = FlowStep(action: "scrollDown")
        scroll.x = 9999
        XCTAssertFalse(MCPServer.hasCoordinateTarget(scroll))
        XCTAssertNil(MCPServer.offscreenBatchCoordinateError(scroll, screen: area, bridge: nil))
    }

    func testHeldByAnotherSessionIsNamedInTheNoBridgeNoteOnlyRightAfter() {
        let key = "held-test-\(UUID().uuidString)"
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertEqual(BridgeRecoveryFailureLedger.note(key: key, now: t0), "")
        BridgeRecoveryFailureLedger.recordHeld(key: key, now: t0)
        let within = BridgeRecoveryFailureLedger.note(key: key, now: t0.addingTimeInterval(5))
        XCTAssertTrue(within.contains("another session"), within)
        XCTAssertEqual(BridgeRecoveryFailureLedger.note(
            key: key, now: t0.addingTimeInterval(BridgeRecoveryFailureLedger.retryCooldownSeconds + 1)), "")
        // 失敗ではないので再挑戦は止めない
        XCTAssertFalse(BridgeRecoveryFailureLedger.blocksRetry(remembered: false, key: key, now: t0))
    }
}
