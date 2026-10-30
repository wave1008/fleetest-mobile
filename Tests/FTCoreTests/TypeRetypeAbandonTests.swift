// 打ち直しを打ち切る(アプリの加工と断じて受理する)のは、打ち直す前と同じ値へ戻ったときだけ。
// witness: RN の iOS で打鍵が2回続けて別の位置で落ち、2回目の `.retype` が無条件に受理されて欄が欠けたまま ok になった。

import XCTest
@testable import FTCore

final class TypeRetypeAbandonTests: XCTestCase {

    func testAcceptsOnlyAReturnToTheValueBeforeRetyping() {
        XCTAssertEqual(TypeReadback.retypeEnd(actual: "12", previous: "12", beforeRetype: "12"), .accept)
        XCTAssertEqual(TypeReadback.retypeEnd(actual: "12", previous: "1", beforeRetype: "12"), .accept, "途中の値を挟んで戻った")
        XCTAssertEqual(TypeReadback.retypeEnd(actual: "1", previous: "12", beforeRetype: "12"), .readAgain, "まだ動いているかもしれない")
        XCTAssertEqual(TypeReadback.retypeEnd(actual: "a2", previous: "a2", beforeRetype: "12"), .fail, "止まっても違う形")
    }

    // 語の間の空白が読めている欄で空白が欠けたら打鍵の落ち。全部消えた形は読めない空白と区別できない
    func testDroppedSpaceIsRetypedOnlyWhenTheFieldShowsSpaces() {
        XCTAssertEqual(TypeReadback.plan(expected: "foo bar baz", actual: "foobar baz"), .retype)
        XCTAssertEqual(TypeReadback.plan(expected: "foo bar baz", actual: "foobarbaz"), .unverifiable)
        XCTAssertEqual(TypeReadback.plan(expected: "foo bar", actual: "foobar"), .unverifiable)
    }

    func testAValueThatRetypingBrokeIsNotAccepted() {
        XCTAssertEqual(TypeReadback.plan(expected: "1a2b3c", actual: "1233"), .unverifiable)
        XCTAssertTrue(TypeReadback.retypeBrokeField(retypes: 1, expected: "1a2b3c", actual: "1233"))
        XCTAssertFalse(TypeReadback.retypeBrokeField(retypes: 0, expected: "1a2b3c", actual: "1233"), "打ち直す前の加工は受理のまま")
        XCTAssertFalse(TypeReadback.retypeBrokeField(retypes: 1, expected: " abc", actual: "abc"), "読めない空白だけの差")
    }
}
