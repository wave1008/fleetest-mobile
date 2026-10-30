// ref なしの入力で「焦点のある要素が木に無い」ときの文言と、replace の末尾改行の扱いの固定。

import XCTest
import FTCore
@testable import fleetest_mcp

final class NoFocusNoteTests: XCTestCase {

    private func tree(keyboard: Bool, elements: [ElementInfo]) -> SnapshotResponse {
        var s = SnapshotResponse(sessionBundleID: "x", screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                                 elements: elements, truncatedCount: 0)
        s.keyboardShown = keyboard
        return s
    }

    private func button() -> ElementInfo {
        ElementInfo(ref: 1, type: "button", identifier: "b", label: "B", value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 1)
    }

    /// キーボードが出ている・木が空のときは「どこにも行っていないかも」と言わない
    func testNoGoneNowhereWarningWhileKeyboardUpOrTreeEmpty() {
        for s in [tree(keyboard: true, elements: [button()]), tree(keyboard: false, elements: [])] {
            let note = MCPServer.noFocusNote(s)
            XCTAssertFalse(note.contains("gone nowhere"), note)
            XCTAssertTrue(note.contains("could not be confirmed"), note)
        }
    }

    /// キーボードも出ていない木では従来の警告のまま
    func testWarnsWhenKeyboardIsNotShown() {
        XCTAssertTrue(MCPServer.noFocusNote(tree(keyboard: false, elements: [button()])).contains("gone nowhere"))
    }

    /// replace の末尾の改行(IME アクション)は期待値から除いて比べる
    func testReplaceWithTrailingNewlineDoesNotWarn() {
        var field = ElementInfo(ref: 2, type: "textField", identifier: "f", label: nil, value: "ab", placeholder: nil,
                                enabled: true, frame: FTRect(x: 0, y: 0, width: 100, height: 40), depth: 1)
        field.focused = true
        let note = MCPServer.replaceVerificationNote(target: nil, expected: "ab\n",
                                                     fresh: tree(keyboard: false, elements: [field]))
        XCTAssertEqual(note, " (replaced the field's prior content)", note)
    }
}
