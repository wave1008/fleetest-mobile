// 覆い(通知センター・スイッチャー等)の注記の出し分け。SpringBoard セッションの読みに偽の警告を出さない・
// appSwitcher が開かなかったら「opened」と言わない・ランナーの 422 を覆いの事実で言い直す。

import XCTest
import FTCore
@testable import fleetest_mcp

final class CoveringSurfaceHintsTests: XCTestCase {
    func testSpringBoardSessionTreeIsNotCalledTheAppsOwnTree() {
        XCTAssertFalse(MCPServer.shouldProbeCovering(sessionBundleID: "com.apple.springboard"))
        XCTAssertTrue(MCPServer.shouldProbeCovering(sessionBundleID: "com.example.app"))
        XCTAssertTrue(MCPServer.shouldProbeCovering(sessionBundleID: nil))
    }

    func testAppSwitcherNoteDoesNotClaimOpenedWhenItWasNotSeen() {
        let seen = MCPServer.backgroundingNavigationNote(target: "appSwitcher", bridge: "xcuitest", switcherSeen: true)
        XCTAssertTrue(seen.contains("The App Switcher opened"), seen)
        let notSeen = MCPServer.backgroundingNavigationNote(target: "appSwitcher", bridge: "xcuitest", switcherSeen: false)
        XCTAssertFalse(notSeen.contains("opened"), notSeen)
        XCTAssertTrue(notSeen.contains("not seen open"), notSeen)
        XCTAssertTrue(MCPServer.backgroundingNavigationNote(target: "appSwitcher", bridge: "xcuitest")
            .contains("The App Switcher opened"))
    }

    func testRefusalNoteNamesTheSurfaceAndDoesNotSendTheReaderToAlertButtons() {
        let note = MCPServer.coveredRefusalNote(CoveringSurface.from(marker: "SBCoverSheetWindow"))
        XCTAssertTrue(note.contains("notification centre"), note)
        XCTAssertTrue(note.contains("not an alert to answer by pressing its buttons"), note)
        XCTAssertTrue(MCPServer.coveredRefusalNote(.appSwitcher).contains("the app switcher"))
    }

    func testSuffixedSwitcherMarkerIsNamedAsTheSwitcher() {
        XCTAssertEqual(MCPServer.coveringSurfaceName(CoveringSurface.from(marker: "SBSwitcherWindow:Main")), "the app switcher")
    }
}
