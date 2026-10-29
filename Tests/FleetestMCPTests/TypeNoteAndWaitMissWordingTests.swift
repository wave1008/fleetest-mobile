// ft_type(ref なし)の読み返しの正規化と、waitFor が外れたときの案内の呼び手別の文言。
// ①typedIntoNote は expected にも値と同じゼロ幅文字の正規化をかける(replaceVerificationNote と同じ)
// ②waitMissHeadline は waitForChange を持たない呼び手(ft_batch)へ、無い引数を勧めない
// ③XCUITest ランナーの /type は文中に改行があれば読み返さず、その事実を注記で返す(Runner は swift test に入らないのでソース走査)

import XCTest
import FTCore
@testable import fleetest_mcp

final class TypeNoteAndWaitMissWordingTests: XCTestCase {

    private func focusedField(value: String) -> SnapshotResponse {
        var field = ElementInfo(ref: 1, type: "textField", identifier: "field_single", label: nil,
                                value: value, placeholder: nil, enabled: true,
                                frame: FTRect(x: 0, y: 0, width: 200, height: 40), depth: 1)
        field.focused = true
        return SnapshotResponse(sessionBundleID: "com.example.app",
                                screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                                elements: [field], truncatedCount: 0)
    }

    func testZeroWidthCharactersInTheTypedTextDoNotRaiseALandedWarning() async {
        // 欄は ZWSP を除いた形で読める(a11y の読み)・打った文字列は ZWSP を含む
        let note = await MCPServer.typedIntoNote(driver: FakeDriver(), expected: "a\u{200B}b",
                                                 snapshot: focusedField(value: "ab"))
        XCTAssertFalse(note.contains("warning"), note)
    }

    func testAMissingTextStillRaisesTheLandedWarning() async {
        let note = await MCPServer.typedIntoNote(driver: FakeDriver(), expected: "xyz",
                                                 snapshot: focusedField(value: "ab"))
        XCTAssertTrue(note.contains("may not have landed"), note)
    }

    /// 見えない文字だけの入力は、正規化すると空 = どんな値も「含む」。入ったとは言わず「確かめていない」と言う
    func testInvisibleOnlyTextIsNotClaimedAsLanded() async {
        let note = await MCPServer.typedIntoNote(driver: FakeDriver(), expected: "\u{200B}\u{200B}",
                                                 snapshot: focusedField(value: "other"))
        XCTAssertTrue(note.contains("whether it landed was not checked"), note)
    }

    func testQuietStopHeadlineDoesNotRecommendWaitForChangeToACallerThatLacksIt() {
        let batch = MCPServer.waitMissHeadline("#x", seconds: 12, quietStopAfter: 4.3, canWaitForChange: false)
        XCTAssertTrue(batch.contains("ft_snapshot waitForChange: true"), batch)
        XCTAssertFalse(batch.contains("wait with waitForChange"), batch)
        let other = MCPServer.waitMissHeadline("#x", seconds: 12, quietStopAfter: 4.3, canWaitForChange: true)
        XCTAssertTrue(other.contains("wait with waitForChange: true"), other)
    }

    /// 文中に改行がある文は一発で送り、**読み返していないことを注記で言う**(黙った成功にしない)。改行ごとに区切って読み返す形は
    /// 時間切れ・誤った赤を生むので戻さない(MN-107.2)
    func testRunnerTypeSaysAMidTextNewlineWasNotReadBack() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Runner/FleetestRunnerUITests/BridgeRouter+TextInput.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("return main.contains(\"\\n\") ? Self.multilineUnverifiedNote : nil"),
                      "文中の改行で読み返さなかった事実を返していない")
        XCTAssertFalse(source.contains("typeSegmentsWithReadback"), "改行ごとに区切る形が戻っている")
    }
}
