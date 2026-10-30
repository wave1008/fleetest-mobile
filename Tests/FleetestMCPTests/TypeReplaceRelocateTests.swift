// ft_type(replace: true) は消去の後に欄を引き直してから打つ(消去でキーボードが引っ込むと欄が動き、撃つ前の ref は
// ブリッジに stale-ref で断られ、欄は消えたまま「何も送っていない」と言っていた)。

import XCTest
import FTCore
@testable import fleetest_mcp

final class TypeReplaceRelocateTests: XCTestCase {

    private func field(_ ref: Int, id: String?, y: Double, focused: Bool? = nil) -> ElementInfo {
        var e = ElementInfo(ref: ref, type: "textField", identifier: id, label: nil, value: nil,
                            placeholder: nil, enabled: true,
                            frame: FTRect(x: 0, y: y, width: 200, height: 40), depth: 1)
        e.focused = focused
        return e
    }

    func testRelocatesByIdentifierAfterTheFieldMoved() {
        let before = field(1298, id: "date", y: 310)
        let after = [field(1311, id: "date", y: 457), field(1312, id: "other", y: 100)]
        XCTAssertEqual(MCPServer.relocateAfterClear(before, in: after)?.ref, 1311)
    }

    func testRelocatesByFrameWhenThereIsNoIdentifier() {
        let before = field(5, id: nil, y: 310)
        XCTAssertEqual(MCPServer.relocateAfterClear(before, in: [field(9, id: nil, y: 310)])?.ref, 9)
    }

    func testFallsBackToTheSingleFocusedFieldOfTheSameType() {
        let before = field(5, id: nil, y: 310)
        let after = [field(9, id: nil, y: 450, focused: true), field(10, id: nil, y: 100)]
        XCTAssertEqual(MCPServer.relocateAfterClear(before, in: after)?.ref, 9)
    }

    func testRefusesWhenAmbiguousOrMissing() {
        let before = field(5, id: "a", y: 310)
        XCTAssertNil(MCPServer.relocateAfterClear(before, in: []))
        XCTAssertNil(MCPServer.relocateAfterClear(before, in: [field(1, id: "a", y: 1), field(2, id: "a", y: 2)]))
    }

    /// 本番の入口(server.call)で: 消去の後の木で欄の番号が変わったら、新しい番号へ打つ(撃つ前の番号のままだと
    /// ブリッジが stale-ref で断る = sim9 F9)
    func testReplaceTypesIntoTheFieldFoundAgainAfterClearing() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        let before = SnapshotResponse(sessionBundleID: "com.example.app", screen: screen,
                                      elements: [field(2, id: "name_field", y: 310)], truncatedCount: 0)
        let afterClear = SnapshotResponse(sessionBundleID: "com.example.app", screen: screen,
                                          elements: [field(7, id: "name_field", y: 457)], truncatedCount: 0)
        driver.snapshotResponse = before
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        driver.scriptedSnapshots = [before, afterClear]
        _ = try await server.call(tool: "ft_type", args: ["text": "abc", "ref": 2, "replace": true])
        XCTAssertTrue(driver.calls.contains("type(ref:7,text:abc)"), "\(driver.calls)")
    }

    /// id が無く枠も動いた欄(アラートの入力欄)は placeholder の一致で引き直す
    func testRelocatesByPlaceholderWhenTheFieldWithoutIdMoved() {
        var before = field(303, id: nil, y: 400)
        before.placeholder = "入力"
        var moved = field(311, id: nil, y: 250)
        moved.placeholder = "入力"
        XCTAssertEqual(MCPServer.relocateAfterClear(before, in: [moved, field(312, id: nil, y: 600)])?.ref, 311)
    }
}
