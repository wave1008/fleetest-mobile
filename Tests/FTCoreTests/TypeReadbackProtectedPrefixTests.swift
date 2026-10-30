// 欄の選択範囲を置き換えた途中の読みを「打鍵の落ち」と誤判定して打ち直さない(TypeReadback.plan の protectedPrefixCount)。
// 実機 SE3 の再現: "hello world" の "hello" を選んで X を打つ → 一瞬 " world" と読めて全文を打ち直し、欄が「hello  world」に壊れた。

import XCTest
import FTCore

final class TypeReadbackProtectedPrefixTests: XCTestCase {

    /// 撃つ前の値(11 文字)の側が欠けた読みは、打鍵の落ちではない
    func testDropInsidePriorValueIsNotRetyped() {
        XCTAssertEqual(TypeReadback.plan(expected: "hello worldX", actual: " world", protectedPrefixCount: 11),
                       .unverifiable)
    }

    /// 撃った文字の側の欠落は従来どおり打ち直す
    func testDropInsideTypedPartIsStillRetyped() {
        XCTAssertEqual(TypeReadback.plan(expected: "abc" + "hello123", actual: "abc" + "hllo123", protectedPrefixCount: 3),
                       .retype)
    }

    /// 既定(0)は従来の挙動
    func testDefaultKeepsExistingBehaviour() {
        XCTAssertEqual(TypeReadback.plan(expected: "hello worldX", actual: " world"), .retype)
    }

    func testReadbackTargetPassesTheProtectionThrough() {
        let target = TypeReadback.readbackTarget(expected: "hello worldX", typedOnly: "X", actual: " world",
                                                 protectedPrefixCount: 11)
        XCTAssertEqual(TypeReadback.plan(expected: target, actual: " world", protectedPrefixCount: 11), .unverifiable)
    }
}
