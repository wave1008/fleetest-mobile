// SpringBoard の覆いの判定(`/systemui/covering`)。
// 実測 2026-11-01(Simulator iPhone 17 Pro / iOS 27.0・SE3 / iOS 26.6.2): CC を開いても `SBSwitcherWindow:Main` は木に居続け、
// 木の順で CC より先に来る。触れない(CC を開くと両機とも false)この窓が OR 述語の firstMatch に当たって nil を返し、
// CC を覆いと言えなかった。

import XCTest
@testable import FTCore

final class SystemUICoveringProbeTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            url.deleteLastPathComponent()
        }
        return try String(contentsOf: url.appendingPathComponent(path), encoding: .utf8)
    }

    /// スイッチャーの窓は木の順で先でも最後に回る(実測の木の順: 窓 → cc-root-folder-view)
    func testSwitcherWindowIsCheckedLast() {
        let ids = ["SBSwitcherWindow:Main", "cc-root-folder-view", "cc-volume-slider"]
        XCTAssertEqual(BridgeAPI.coveringCandidateOrder(identifiers: ids), [1, 2, 0])
    }

    func testOrderIsStableWithoutSwitcher() {
        XCTAssertEqual(BridgeAPI.coveringCandidateOrder(identifiers: ["SBCoverSheetWindow", "cc-root-folder-view"]), [0, 1])
        XCTAssertEqual(BridgeAPI.coveringCandidateOrder(identifiers: []), [])
    }

    /// Simulator の CC はスライダーが無く、根だけが目印になる(実測の木)
    func testSimulatorControlCenterRootIsAMarker() {
        XCTAssertTrue(BridgeAPI.systemUICoveringMarkers.contains("cc-root-folder-view"))
        XCTAssertEqual(CoveringSurface.from(marker: "cc-root-folder-view"), .controlCenter)
    }

    /// ランナーは OR 述語の firstMatch 1件で決めない(触れない窓が先に当たる)。順を通して1件ずつ見る
    func testRunnerProbeDoesNotDecideOnFirstMatch() throws {
        let runner = try source("Runner/FleetestRunnerUITests/BridgeRouter.swift")
        let start = try XCTUnwrap(runner.range(of: "private func probeSystemUICovering()"))
        let tail = String(runner[start.lowerBound...])
        let end = tail.range(of: "private func handleSystemUISnapshot")?.lowerBound ?? tail.endIndex
        // コメントは落とす(判定の名前は doc にも出る)
        let body = tail[..<end].split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(body.contains("firstMatch"), "触れない SBSwitcherWindow が先に当たって CC を取りこぼす")
        XCTAssertTrue(body.contains("BridgeAPI.coveringCandidateOrder"))
    }
}
