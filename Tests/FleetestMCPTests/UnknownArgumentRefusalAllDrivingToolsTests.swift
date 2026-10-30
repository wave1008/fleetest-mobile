// 未知の引数を撃たずに断る範囲 = 端末を動かす・消すツール全部(toolEffects が drivesDevice / destructive)。
// 探索で ft_clear_input(selector)・ft_swipe(scrollframe)・ft_tap(holdSeconds)等が「ignored」と言って別の的へ撃っていた

import XCTest
import FTCore
@testable import fleetest_mcp

final class UnknownArgumentRefusalAllDrivingToolsTests: XCTestCase {

    private static let drivingTools: [String] = MCPServer.toolEffects
        .filter { $0.value == .drivesDevice || $0.value == .destructive }.map(\.key).sorted()

    func testEveryDrivingToolRefusesAnUnknownArgument() {
        XCTAssertTrue(Self.drivingTools.contains("ft_clear_input") && Self.drivingTools.contains("ft_swipe")
                      && Self.drivingTools.contains("ft_pinch") && Self.drivingTools.contains("ft_tap"))
        for tool in Self.drivingTools {
            let refusal = MCPServer.unknownArgumentRefusal(tool: tool, args: ["selector": "#x", "thisDoesNotExist": 1])
            XCTAssertNotNil(refusal, "\(tool) must refuse an unknown argument")
            XCTAssertTrue(refusal?.contains("nothing was sent") == true, "\(tool): \(refusal ?? "")")
        }
    }

    /// 正当な引数(各ツールのスキーマが宣言した欄)は断らない
    func testEveryDeclaredArgumentOfEveryDrivingToolIsAccepted() {
        for tool in Self.drivingTools {
            guard let definition = MCPServer.toolDefinitions.first(where: { $0["name"] as? String == tool }),
                  let properties = (definition["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
            else { XCTFail("no schema for \(tool)"); continue }
            let args = Dictionary(uniqueKeysWithValues: properties.keys.map { ($0, 1 as Any) })
            XCTAssertNil(MCPServer.unknownArgumentRefusal(tool: tool, args: args), "\(tool) refused a declared argument")
        }
    }

    func testTypoOfScrollFrameIsRefusedWithTheSuggestion() {
        for tool in ["ft_swipe", "ft_scroll_to"] {
            let refusal = MCPServer.unknownArgumentRefusal(tool: tool, args: ["scrollframe": "#list"])
            XCTAssertTrue(refusal?.contains("did you mean \"scrollFrame\"?") == true, "\(tool): \(refusal ?? "nil")")
        }
        XCTAssertNotNil(MCPServer.unknownArgumentRefusal(tool: "ft_tap", args: ["x": 1, "y": 1, "holdSeconds": 1.5]))
    }

    /// 木の読み方だけの欄は従来どおり注記で通す(DeclaredArgumentTypeCheckTests の ft_tap + maxElements)
    func testViewOnlyArgumentsAreStillOnlyNoted() {
        XCTAssertNil(MCPServer.unknownArgumentRefusal(tool: "ft_tap", args: ["x": 1, "y": 1, "maxElements": "250"]))
    }

    func testReadOnlyToolsOnlyNote() {
        XCTAssertNil(MCPServer.unknownArgumentRefusal(tool: "ft_snapshot", args: ["thisDoesNotExist": 1]))
    }

    func testWithScrollBlockAdviceIsRewrittenForBatch() {
        let reason = "nothing moved at all. A scroll area is declared (scrollFrame: \"#pager_main\")"
            + " — consider wrapping the step in withScrollRight(scrollFrame: \"#pager_main\") { } to search inside it."
        let advice = MCPServer.batchWritableAdvice(reason)
        XCTAssertFalse(advice.contains("withScrollRight"), advice)
        XCTAssertTrue(advice.contains("scrollTo '<target>' scrollFrame: \"#pager_main\""), advice)
        XCTAssertEqual(MCPServer.batchWritableAdvice("plain failure"), "plain failure")
    }

    func testBatchVerdictNamesAnEarlierStepPossibility() {
        let verdict = MCPServer.batchVerdict(stepCount: 3, suspects: [], appLeftFront: true)
        XCTAssertTrue(verdict.contains("EARLIER step"), verdict)
    }
}
