// 応答の途中で接続が切れた手(DriverError.bridgeUnreachable)は「届いたか分からない」と言う。
// 撃つ前に断られた手(bridgeConnectionRefused)と、読むだけのツールには付けない。

import XCTest
import FTCore
@testable import fleetest_mcp

final class DeliveryUnknownNoteTests: XCTestCase {

    func testActionToolsGetTheNoteAndReadOnlyToolsDoNot() {
        XCTAssertTrue(MCPServer.deliveryUnknownNote(mayHaveTakenEffect: MCPServer.mayHaveTakenEffect(tool: "ft_tap"))
            .contains("unknown whether this action was performed"))
        XCTAssertEqual(MCPServer.deliveryUnknownNote(mayHaveTakenEffect: MCPServer.mayHaveTakenEffect(tool: "ft_snapshot")), "")
    }

    func testBatchNoteOnlyForDriverUnreachableFailures() {
        XCTAssertTrue(MCPServer.batchDeliveryUnknownNote(failureKind: .driverUnreachable)
            .contains("may already have been performed"))
        for kind in StepFailureKind.allCases where kind != .driverUnreachable {
            XCTAssertEqual(MCPServer.batchDeliveryUnknownNote(failureKind: kind), "", "\(kind)")
        }
        XCTAssertEqual(MCPServer.batchDeliveryUnknownNote(failureKind: nil), "")
    }

    /// ソース走査: replace の消去の後の読みは try? で nil に畳まない(接続断が「欄が見つからない」に化けた)
    func testReadAfterClearDoesNotSwallowFailures() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/fleetest-mcp/MCPServer+ScreenTools.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "func readAfterClear()"))
        let end = try XCTUnwrap(source.range(of: "relocatedNativeRef = refound.ref"))
        let region = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(region.contains("try? await typeDriver.snapshot"))
    }
}
