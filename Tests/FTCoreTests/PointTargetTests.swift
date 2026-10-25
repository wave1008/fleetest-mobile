// `PointTarget`: 座標で撃った操作を、中心を押しても同じ結果になる要素のセレクタへ写すかの判定
// (ライブ操作の操作記録と MCP の下書きが共有する)。

import XCTest
@testable import FTCore

final class PointTargetTests: XCTestCase {

    private func element(_ ref: Int, _ type: String, id: String? = nil, label: String? = nil,
                         _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: x, y: y, width: w, height: h), depth: 1)
    }

    private func tree(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app", screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                         elements: elements, truncatedCount: 0)
    }

    /// 点を含む操作可能な要素のうち、いちばん小さいもの(行の中のボタンはボタン)
    func testPicksTheSmallestOperableElementContainingThePoint() {
        let row = element(1, "cell", id: "row", 0, 100, 400, 60)
        let button = element(2, "button", id: "delete", 320, 110, 60, 40)
        XCTAssertEqual(PointTarget.element(atX: 340, y: 120, in: [row, button])?.ref, 2)
        XCTAssertEqual(PointTarget.element(atX: 100, y: 120, in: [row, button])?.ref, 1)
        // 端ちょうどは含む
        XCTAssertEqual(PointTarget.element(atX: 320, y: 110, in: [row, button])?.ref, 2)
    }

    /// 操作可能な型でない要素(容器・マップ・文字)は写さない —— 中心を押すと別の場所に当たる。
    /// ボタンの上の文字を押したならボタンに写る
    func testNonOperableElementsAreNotTargets() {
        let map = element(1, "other", id: "pad_map", 0, 0, 400, 800)
        XCTAssertNil(PointTarget.element(atX: 200, y: 400, in: [map]))
        let button = element(2, "button", id: "ok", 100, 100, 100, 40)
        let text = element(3, "staticText", label: "OK", 130, 110, 40, 20)
        XCTAssertEqual(PointTarget.element(atX: 140, y: 115, in: [map, button, text])?.ref, 2)
    }

    /// スライダーは押した位置で値が変わるので写さない
    func testPositionSensitiveTypesAreNotTargets() {
        let slider = element(1, "slider", id: "volume", 20, 100, 360, 30)
        XCTAssertNil(PointTarget.element(atX: 300, y: 110, in: [slider]))
    }

    /// 名前の無い小さい要素でも、その要素のセレクタ(SelectorNaming の格付けつき)を書く。
    /// 大きい要素(`#row`)へ繰り上げない(大きい要素の中心は押した点から遠い)
    func testNamesTheSmallestElementEvenWhenALargerOneHasAnID() {
        let row = element(1, "cell", id: "row", 0, 100, 400, 60)
        let anonymous = element(2, "button", 320, 110, 60, 40)
        let graded = PointTarget.writableSelector(atX: 340, y: 120, in: tree([row, anonymous]))
        XCTAssertNotEqual(graded?.selector, "#row")
        XCTAssertEqual(graded?.durability, .relative)
        XCTAssertEqual(PointTarget.writableSelector(atX: 100, y: 120, in: tree([row, anonymous]))?.selector, "#row")
    }
}
