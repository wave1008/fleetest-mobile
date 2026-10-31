import XCTest
@testable import FTCore

/// 前面の判定(`ForegroundState.judge`)を、状態ごとに表で固定する。MCP の ft_status / snapshot の注記 /
/// batch の中断 / DSL の探索の打ち切りが同じ答えを引く(文言は呼び手ごと)
final class ForegroundStateTests: XCTestCase {

    private let app = "com.example.app"
    private let systemUI = "com.android.systemui"

    private struct Row {
        let name: String
        let facts: ForegroundFacts
        let expected: ForegroundVerdict
    }

    private func rows() -> [Row] {
        [
            Row(name: "iOS: app in front (appstate true)",
                facts: ForegroundFacts(launched: app, sessionBundleID: app, sessionInForeground: .value(true)),
                expected: .inFront),
            Row(name: "iOS: app died / left (appstate false, no name)",
                facts: ForegroundFacts(launched: app, sessionBundleID: app, sessionInForeground: .value(false)),
                expected: .otherApp(name: nil)),
            Row(name: "iOS: notification centre drawn over the app (appstate still true)",
                facts: ForegroundFacts(launched: app, sessionBundleID: app, sessionInForeground: .value(true),
                                       covering: .value(.coverSheet)),
                expected: .covered(.coverSheet)),
            Row(name: "iOS: Control Center",
                facts: ForegroundFacts(launched: app, sessionBundleID: app, sessionInForeground: .value(false),
                                       covering: .value(CoveringSurface.from(marker: "cc-brightness-slider"))),
                expected: .covered(.controlCenter)),
            Row(name: "iOS: app switcher",
                facts: ForegroundFacts(launched: app, sessionBundleID: app, sessionInForeground: .value(true),
                                       covering: .value(CoveringSurface.from(marker: "SBSwitcherWindow"))),
                expected: .covered(.appSwitcher)),
            Row(name: "iOS: covering asked and nothing covers",
                facts: ForegroundFacts(launched: app, sessionBundleID: app, sessionInForeground: .value(true),
                                       covering: .value(nil)),
                expected: .inFront),
            Row(name: "Android: front is the app",
                facts: ForegroundFacts(launched: app, sessionBundleID: app, front: .value(app)),
                expected: .inFront),
            Row(name: "Android: shade holds input focus while the front is still the app",
                facts: ForegroundFacts(launched: app, sessionBundleID: app, front: .value(app),
                                       shadeHoldsInputFocus: .value(true)),
                expected: .covered(.shade)),
            Row(name: "Android: session moved to the shade tree",
                facts: ForegroundFacts(launched: app, sessionBundleID: systemUI, tree: .notificationShade),
                expected: .covered(.shade)),
            Row(name: "Android: session moved to the lock screen tree",
                facts: ForegroundFacts(launched: app, sessionBundleID: systemUI, tree: .lockScreen),
                expected: .locked),
            Row(name: "Android: permission dialog as the session",
                facts: ForegroundFacts(launched: app, sessionBundleID: "com.google.android.permissioncontroller"),
                expected: .dialog(package: "com.google.android.permissioncontroller")),
            Row(name: "Android: another app in front",
                facts: ForegroundFacts(launched: app, sessionBundleID: app, front: .value("com.example.other")),
                expected: .otherApp(name: "com.example.other")),
            Row(name: "Android: session re-pointed to another app",
                facts: ForegroundFacts(launched: app, sessionBundleID: "com.example.other"),
                expected: .otherApp(name: "com.example.other")),
            Row(name: "Android: launched app has no process",
                facts: ForegroundFacts(launched: app, sessionBundleID: "com.example.launcher", processRunning: .value(false)),
                expected: .processGone),
            Row(name: "the tool stopped the app itself (wins over processGone)",
                facts: ForegroundFacts(launched: app, sessionBundleID: "com.example.launcher",
                                       processRunning: .value(false), stoppedByTool: "ft_clear_app_data"),
                expected: .toolStopped(by: "ft_clear_app_data")),
            Row(name: "session is SpringBoard",
                facts: ForegroundFacts(launched: app, sessionBundleID: ForegroundState.springboard),
                expected: .home),
            Row(name: "nothing asked",
                facts: ForegroundFacts(launched: app, sessionBundleID: app),
                expected: .unknown(.notAnswerable)),
            Row(name: "every probe failed",
                facts: ForegroundFacts(launched: app, sessionBundleID: app, front: .failed, sessionInForeground: .failed),
                expected: .unknown(.failed)),
            Row(name: "no session and no launch",
                facts: ForegroundFacts(),
                expected: .unknown(.notAnswerable)),
        ]
    }

    func testVerdictTable() {
        for row in rows() {
            XCTAssertEqual(ForegroundState.judge(row.facts), row.expected, row.name)
        }
    }

    /// 答えない(前面アプリ名が無い)ことを「別のアプリ」に畳まない
    func testUnansweredFrontIsNotAnotherApp() {
        let verdict = ForegroundState.judge(ForegroundFacts(launched: app, sessionBundleID: app, front: .notAnswerable))
        XCTAssertEqual(verdict, .unknown(.notAnswerable))
    }

    func testTreeKindOrderPutsTheLockScreenFirst() {
        let bouncer: [String?] = ["quick_settings_container", "keyguard_pin_view"]
        XCTAssertEqual(SystemUITreeKind.classify(sessionBundleID: systemUI, identifiers: bouncer), .lockScreen)
        XCTAssertEqual(SystemUITreeKind.classify(sessionBundleID: systemUI, identifiers: ["notification_panel"]),
                       .notificationShade)
        XCTAssertEqual(SystemUITreeKind.classify(sessionBundleID: systemUI, identifiers: []), .systemUIOther)
        XCTAssertEqual(SystemUITreeKind.classify(sessionBundleID: app, identifiers: ["keyguard_pin_view"]), .app)
    }

    /// ランナーが返す目印は接尾辞付き(実物の名前)。完全一致だと「a system surface (SBSwitcherWindow:Main)」になっていた
    func testRunnerMarkersWithSuffixesMapToTheirSurface() {
        XCTAssertEqual(CoveringSurface.from(marker: "SBSwitcherWindow:Main"), .appSwitcher)
        XCTAssertEqual(CoveringSurface.from(marker: "SBSwitcherWindow"), .appSwitcher)
        XCTAssertEqual(CoveringSurface.from(marker: "SBCoverSheetWindow"), .coverSheet)
        XCTAssertEqual(CoveringSurface.from(marker: "SBCoverSheetWindow:Main"), .coverSheet)
        XCTAssertEqual(CoveringSurface.from(marker: "cc-brightness-slider"), .controlCenter)
        XCTAssertEqual(CoveringSurface.from(marker: "SBOther"), .other("SBOther"))
        XCTAssertEqual(CoveringSurface.from(marker: nil), .other("unknown"))
        XCTAssertEqual(CoveringSurface.appSwitcher.displayName, "the app switcher")
        XCTAssertEqual(CoveringSurface.from(marker: "SBSwitcherWindow:Main").displayName, "the app switcher")
    }
}
