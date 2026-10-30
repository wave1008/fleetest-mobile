import XCTest
import FTCore
@testable import fleetest_mcp

/// Android ブリッジの帰属・失敗文言の修正(ロック画面/AOD を system dialog と言わない)と、
/// Java ソースに載せた修正(入力の IME 検査・受理後の「届いたか不明」・起動失敗の理由・止めた前面)の走査
final class AndroidAttributionFixesTests: XCTestCase {

    private func snapshot(session: String, ids: [String]) -> SnapshotResponse {
        let elements = ids.enumerated().map { index, id in
            ElementInfo(ref: index + 1, type: "staticText", identifier: id, label: "x", value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: Double(index * 40), width: 100, height: 40), depth: 1)
        }
        return SnapshotResponse(sessionBundleID: session,
                                screen: FTRect(x: 0, y: 0, width: 1080, height: 2340),
                                elements: elements, truncatedCount: 0)
    }

    func testAlwaysOnDisplayTreeIsNotCalledASystemDialog() {
        let snap = snapshot(session: "com.android.systemui",
                            ids: ["animatable_clock_view", "keyguard_indication_text"])
        let note = MCPServer.switchedAppNote(launched: "com.ftester.e2e", snapshot: snap)
        XCTAssertTrue(note.contains("lock screen / always-on display"), note)
        XCTAssertFalse(note.contains("system dialog"), note)
    }

    func testPermissionStyleSystemuiTreeStaysASystemDialog() {
        let snap = snapshot(session: "com.android.systemui", ids: ["some_panel"])
        let note = MCPServer.switchedAppNote(launched: "com.ftester.e2e", snapshot: snap)
        XCTAssertTrue(note.contains("system dialog"), note)
        let perm = snapshot(session: "com.google.android.permissioncontroller",
                            ids: ["keyguard_like_id"])
        XCTAssertTrue(MCPServer.switchedAppNote(launched: "com.ftester.e2e", snapshot: perm)
            .contains("system dialog"))
    }

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testInputInjectorSourceCarriesTheFixes() throws {
        let java = try source("AndroidRunner/src/com/example/ftbridge/InputInjector.java")
        XCTAssertTrue(java.contains("target.isFocused() && imeWindowVisible(ua)"),
                      "an a11y-focused field with no IME in front must be tapped again (Flutter after an IME action)")
        XCTAssertEqual(java.components(separatedBy: "+ deliveryUnknownNote(accepted)").count - 1, 2,
                       "both give-up paths must say delivery is unknown after an accepted SET_TEXT")
        XCTAssertFalse(java.contains("accepted but the value did not change"))
    }

    func testBridgeRouterSourceCarriesTheFixes() throws {
        let java = try source("AndroidRunner/src/com/example/ftbridge/BridgeRouter.java")
        XCTAssertTrue(java.contains("launchFailureReason(bundleID)"))
        XCTAssertTrue(java.contains("installed but disabled"))
        XCTAssertTrue(java.contains("stoppedForeground"))
        // ref なしの入力・消去も、焦点が残ったまま IME が閉じた欄を張り直してから撃つ(emu9 F1 の ft_type ref なし)
        XCTAssertEqual(java.components(separatedBy: "InputInjector.tapFocusedEditableIfImeHidden(ua(), instrumentation.getContext());").count - 1, 2)
    }
}
