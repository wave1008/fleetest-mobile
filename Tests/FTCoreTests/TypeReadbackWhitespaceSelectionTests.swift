import XCTest
@testable import FTCore

/// 前後の空白が別の空白に化けた値(RN の iOS: 半角 → U+3000)と、語を選択して打った後ろが欠けた値の読み返し
final class TypeReadbackWhitespaceSelectionTests: XCTestCase {

    func testFullWidthSpaceInsteadOfTypedSpaceIsFlagged() {
        XCTAssertEqual(TypeReadback.plan(expected: " lead", actual: "\u{3000}lead"), .whitespaceAltered)
        XCTAssertEqual(TypeReadback.plan(expected: "lead ", actual: "lead\u{3000}"), .whitespaceAltered)
    }

    /// 語の間の空白が別の空白に化けた(RN の iOS: `🙂 ok` → `🙂　ok`)。数と位置が同じで種類だけ違う
    func testInnerWhitespaceKindChangeIsFlagged() {
        XCTAssertEqual(TypeReadback.plan(expected: "🙂 ok", actual: "🙂\u{3000}ok"), .whitespaceAltered)
        XCTAssertEqual(TypeReadback.plan(expected: "あ b", actual: "あ\u{3000}b"), .whitespaceAltered)
        // 落ちた空白(読めない空白)・文字が欠けた値は従来どおり
        XCTAssertEqual(TypeReadback.plan(expected: "a b", actual: "ab"), .unverifiable)
        XCTAssertEqual(TypeReadback.plan(expected: "a b", actual: "a "), .resend("b"))
    }

    /// 空白が読み返せない欄(空白が落ちて返る)は従来どおり検証を諦める
    func testUnreadableWhitespaceStaysUnverifiable() {
        XCTAssertEqual(TypeReadback.plan(expected: " lead", actual: "lead"), .unverifiable)
        XCTAssertEqual(TypeReadback.plan(expected: "lead ", actual: "lead"), .unverifiable)
    }

    func testSelectionReplacedButTailLostRetypesTheWholeTarget() {
        let target = TypeReadback.readbackTarget(expected: "hello worldABCD", typedOnly: "ABCD",
                                                 actual: "AB world", protectedPrefixCount: 11)
        XCTAssertEqual(target, "ABCD world")
        XCTAssertEqual(TypeReadback.plan(expected: target, actual: "AB world"), .retype)
    }

    /// 追記が丸ごと届いた通常の形・全部届いた置き換えは目標を変えない
    func testAppendedTextKeepsTheExpectedTarget() {
        XCTAssertEqual(TypeReadback.readbackTarget(expected: "helloABCD", typedOnly: "ABCD",
                                                   actual: "helloABCD", protectedPrefixCount: 5), "helloABCD")
        XCTAssertNil(TypeReadback.selectionReplacedTarget(expected: "hello worldABCD", typedOnly: "ABCD",
                                                          actual: "ABCD world"))
    }
}
