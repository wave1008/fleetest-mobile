// replace の消去の後の引き直しは DSL と MCP で同じ判定(ClearedFieldRelocation.relocate)。同じ画面で片方だけ引けると、
// MCP で通った手順が DSL(ft_batch・シナリオ)では「消した・打っていない」で落ちる

import XCTest
@testable import FTCore

final class ClearedFieldRelocationTests: XCTestCase {
    private func field(_ ref: Int, y: Double, placeholder: String?) -> ElementInfo {
        ElementInfo(ref: ref, type: "textField", identifier: nil, label: nil, value: nil, placeholder: placeholder,
                    enabled: true, frame: FTRect(x: 20, y: y, width: 300, height: 40), depth: 3)
    }

    /// id の無いアラートの欄がキーボードで持ち上がった: DSL の経路も placeholder で引き直す
    func testTheDSLPathFindsAMovedFieldWithoutIdByPlaceholder() {
        let before = field(3, y: 400, placeholder: "入力")
        let snapshot = SnapshotResponse(sessionBundleID: "a", screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                        elements: [field(11, y: 250, placeholder: "入力"), field(12, y: 600, placeholder: "別")],
                                        truncatedCount: 0)
        var step = FlowStep(action: "type")
        var locator = FlowLocator()
        locator.placeholder = "存在しない"
        step.locator = locator
        XCTAssertEqual(StepExecutor.relocateAfterClear(before, step: step, in: snapshot)?.ref, 11)
        XCTAssertEqual(ClearedFieldRelocation.relocate(before, in: snapshot.elements)?.ref, 11)
    }
}
