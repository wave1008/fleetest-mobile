// キーボードの下の欄の門(`MCPServer.keyboardRefusal`): 焦点を持つ欄への ft_type / ft_clear_input は断らない(mxa F10)。
// ドライバは焦点の欄を叩かずに打つ・消す。ft_tap など叩く操作は従来どおり断る。

import XCTest
import FTCore
@testable import fleetest_mcp

final class KeyboardRefusalFocusedFieldTests: XCTestCase {

    private func underKeyboard(focused: Bool) -> (ElementInfo, KeyboardOcclusion) {
        var field = ElementInfo(ref: 1, type: "textView", identifier: "field_multiline", label: nil, value: nil,
                                placeholder: nil, enabled: true, frame: FTRect(x: 16, y: 494, width: 370, height: 88),
                                depth: 1)
        field.focused = focused
        let occlusion = KeyboardOcclusion.resolve(reported: FTRect(x: 0, y: 538, width: 402, height: 336),
                                                  in: [field], screen: FTRect(x: 0, y: 0, width: 402, height: 874))
        return (field, occlusion)
    }

    private func refusal(tool: String, focused: Bool) async -> String? {
        let (field, occlusion) = underKeyboard(focused: focused)
        return await MCPServer.$currentTool.withValue(tool) {
            MCPServer.keyboardRefusal(field, keyboardOcclusion: occlusion)
        }
    }

    func testFocusedFieldIsNotRefusedForTypeAndClearInput() async {
        let (field, occlusion) = underKeyboard(focused: true)
        XCTAssertNotNil(occlusion.advisory(for: field), "前提: 中心がキーボードの下")
        for tool in ["ft_type", "ft_clear_input"] {
            let message = await refusal(tool: tool, focused: true)
            XCTAssertNil(message, "\(tool) が焦点の欄を断った")
        }
    }

    func testUnfocusedFieldAndTapAreStillRefused() async {
        let unfocusedClear = await refusal(tool: "ft_clear_input", focused: false)
        XCTAssertNotNil(unfocusedClear)
        let focusedTap = await refusal(tool: "ft_tap", focused: true)
        XCTAssertNotNil(focusedTap)
    }
}
