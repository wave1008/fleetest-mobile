// type の直後の読みが「キーボードが上がる前の木」を返さないための配線をソース走査で固定する。
// 実害: ft_type → ft_snapshot → ft_batch の type で、上がる前の欄の位置を撃ち、上がってきたキーボードの上の別のボタンを押した(SwiftUI)。
// 読みは ft_snapshot / snapshotAfter が出現待ちを払い、ft_batch は新しい executor へ印を引き継ぐ。

import XCTest

final class MCPTypeKeyboardCarryWiringTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func code(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relativePath), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testSnapshotReadersPayThePendingKeyboardWait() throws {
        XCTAssertTrue(try code("Sources/fleetest-mcp/MCPServer+ScreenTools.swift")
            .contains("consumePendingTypeKeyboardCheck(snapshot, driver: snapshotDriver"), "ft_snapshot")
        XCTAssertTrue(try code("Sources/fleetest-mcp/MCPServer+Snapshot.swift")
            .contains("snapshot = try await consumePendingTypeKeyboardCheck(snapshot, driver: snapshotDriver"), "snapshotAfter")
    }

    func testBatchCarriesThePendingMarkIntoItsExecutor() throws {
        let batch = try code("Sources/fleetest-mcp/MCPServer+Batch.swift")
        XCTAssertTrue(batch.contains("executor.carryPendingTypeKeyboardCheck("))
        XCTAssertTrue(batch.contains("keyboardKnownAbsent"))
    }
}
