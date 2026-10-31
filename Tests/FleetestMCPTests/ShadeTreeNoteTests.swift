import XCTest
import FTCore
@testable import fleetest_mcp

/// 通知シェードの木は「権限ダイアログ」ではない(アプリは下で生きている・back で戻る)
final class ShadeTreeNoteTests: XCTestCase {
    private func snapshot(ids: [String]) -> SnapshotResponse {
        let elements = ids.enumerated().map { index, id in
            ElementInfo(ref: index + 1, type: "staticText", identifier: id, label: "x", value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: Double(index * 40), width: 100, height: 40), depth: 1)
        }
        return SnapshotResponse(sessionBundleID: "com.android.systemui",
                                screen: FTRect(x: 0, y: 0, width: 1080, height: 2340),
                                elements: elements, truncatedCount: 0)
    }

    func testShadeTreeSaysBackClosesItAndDoesNotCallItADialog() {
        let note = MCPServer.switchedAppNote(launched: "com.ftester.e2e",
                                             snapshot: snapshot(ids: ["notification_stack_scroller", "qs_panel"]))
        XCTAssertTrue(note.contains("ft_navigate back closes the shade"), note)
        XCTAssertFalse(note.contains("system dialog"), note)
    }
}
