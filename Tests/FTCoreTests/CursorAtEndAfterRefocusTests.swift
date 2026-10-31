// 叩いて焦点を取り戻した複数行の欄で、カーソルを末尾へ送ってから打つ・消す(mxa F9)。
// 実測 2026-11-01 E2E-CMP(XCUITest): `type(欄,"L3"); type(別の欄,"p"); type(欄,"x")` が `xL3`(読み返しは文字の集合しか
// 見ないので通る)・clearInput は先頭への delete が空振り。Cmd+↓ を送ると `L3x`。

import XCTest
@testable import FTCore

final class CursorAtEndAfterRefocusTests: XCTestCase {

    private func field(type: String, value: String?) -> ElementInfo {
        ElementInfo(ref: 1, type: type, identifier: "field_multiline", label: nil, value: value, placeholder: nil,
                    enabled: true, frame: FTRect(x: 16, y: 458, width: 370, height: 40), depth: 1)
    }

    func testMultilineFieldWithAValueNeedsTheCursorAtTheEnd() {
        XCTAssertTrue(TypeReadback.needsCursorAtEndAfterRefocus(field(type: "textView", value: "L3")))
    }

    /// 空の欄は先頭 = 末尾。1行の欄は叩いた位置で末尾に着く形なので送らない
    func testEmptyMultilineAndSingleLineFieldsAreLeftAlone() {
        XCTAssertFalse(TypeReadback.needsCursorAtEndAfterRefocus(field(type: "textView", value: nil)))
        XCTAssertFalse(TypeReadback.needsCursorAtEndAfterRefocus(field(type: "textView", value: "")))
        XCTAssertFalse(TypeReadback.needsCursorAtEndAfterRefocus(field(type: "textField", value: "L3")))
        XCTAssertFalse(TypeReadback.needsCursorAtEndAfterRefocus(field(type: "secureTextField", value: "••")))
    }

    /// ランナーが type と clear の両方で、焦点が立つまで待った後にだけ送る
    func testRunnerSendsTheKeyInBothTypeAndClearAfterFocus() throws {
        var url = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            url.deleteLastPathComponent()
        }
        let source = try String(contentsOf: url.appendingPathComponent("Runner/FleetestRunnerUITests/BridgeRouter+TextInput.swift"),
                                encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "moveCursorToEndAfterRefocus(app, ref: ref)").count - 1, 2,
                       "type と clear の両方の叩いた直後で呼ぶこと")
        XCTAssertTrue(source.contains("app.typeKey(.downArrow, modifierFlags: .command)"))
        XCTAssertTrue(source.contains("(try? Self.requireKeyboardFocus(app)) != nil"), "焦点が無いまま送るとランナーごと落ちる")
        XCTAssertTrue(source.contains("TypeReadback.needsCursorAtEndAfterRefocus(element)"))
    }
}
