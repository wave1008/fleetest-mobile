// テキストの可視性検証の失敗文に「画面のどの文字も描かれていない」の事実を添える(`undrawnScreenFact`)。判定(赤)は変えない。
// 添えないと、1つの要素の問題か端末側の描画の崩れかを読み分けられない(Simulator の CMP で文字だけが画面ごと消えた絵で実測)

import XCTest
@testable import FTCore

final class UndrawnScreenFactTests: XCTestCase {

    private static let frames = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/BlackFrames")
    private static let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
    /// 可視性検証の既定の閾値(StepExecutor.init の occlusionInkThreshold の既定)
    private static let inkThreshold: Double = 12

    private static func text(_ ref: Int, _ label: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: "staticText", identifier: nil, label: label, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: x, y: y, width: w, height: h), depth: 2)
    }

    /// 実物: Simulator の E2EX-CMP(入力の種類)で、枠は描けているのに文字が画面ごと消えた絵。キーボードは出ている
    func testTextMissingAcrossTheScreenIsNamed() throws {
        let png = try Data(contentsOf: Self.frames.appendingPathComponent("ios-cmp-text-not-drawn.png"))
        let elements = [
            Self.text(3, "入力の種類", 56, 80, 103, 28), Self.text(4, "number=123", 16, 134, 100, 24),
            Self.text(5, "password_len=0", 16, 162, 131, 24), Self.text(6, "lines=0", 16, 190, 58, 24),
            Self.text(7, "focus=none", 16, 218, 94, 24), Self.text(8, "auto=none", 16, 246, 85, 24),
            Self.text(9, "bottom=", 16, 274, 68, 24), Self.text(11, "国", 32, 346, 15, 24),
            Self.text(13, "数量", 32, 398, 23, 16), Self.text(15, "パスワード", 32, 498, 77, 24),
            Self.text(19, "姓", 32, 698, 15, 24), Self.text(21, "名", 32, 774, 15, 24),
        ]
        let keyboard = FTRect(x: 0, y: 572, width: 402, height: 302)
        let fact = StepExecutor.undrawnScreenFact(screenshot: png, elements: elements, screen: Self.screen,
                                                  keyboard: keyboard, inkThreshold: Self.inkThreshold)
        XCTAssertTrue(fact.contains("text element(s) the tree reports on screen is drawn"), fact)
    }

    /// 実物: 文字が描かれている Flutter の画面には添えない
    func testDrawnScreenGetsNoFact() throws {
        let png = try Data(contentsOf: Self.frames.appendingPathComponent("ios-flutter-text-drawn.png"))
        let elements = [
            Self.text(2, "テキスト入力", 100, 92, 84, 20), Self.text(3, "single=", 16, 158, 49, 20),
            Self.text(4, "password=secret42", 16, 186, 134, 20), Self.text(5, "len=0", 16, 214, 38, 20),
            Self.text(6, "ime=0", 16, 242, 42, 20), Self.text(7, "submitted=-", 16, 270, 84, 20),
            Self.text(12, "multiline=", 16, 466, 66, 20),
        ]
        XCTAssertEqual(StepExecutor.undrawnScreenFact(screenshot: png, elements: elements, screen: Self.screen,
                                                      keyboard: nil, inkThreshold: Self.inkThreshold), "")
    }
}
