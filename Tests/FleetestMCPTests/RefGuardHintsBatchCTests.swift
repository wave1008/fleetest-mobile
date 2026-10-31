// RefGuard / MCPServer+Hints の文言の事実関係(探索 2026-10-30 の所見: アラート内の欄・名指しできない容器・
// 移動量の単位・SpringBoard のセッションの前面)。

import XCTest
import FTCore
@testable import fleetest_mcp

final class RefGuardHintsBatchCTests: XCTestCase {

    private func alertScreen() -> SnapshotResponse {
        SnapshotResponse(
            sessionBundleID: "com.example.app", screen: FTRect(x: 0, y: 0, width: 402, height: 874),
            elements: [
                ElementInfo(ref: 10, type: "alert", identifier: nil, label: "入力してください", value: nil,
                            placeholder: nil, enabled: true, frame: FTRect(x: 40, y: 300, width: 320, height: 240), depth: 1),
                ElementInfo(ref: 11, type: "button", identifier: nil, label: "保存", value: nil,
                            placeholder: nil, enabled: true, frame: FTRect(x: 60, y: 480, width: 120, height: 44), depth: 2),
            ], truncatedCount: 0)
    }

    /// 的がアラートの中の欄なら「アラートのボタンを押せ」と言わない(従うと欄ごと閉じる)
    func testGoneRefInsideTheAlertDoesNotTellToTapTheAlertButtons() {
        let field = ElementInfo(ref: 2211, type: "textField", identifier: nil, label: nil, value: nil,
                                placeholder: "入力", enabled: true,
                                frame: FTRect(x: 60, y: 380, width: 280, height: 40), depth: 2)
        let message = RefGuard.goneMessage(ref: 2211, target: field,
                                           inAppAlert: MCPServer.frontInAppAlertWithButtons(alertScreen()))
        XCTAssertTrue(message.contains("fresh ft_snapshot"), message)
        XCTAssertFalse(message.contains("Handle it first"), message)
    }

    func testGoneRefBehindTheAlertStillTellsToHandleTheAlert() {
        let behind = ElementInfo(ref: 5, type: "button", identifier: "go", label: nil, value: nil,
                                 placeholder: nil, enabled: true,
                                 frame: FTRect(x: 20, y: 100, width: 300, height: 44), depth: 1)
        let message = RefGuard.goneMessage(ref: 5, target: behind,
                                           inAppAlert: MCPServer.frontInAppAlertWithButtons(alertScreen()))
        XCTAssertTrue(message.contains("Handle it first"), message)
    }

    func testMovedNoteUsesTheGivenUnit() {
        let el = ElementInfo(ref: 1, type: "button", identifier: "b", label: nil, value: nil, placeholder: nil,
                             enabled: true, frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 1)
        XCTAssertTrue(RefGuard.movedNote(found: el, moved: 68, cause: "", unit: "pt").contains("68pt"))
        XCTAssertTrue(RefGuard.movedNote(found: el, moved: 68, cause: "").contains("68px"))
    }

    /// 申告された容器があるのに id もラベルも無い画面で「申告する要素が無い」と言わない(ref を渡せと言う)
    func testScrollAlternativesHintSaysWhenTheContainerHasNoName() {
        let snapshot = SnapshotResponse(
            sessionBundleID: "com.example.app", screen: FTRect(x: 0, y: 0, width: 402, height: 874),
            elements: [ElementInfo(ref: 1, type: "scrollView", identifier: nil, label: nil, value: nil,
                                   placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 0, width: 402, height: 874),
                                   depth: 1, scrollable: true)],
            truncatedCount: 0)
        let text = MCPServer.scrollAlternativesHint(snapshot)
        XCTAssertFalse(text.contains("No element on this screen declares"), text)
        XCTAssertTrue(text.contains("[1]"), text)
        let none = SnapshotResponse(sessionBundleID: "x", screen: snapshot.screen, elements: [], truncatedCount: 0)
        XCTAssertTrue(MCPServer.scrollAlternativesHint(none).contains("No element on this screen declares"))
    }

    /// SpringBoard のセッションは常に前面に見える(appstate)ので yes と言わない
    func testSpringBoardSessionIsNotReportedAsForeground() async {
        let verdict = ForegroundState.judge(ForegroundFacts(sessionBundleID: "com.apple.springboard"))
        let note = MCPServer.statusForegroundText(verdict, launched: nil, session: "com.apple.springboard")
        XCTAssertFalse(note.contains("foreground: yes"), note)
        XCTAssertTrue(note.contains("foreground: unknown"), note)
    }
}
