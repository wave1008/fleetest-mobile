// アラートが前面にある間の木の範囲(AlertTreeScope)。MCP の snapshotBody と DSL の失敗レポートが共有する

import XCTest
@testable import FTCore

final class AlertTreeScopeTests: XCTestCase {

    private func el(_ ref: Int, _ type: String, _ label: String, depth: Int) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: nil, label: label, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 40, y: Double(ref * 50), width: 300, height: 44), depth: depth)
    }

    /// いちばん手前(木の順で最後)の alert を採り、その部分木だけを残す。背面の行も、alert の後ろの兄弟も残さない
    func testOnlyTheFrontAlertSubtreeIsKept() throws {
        // ボタン(y=250・300)を枠の中に持つ手前のアラート
        var frontAlert = el(4, "alert", "手前のアラート", depth: 1)
        frontAlert.frame = FTRect(x: 20, y: 200, width: 340, height: 160)
        let snapshot = SnapshotResponse(
            sessionBundleID: "com.example.app", screen: FTRect(x: 0, y: 0, width: 402, height: 874),
            elements: [el(1, "button", "背面", depth: 1),
                       el(2, "alert", "奥のアラート", depth: 1), el(3, "button", "奥のOK", depth: 2),
                       frontAlert, el(5, "button", "OK", depth: 2),
                       el(6, "button", "キャンセル", depth: 2), el(7, "button", "後ろの兄弟", depth: 1)],
            truncatedCount: 0)
        let alert = try XCTUnwrap(AlertTreeScope.frontInAppAlert(in: snapshot))
        XCTAssertEqual(alert.ref, 4)
        XCTAssertEqual(AlertTreeScope.alertOnly(alert, in: snapshot).elements.map(\.ref), [4, 5, 6])
        XCTAssertEqual(AlertTreeScope.buttonLabels(of: alert, in: snapshot), ["OK", "キャンセル"])
        XCTAssertNil(AlertTreeScope.frontInAppAlert(in: SnapshotResponse(
            sessionBundleID: nil, screen: snapshot.screen, elements: [el(1, "button", "背面", depth: 1)],
            truncatedCount: 0)))
    }

    /// オーバーレイの窓の行はアラートの部分木に並ぶことがある(深さだけでは見分けられない)。窓が違えばアラートの中身ではない
    func testRowsOfAnotherWindowAreNotPartOfTheAlert() {
        var alert = el(2, "alert", "確認", depth: 1)
        alert.frame = FTRect(x: 20, y: 40, width: 340, height: 400)
        var overlayButton = el(4, "button", "オーバーレイ", depth: 2)
        overlayButton.inOverlayWindow = true
        let snapshot = SnapshotResponse(
            sessionBundleID: "com.example.app", screen: FTRect(x: 0, y: 0, width: 402, height: 874),
            elements: [el(1, "button", "背面", depth: 1), alert, el(3, "button", "OK", depth: 2), overlayButton],
            truncatedCount: 0)
        XCTAssertEqual(AlertTreeScope.alertOnly(alert, in: snapshot).elements.map(\.ref), [2, 3])
        XCTAssertEqual(AlertTreeScope.buttonLabels(of: alert, in: snapshot), ["OK"])
    }

    /// アラート自身がオーバーレイの窓に居る形(同じ窓の行は中身)
    func testAnAlertInsideTheOverlayWindowKeepsItsOwnRows() {
        var alert = el(2, "alert", "確認", depth: 1)
        alert.frame = FTRect(x: 20, y: 40, width: 340, height: 400)
        alert.inOverlayWindow = true
        var ok = el(3, "button", "OK", depth: 2)
        ok.inOverlayWindow = true
        let snapshot = SnapshotResponse(
            sessionBundleID: "com.example.app", screen: FTRect(x: 0, y: 0, width: 402, height: 874),
            elements: [alert, ok, el(4, "button", "本体の窓", depth: 2)], truncatedCount: 0)
        XCTAssertEqual(AlertTreeScope.alertOnly(alert, in: snapshot).elements.map(\.ref), [2, 3])
        XCTAssertEqual(AlertTreeScope.buttonLabels(of: alert, in: snapshot), ["OK"])
    }

    /// **描かれていない alert(枠が0・画面の外)では木を伏せない**(閉じた後の残りで伏せると、押しても何も起きない
    /// アラートだけの画面が見え続ける)
    func testAnAlertThatIsNotOnScreenIsIgnored() {
        var offscreen = el(2, "alert", "閉じた後の残り", depth: 1)
        offscreen.frame = FTRect(x: 40, y: 900, width: 300, height: 200)
        var zero = el(3, "alert", "枠が0", depth: 1)
        zero.frame = FTRect(x: 40, y: 100, width: 0, height: 0)
        let snapshot = SnapshotResponse(sessionBundleID: "com.example.app",
                                        screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                        elements: [el(1, "button", "背面", depth: 1), offscreen, zero],
                                        truncatedCount: 0)
        XCTAssertNil(AlertTreeScope.frontInAppAlert(in: snapshot))
    }

    /// 入力欄つきのアラートではキーボード(予測変換の候補)が部分木に入る。ボタン一覧に並べるのはアラートの枠の中だけ
    func testKeyboardCandidatesInsideTheAlertSubtreeAreNotListedAsButtons() throws {
        var alert = el(1, "alert", "名前", depth: 1)
        alert.frame = FTRect(x: 20, y: 200, width: 340, height: 160)
        var ok = el(2, "button", "OK", depth: 2)
        ok.frame = FTRect(x: 40, y: 300, width: 300, height: 44)
        var candidate = el(3, "button", "こんにちは", depth: 3)
        candidate.frame = FTRect(x: 0, y: 560, width: 130, height: 44)
        let snapshot = SnapshotResponse(sessionBundleID: "com.example.app", screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                        elements: [alert, ok, candidate], truncatedCount: 0)
        XCTAssertEqual(AlertTreeScope.buttonLabels(of: alert, in: snapshot), ["OK"])
    }
}
