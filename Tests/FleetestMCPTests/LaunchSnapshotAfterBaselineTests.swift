import XCTest

/// ft_launch の snapshotAfter は**操作前の木と比べない**(`outsideTheAppTree: true`)。起動し直しは前と同じ最初の画面に着くのが
/// 普通で、resume は背面から戻した木と前面だった頃の木を比べることになり、どちらも「効かなかったかも」と誤って言っていた
final class LaunchSnapshotAfterBaselineTests: XCTestCase {
    func testLaunchReadsTheLandingScreenWithoutComparingToTheTreeBeforeIt() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/fleetest-mcp/MCPServer+SessionTools.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "func ftLaunch("))
        let end = try XCTUnwrap(source.range(of: "func ftOpenUrl(", range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("snapshotAfterBody(args, outsideTheAppTree: true)"), "ft_launch が操作前の木と比べている")
        XCTAssertFalse(body.contains("outsideTheAppTree: false"))
    }
}
