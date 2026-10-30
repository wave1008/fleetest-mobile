// ref 無しの `type` が「入力フォーカスが無い」で落ちたときの案内(2026-08-21 の受け手報告)。
//
// ブリッジの文面は「tap the field by ref first」だが、**その tap が効かなかったからここに来る**
// ので、読み手は次に何をすべきか分からない。Android の入力欄は容器(TextInputLayout)と
// 中身(TextInputEditText)に分かれ、**id は容器側に付くことが多い** —— `#id` で tap すると
// 容器に解決し、入力フォーカスは中身へ移らない。案内はセレクタを取る `type` へ寄せる。

import XCTest
@testable import FTAndroid
import FTCore

final class TypeNoFocusAdviceTests: XCTestCase {

    private let noFocus = "no-input-focus: nothing has input focus (tap the field by ref first)"

    func testAdvisesTheSelectorFormWhenNothingHasFocus() throws {
        let rewritten = AndroidDriver.typeNoFocusAdvice(
            after: .badResponse(status: 500, body: noFocus), hadRef: false)

        guard case .badResponse(let status, let body)? = rewritten else {
            return XCTFail("書き換えていない: \(String(describing: rewritten))")
        }
        XCTAssertEqual(status, 500, "status はホストの分岐契約なので変えない")
        XCTAssertTrue(body.contains(noFocus), "元の理由も残すこと: \(body)")
        XCTAssertTrue(body.contains("type(<selector>"), "次の一手が書かれていない: \(body)")
        XCTAssertTrue(body.contains("TextInputEditText"), "容器と中身の話が要る: \(body)")
    }

    /// **ref 付きで落ちたら別の話**(掴んだ要素へ撃って失敗している)ので触らない
    func testLeavesRefTypeFailuresAlone() {
        XCTAssertNil(AndroidDriver.typeNoFocusAdvice(
            after: .badResponse(status: 500, body: noFocus), hadRef: true))
    }

    /// フォーカス以外の失敗には足さない(全部のエラーに同じ助言を付けない)
    func testLeavesOtherFailuresAlone() {
        XCTAssertNil(AndroidDriver.typeNoFocusAdvice(
            after: .badResponse(status: 500, body: "set-text rejected"), hadRef: false))
        XCTAssertNil(AndroidDriver.typeNoFocusAdvice(
            after: .bridgeUnreachable(
                context: DriverErrorContext(bridge: .android, physicalDevice: false), detail: "x"),
            hadRef: false))
    }
}

/// 前面が覆い(systemui)・別のアプリのときは、欄の話ではなく前面の話をする
final class TypeNoFocusFrontAdviceTests: XCTestCase {
    private let noFocus = "no-input-focus: nothing has input focus (tap the field by ref first)"

    private func body(front: String?, last: String?) -> String? {
        guard case .badResponse(_, let b)? = AndroidDriver.typeNoFocusAdvice(
            after: .badResponse(status: 500, body: noFocus), hadRef: false, front: front, lastTreePackage: last)
        else { return nil }
        return b
    }

    func testSystemUIInFrontIsNamedNotTheField() throws {
        let b = try XCTUnwrap(body(front: "com.android.systemui", last: "com.app"))
        XCTAssertTrue(b.contains("notification shade"), b)
        XCTAssertFalse(b.contains("TextInputEditText"), b)
    }

    func testAnotherAppInFrontSaysTheAppWentAway() throws {
        let b = try XCTUnwrap(body(front: "com.other", last: "com.app"))
        XCTAssertTrue(b.contains("com.other is in front, not com.app"), b)
        XCTAssertFalse(b.contains("TextInputEditText"), b)
    }

    func testSameAppInFrontKeepsTheContainerAdvice() throws {
        let b = try XCTUnwrap(body(front: "com.app", last: "com.app"))
        XCTAssertTrue(b.contains("TextInputEditText"), b)
    }
}
