import XCTest
import FTCore
@testable import fleetest_mcp

final class BatchTypeSelectorMistakeTests: XCTestCase {
    private func field(_ id: String) -> ElementInfo {
        ElementInfo(ref: 1, type: "textField", identifier: id, label: nil, value: nil,
                    placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)
    }

    func testRefusesTextThatIsAnIdOnScreen() {
        let step = FlowStep(action: "type", text: "#field_single")
        XCTAssertNotNil(MCPServer.typeTextLooksLikeSelector(step, tree: [field("field_single")]))
    }

    func testAllowsHashtagThatIsNotOnScreenAndSelectorForm() {
        XCTAssertNil(MCPServer.typeTextLooksLikeSelector(FlowStep(action: "type", text: "#swift"),
                                                         tree: [field("field_single")]))
        var withSelector = FlowStep(action: "type", text: "#field_single")
        withSelector.locator = FlowLocator(id: "field_single")
        XCTAssertNil(MCPServer.typeTextLooksLikeSelector(withSelector, tree: [field("field_single")]))
    }
}
