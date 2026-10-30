import XCTest

/// 起動の途中で画面が消えたとき、前面の掃除が `am force-stop com.android.systemui` を撃たない(pixel F8)
final class LaunchNeverForceStopsSystemUITests: XCTestCase {
    func testHandleLaunchBranchesOnSystemUIBeforeTheForceStop() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("AndroidRunner/src/com/example/ftbridge/BridgeRouter.java")
        let src = try String(contentsOf: url, encoding: .utf8)
        let guardRange = try XCTUnwrap(src.range(of: "\"com.android.systemui\".equals(stuck)"))
        let stopRange = try XCTUnwrap(src.range(of: "shell(\"am force-stop \" + stuck)"))
        XCTAssertLessThan(guardRange.lowerBound, stopRange.lowerBound)
    }

    func testUnknownRefIsRefusedAsStaleRef() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("AndroidRunner/src/com/example/ftbridge/BridgeRouter.java")
        let src = try String(contentsOf: url, encoding: .utf8)
        let site = try XCTUnwrap(src.range(of: "reference number [\" + ref + \"] is unknown"))
        let tail = String(src[site.lowerBound...].prefix(200))
        XCTAssertTrue(tail.contains("STALE_REF_REASON"))
        XCTAssertFalse(src.contains("BridgeException(404"))
    }
}
