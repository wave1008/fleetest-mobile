// 別プロセスが指を下ろしたまま死ぬと、ゲストに identifier 0 の指が残り、次の gRPC ジェスチャの down はその指の MOVE として
// 消費される(探索 b F1。実測: 残った指のまま ft_drag(900,1700→900,800)が「sent」で、アプリは swipe=right)。
// ジェスチャの前に pressure 0 の up を1本送って上げる。指が無いときの up は何も起こさない(実測)。
// この up を外す・drag と longPress の片方だけに掛ける変異を落とす。

import Foundation
import XCTest

final class GestureStrayFingerScanTests: XCTestCase {

    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTEmulatorGrpc/EmulatorGrpcSession.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testRequireControllerReleasesAStrayFingerAfterGetStatus() throws {
        let text = try source()
        let start = try XCTUnwrap(text.range(of: "private static func requireController("))
        let body = String(text[start.lowerBound...].prefix(1800))
        let statusAt = try XCTUnwrap(body.range(of: "client.getStatus("))
        let upAt = try XCTUnwrap(body.range(of: "touchEvent(x: point.x, y: point.y, pressure: 0)"),
                                 "getStatus の後の pressure 0 の up が無い")
        XCTAssertLessThan(statusAt.lowerBound, upAt.lowerBound, "up は getStatus(撃ってよい確認)の後でなければならない")
    }

    func testBothGesturesClearTheStrayFingerAtTheirStartPoint() throws {
        let text = try source()
        XCTAssertTrue(text.contains("clearingStrayFingerAt: (fromX, fromY))"), "drag が始点で残った指を上げていない")
        XCTAssertTrue(text.contains("clearingStrayFingerAt: (x, y))"), "longPress が押す点で残った指を上げていない")
    }
}
