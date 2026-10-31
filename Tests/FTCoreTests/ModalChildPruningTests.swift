// in-app の木が `accessibilityViewIsModal` を守る(確認ダイアログ・全画面カバー・アラート・メニューの背面を木から外す)。
// 実測 2026-11-01(Simulator iOS 27.0 / E2EX-iOS): 4形とも背面の兄弟が旗付きの view の下に居た。

import XCTest
@testable import FTCore

final class ModalChildPruningTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            url.deleteLastPathComponent()
        }
        return try String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
    }

    /// 窓の子 = [アプリ本体の UITransitionView, 旗付きの UITransitionView] → 旗付き以降(= 手前)だけが残る
    func testPicksTheVisibleModalSibling() {
        XCTAssertEqual(BridgeAPI.visibleModalChildStart(isModal: [false, true], isVisible: [true, true]), 1)
    }

    /// 複数あれば最後(手前)から残る
    func testPicksTheFrontMostModalSibling() {
        XCTAssertEqual(BridgeAPI.visibleModalChildStart(isModal: [true, false, true], isVisible: [true, true, true]), 2)
    }

    /// 見えない旗付き view(メニューの出入りで残る alpha 0 の UITransitionView)は背面を消さない
    func testIgnoresInvisibleModalSibling() {
        XCTAssertNil(BridgeAPI.visibleModalChildStart(isModal: [false, true], isVisible: [true, false]))
        XCTAssertEqual(BridgeAPI.visibleModalChildStart(isModal: [false, true, true], isVisible: [true, true, false]), 1)
    }

    func testNoModalMeansNoPruning() {
        XCTAssertNil(BridgeAPI.visibleModalChildStart(isModal: [false, false], isVisible: [true, true]))
        XCTAssertNil(BridgeAPI.visibleModalChildStart(isModal: [], isVisible: []))
    }

    /// 木の走査が子の選別を通る(通さない版では背面のボタンが木に残り exist / tap が XCUITest と逆になる)
    func testSnapshotCollectGoesThroughTheModalFilter() throws {
        let snapshot = try source("InAppBridge/Sources/InAppSnapshot.swift")
        XCTAssertTrue(snapshot.contains("let children = modalChildOnly(axChildren(node))"))
        XCTAssertTrue(snapshot.contains("BridgeAPI.visibleModalChildStart"))
    }
}
