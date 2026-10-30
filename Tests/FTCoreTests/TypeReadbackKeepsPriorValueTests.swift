// 先頭の語の選択・カーソルが先頭のとき、読み返しが撃った文字を削除で消さない(typedOnly 側の deleteExcess を余りが撃つ前の値のときに採らない)
import XCTest
@testable import FTCore

final class TypeReadbackKeepsPriorValueTests: XCTestCase {
    func testSelectedFirstWordReplacementIsNotDeleted() {
        let expected = "hello worldABCD"
        let actual = "ABCD world"
        let target = TypeReadback.readbackTarget(expected: expected, typedOnly: "ABCD", actual: actual,
                                                 protectedPrefixCount: 11)
        XCTAssertEqual(target, expected)
        XCTAssertEqual(TypeReadback.plan(expected: target, actual: actual, protectedPrefixCount: 11), .unverifiable)
    }

    func testCursorAtStartIsNotDeleted() {
        let expected = "hello worldQ"
        let actual = "Qhello world"
        let target = TypeReadback.readbackTarget(expected: expected, typedOnly: "Q", actual: actual,
                                                 protectedPrefixCount: 11)
        XCTAssertEqual(TypeReadback.plan(expected: target, actual: actual, protectedPrefixCount: 11), .unverifiable)
    }

    func testHintFieldDoubleInputStillDeletes() {
        // 撃つ前の値がヒント文字列の欄: 二重入力(余りが撃った文字)は従来どおり typedOnly で削除
        let target = TypeReadback.readbackTarget(expected: "単一行hello123", typedOnly: "hello123",
                                                 actual: "hello123hello123", protectedPrefixCount: 3)
        XCTAssertEqual(target, "hello123")
        XCTAssertEqual(TypeReadback.plan(expected: target, actual: "hello123hello123"), .deleteExcess(8))
    }

    func testExcessEqualToTypedTextStaysDoubleInput() {
        XCTAssertFalse(TypeReadback.typedOnlyExcessIsPriorValue(expected: "名前前", typedOnly: "前", actual: "前前"))
    }
}
