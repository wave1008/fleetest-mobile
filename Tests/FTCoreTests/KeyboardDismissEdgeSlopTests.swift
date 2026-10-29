import XCTest
@testable import FTCore

/// キーボードの縁に接した・裏へ押し込まれたタブバーの当たり判定の余白を、背景タップの点に選ばない
final class KeyboardDismissEdgeSlopTests: XCTestCase {

    private func el(_ ref: Int, _ type: String, _ id: String?, _ frame: FTRect, depth: Int) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil, placeholder: nil, enabled: true,
                    frame: frame, depth: depth, focused: nil)
    }

    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
    private let keyboard = FTRect(x: 0, y: 546, width: 402, height: 328)

    /// E2E-iOS の実測の形: タブがキーボード上端(546)より下(548)に押し込まれている
    private var tree: [ElementInfo] {
        [el(1, "other", nil, screen, depth: 0),
         el(2, "staticText", nil, FTRect(x: 56, y: 126, width: 95, height: 22), depth: 1),
         el(3, "tabBar", nil, FTRect(x: 0, y: 548, width: 402, height: 62), depth: 1),
         el(4, "tab", "tab_home", FTRect(x: 0, y: 548, width: 134, height: 62), depth: 2)]
    }

    func testNoCandidateWithinTheHitSlopOfATabTuckedBehindTheKeyboard() {
        let found = KeyboardDismissPoint.candidates(elements: tree, screen: screen, keyboard: keyboard, overlays: [])
        XCTAssertFalse(found.isEmpty)
        for choice in found {
            XCTAssertLessThan(choice.y, 548 - KeyboardDismissPoint.edgeHitSlop, "タブの当たり判定の余白(\(choice.x), \(choice.y))")
        }
    }

    /// E2E-CMP の小さい画面: タブの下端とキーボードの間の 8pt の隙間(木に載らない)は叩かず、その上の空きへ進む
    func testSkipsTheGapBetweenTheTabBarAndTheKeyboard() {
        let kb = FTRect(x: 0, y: 399, width: 375, height: 400)
        let scr = FTRect(x: 0, y: 0, width: 375, height: 800)
        let elements = [el(1, "other", nil, scr, depth: 0),
                        el(2, "tab", "tab_home", FTRect(x: 0, y: 343, width: 125, height: 48), depth: 1),
                        el(3, "tab", "tab_controls", FTRect(x: 125, y: 343, width: 125, height: 56), depth: 1)]
        let found = KeyboardDismissPoint.candidates(elements: elements, screen: scr, keyboard: kb, overlays: [])
        XCTAssertFalse(found.isEmpty)
        for choice in found {
            XCTAssertFalse(choice.y > 343 - KeyboardDismissPoint.edgeHitSlop && choice.x <= 250 + KeyboardDismissPoint.edgeHitSlop,
                           "タブの余白に候補(\(choice.x), \(choice.y))")
        }
    }

    /// 既定値はリテラルで固定する(実測: キーボード裏のタブは 11pt 上で反応・23pt 上で反応しない = その間)
    func testEdgeHitSlopIsPinned() {
        XCTAssertEqual(KeyboardDismissPoint.edgeHitSlop, 16)
    }

    /// 縁から離れた欄の余白までは除かない(詰まった画面で空きを失わない)
    func testControlsAwayFromTheKeyboardEdgeKeepOnlyTheirFrames() {
        let field = el(2, "textField", "f", FTRect(x: 16, y: 100, width: 370, height: 40), depth: 1)
        XCTAssertFalse(KeyboardDismissPoint.isNearKeyboardEdgeControl(x: 200, y: 145, elements: [field], keyboardTop: 546,
                                                                       keyboardRefs: []))
    }

    /// キーボードまで届く縦長のテキストビューの脇の狭い余白(その画面で唯一の空き)は、縁の帯より上なら候補に残る
    /// (部品の周り全体を除くと候補が空になり、DSL の hideKeyboard が Enter = 改行へ落ちる)
    func testNarrowMarginsBesideATallTextViewStayCandidatesAboveTheEdgeBand() {
        let compose = [el(1, "other", nil, screen, depth: 0),
                       el(2, "textView", "body", FTRect(x: 10, y: 60, width: 382, height: 486), depth: 1)]
        let found = KeyboardDismissPoint.candidates(elements: compose, screen: screen, keyboard: keyboard, overlays: [])
        XCTAssertFalse(found.isEmpty, "脇の余白が1つも候補に残らない")
        // 候補は入れ物ごとに1点 = テキストビューより上(画面の最上部)の点でも空ではなくなるので、脇(テキストビューの縦の範囲)にあることを見る
        XCTAssertTrue(found.contains { $0.y > 60 }, "テキストビューの脇の余白が候補に残っていない: \(found)")
        for choice in found {
            XCTAssertTrue(choice.x < 10 || choice.x > 392, "テキストビューの上を選んだ: (\(choice.x), \(choice.y))")
            XCTAssertLessThan(choice.y, keyboard.y - KeyboardDismissPoint.edgeHitSlop, "縁の帯の中を選んだ")
        }
    }

    /// キーボードの子孫でない押せる部品は、型が key でも余白を持つ(型ではなく木の位置で除く)
    func testKeyTypedControlOutsideTheKeyboardKeepsItsSlop() {
        let accessory = el(2, "key", "accessory_done", FTRect(x: 0, y: 548, width: 402, height: 40), depth: 1)
        XCTAssertTrue(KeyboardDismissPoint.isNearKeyboardEdgeControl(x: 200, y: 540, elements: [accessory],
                                                                     keyboardTop: 546, keyboardRefs: []))
    }

    /// キーボードの子孫(予測変換バーのボタン)の余白はキーボードの上の帯を潰さない(アプリの裏のタブだけが余白を持つ)
    func testPredictiveBarButtonsInsideTheKeyboardDoNotBlockTheBandAboveIt() {
        let elements = [el(1, "other", nil, screen, depth: 0),
                        el(2, "keyboard", nil, keyboard, depth: 1),
                        el(3, "button", "prediction", FTRect(x: 0, y: 546, width: 402, height: 44), depth: 2),
                        el(4, "key", "q", FTRect(x: 0, y: 600, width: 40, height: 44), depth: 2)]
        let found = KeyboardDismissPoint.candidates(elements: elements, screen: screen, keyboard: keyboard, overlays: [])
        XCTAssertTrue(found.contains { $0.y > 546 - KeyboardDismissPoint.edgeHitSlop }, "\(found.map(\.y))")
    }
}
