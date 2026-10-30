// ft_capture_element は手前の部品に中心を覆われた要素を見本にしない(切り抜きは覆いの絵になり、保存は永続 = 分類器が以後ずっと誤る)

import XCTest
import FTCore
@testable import fleetest_mcp

final class CaptureCoverRefusalTests: XCTestCase {
    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    private func element(_ ref: Int, _ id: String, _ type: String,
                         _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil, placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: 17)
    }

    func testCoveredElementIsNotSaved() {
        let target = element(13, "sw_target", "switch", 60, 300, 116, 32)
        let cover = element(18, "", "datePicker", 41, 246.67, 320, 216)
        let refusal = MCPServer.captureCoverRefusal(target, in: [target, cover], screen: screen)
        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal?.hasPrefix("nothing was saved") == true, refusal ?? "")
    }

    func testUncoveredElementIsSaved() {
        let target = element(13, "sw_target", "switch", 60, 300, 116, 32)
        XCTAssertNil(MCPServer.captureCoverRefusal(target, in: [target], screen: screen))
    }
}
