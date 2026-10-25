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

    /// 操作可能な要素が無ければ、点を含むいちばん小さい要素(地図等)へ写し、押した点と結果が違い得る印を立てる
    func testFallsBackToTheSmallestElementOfAnyTypeAndSaysItIsNotThePoint() {
        let map = element(1, "other", id: "pad_map", 0, 100, 400, 600)
        let target = PointTarget.writableSelector(atX: 200, y: 300, in: tree([map]))
        XCTAssertEqual(target?.selector, "#pad_map")
        XCTAssertEqual(target?.pressesThePoint, false)
        // 操作可能な要素の上なら中心で同じ結果 = 印は立てない
        let button = element(2, "button", id: "ok", 100, 200, 100, 40)
        XCTAssertEqual(PointTarget.writableSelector(atX: 150, y: 220, in: tree([map, button])),
                       PointTarget.Target(selector: "#ok", durability: .stable, pressesThePoint: true))
    }

    /// 操作できない要素へは、安定したセレクタ(#id・ラベル)が書けるときだけ写す。索引形しか書けなければ座標の行
    func testAreaFallbackNeedsAStableSelector() {
        let root = element(1, "other", id: "Maps.Application", 0, 0, 400, 800)
        let a = element(2, "other", 0, 100, 400, 300)
        let b = element(3, "other", 0, 400, 400, 300)
        // a・b は名前が無く同じ型 = `#Maps.Application >> .other[n]` の索引形しか書けない
        XCTAssertNil(PointTarget.writableSelector(atX: 200, y: 250, in: tree([root, a, b])))
    }

    /// 画面全体を覆う要素(アプリ・ウィンドウ・根の容器)には写さない —— 中心を押す行が意味を持たない
    func testElementsCoveringTheWholeScreenAreNotTargets() {
        let window = element(1, "window", id: "main_window", 0, 0, 400, 800)
        XCTAssertNil(PointTarget.writableSelector(atX: 200, y: 300, in: tree([window])))
    }

    /// 点に操作可能な要素が在れば、名前の無いボタンでもその要素を指す(相対のセレクタ)。
    /// 操作できない大きい要素(地図)へは移らない = 押した点と同じ結果の印のまま
    func testOperableElementWinsOverTheLargerAreaEvenWithoutAnID() {
        let map = element(1, "other", id: "pad_map", 0, 100, 400, 600)
        let button = element(2, "button", 100, 200, 50, 40)
        let target = PointTarget.writableSelector(atX: 120, y: 220, in: tree([map, button]))
        XCTAssertNotEqual(target?.selector, "#pad_map")
        XCTAssertEqual(target?.pressesThePoint, true)
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
