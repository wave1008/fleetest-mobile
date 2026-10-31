// Android ブリッジの回復を妨げていた2つの門(負荷テスト 2026-10-30 e F3 / e F6)のソース走査。
// 実機・端末が要る経路なので、構造だけを固定する。

import XCTest

final class AndroidBridgeRecoveryGateScanTests: XCTestCase {

    private func code() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTAndroid/AndroidBridge.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// adb forward の失敗は失敗キャッシュ(60 秒の再生)に載せない
    func testForwardFailureIsNotCached() throws {
        let c = try code()
        XCTAssertTrue(c.contains("do { hostPort = try ensureForward() } catch { throw ForwardStepFailure(underlying: error) }"))
        guard let r = c.range(of: "catch let forward as ForwardStepFailure {") else {
            return XCTFail("ForwardStepFailure の分岐が無い")
        }
        // 次の catch の手前まで(その次の枝は失敗キャッシュの本体)
        let rest = c[r.upperBound...]
        let branch = String(rest[..<(rest.range(of: "} catch")?.lowerBound ?? rest.endIndex)])
        XCTAssertTrue(branch.contains("Self.setRegistry(key, nil)"), branch)
        XCTAssertFalse(branch.contains(".unavailable("), branch)
    }

    /// ブリッジのプロセスが無いと確かめられたら、他のセッションの印があっても起動し直す
    func testAbsentBridgeProcessIsNotRefusedAsHeldByAnotherSession() throws {
        let c = try code()
        guard let r = c.range(of: "hasForeignLeaseUnlessOwnRun(key: serial, stateDir: stateDir) {") else {
            return XCTFail("門が見当たらない")
        }
        let cond = String(c[r.upperBound...].prefix(200))
        XCTAssertTrue(cond.contains("probed != nil ? true : Self.isBridgeRunning("), cond)
        XCTAssertTrue(cond.contains("!= false"), cond)
    }
}
