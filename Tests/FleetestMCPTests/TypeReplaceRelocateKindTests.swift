// replace の「消した後に見つけ直す」: 入力欄どうしの型の変化(Flutter の textField → secureTextField)・
// 末尾の改行(IME アクション)を不一致と誤警告しない。

import XCTest
import FTCore
@testable import fleetest_mcp

final class TypeReplaceRelocateKindTests: XCTestCase {

    private func field(_ ref: Int, type: String, id: String?, value: String? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: value,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 16, y: 312, width: 343, height: 48), depth: 1)
    }

    func testRelocatesAcrossTextFieldAndSecureTextFieldWithTheSameId() {
        let before = field(513, type: "textField", id: "field_password")
        let after = [field(530, type: "secureTextField", id: "field_password")]
        XCTAssertEqual(MCPServer.relocateAfterClear(before, in: after)?.ref, 530)
        XCTAssertEqual(ClearedFieldRelocation.byIdentifier(before, id: "field_password", in: after)?.ref, 530)
    }

    func testSameTypeIsPreferredAndNonInputsAreNotAdopted() {
        let before = field(1, type: "textField", id: "a")
        let both = [field(2, type: "secureTextField", id: "a"), field(3, type: "textField", id: "a")]
        XCTAssertEqual(MCPServer.relocateAfterClear(before, in: both)?.ref, 3)
        let notInput = [field(4, type: "staticText", id: "a")]
        XCTAssertNil(MCPServer.relocateAfterClear(before, in: notInput))
    }

    func testTrailingNewlineDoesNotWarnAsMismatch() async throws {
        let driver = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        func snap(_ value: String?) -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: "com.example.app", screen: screen,
                             elements: [field(2, type: "textField", id: "f", value: value)], truncatedCount: 0)
        }
        driver.snapshotResponse = snap(nil)
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        driver.scriptedSnapshots = [snap(nil), snap(nil), snap("ab"), snap("ab")]
        let out = try await server.call(tool: "ft_type", args: ["text": "ab\n", "ref": 2, "replace": true])
        let joined = out.compactMap { $0["text"] as? String }.joined()
        XCTAssertFalse(joined.contains("does not match"), joined)
    }
}
