// XCUITest ランナーの木の幾何(手前の窓・ウィジェットの局所座標・キーボードの枠・横向きの SpringBoard の門)の配線を守る。
// ランナーは単体でコンパイルできないのでソース走査で固定する。

import XCTest

final class RunnerSnapshotGeometryContractTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Runner/FleetestRunnerUITests/\(name)"), encoding: .utf8)
    }

    /// inputAccessoryView だけの全画面の窓は、窓の枠でなく中身の外接矩形を申告する(落とすと全 tap に「手前の窓の下」と誤警告)
    func testInputAccessoryOnlyWindowReportsContentBounds() throws {
        let router = try source("BridgeRouter.swift")
        let snapshot = try source("BridgeRouter+Snapshot.swift")
        XCTAssertTrue(router.contains("content.hasTextInput"), "入力欄を持つ全画面の窓だけ中身の外接矩形にすること")
        XCTAssertTrue(router.contains("content.union.intersection(screen)"))
        XCTAssertTrue(snapshot.contains("lastOverlayWindowContent = content"))
        XCTAssertTrue(snapshot.contains("textInputTypes.contains("))
    }


    /// 横向きの SpringBoard を断る門は端末の向きだけで決めない(縦で描かれたホーム画面は撃てる)
    func testLandscapeSpringBoardGateLooksAtTheTreeScreen() throws {
        let router = try source("BridgeRouter.swift")
        XCTAssertFalse(router.contains("if BridgeAPI.springBoardTapWouldMiss(") || router.contains(", BridgeAPI.springBoardTapWouldMiss("),
                       "呼び手は springBoardTapWouldMissNow を通すこと")
        XCTAssertTrue(router.contains("lastTreeScreen.height > lastTreeScreen.width"))
        XCTAssertGreaterThanOrEqual(router.components(separatedBy: "lastTreeScreen = cap.screen").count - 1, 2,
                                    "アプリの /snapshot と /systemui/snapshot の両方で画面を控えること")
    }

}
