// ft_scroll_to は直前の ft_type のキーボードが上がりきってから探索すること(DSL の探索の
// consumePendingTypeKeyboardCheck と同じ型)。新しい StepExecutor は type の印を持たないので、MCP 側で消化しないと
// 上がる前の木で「見えている」と判断して送らず、後から上がったキーボードの下に対象が入る。
// 消化を落としてもコンパイルは通るのでソース走査で固定する。

import XCTest

final class ScrollToTypeKeyboardWaitTests: XCTestCase {

    private static func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // FleetestMCPTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // リポジトリルート
            .appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testScrollToConsumesThePendingTypeKeyboardCheckBeforeSearching() throws {
        let code = try Self.source("Sources/fleetest-mcp/MCPServer+Snapshot.swift")
        let search = try XCTUnwrap(code.range(of: "SlowCallWatchdog.mark(\"scroll search\")"),
                                   "ft_scroll_to の探索の始まりが見つからない(走査の前提が崩れた)")
        let before = String(code[code.startIndex..<search.lowerBound])
        let executor = try XCTUnwrap(before.range(of: "let executor = StepExecutor(driver: scrollDriver", options: .backwards),
                                     "ft_scroll_to の executor が見つからない")
        let setup = String(before[..<executor.lowerBound])
        let tail = try XCTUnwrap(setup.range(of: "resolveExecutorHints(scrollDriver", options: .backwards))
        XCTAssertTrue(String(setup[tail.upperBound...]).contains("consumePendingTypeKeyboardCheck("),
                      "ft_scroll_to が直前の ft_type のキーボードを待たずに探索している")
    }
}
