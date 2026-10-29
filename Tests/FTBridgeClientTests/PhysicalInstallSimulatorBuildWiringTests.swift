// 実機の install はすべて BridgeClient.install の devicectl の枝を通る。Simulator 用ビルドの断りはそこ1箇所に置き、devicectl を撃つ前に効かせる
// (呼び手ごとに置くと、CLI・ライブ操作・MCP の autoInstall のように漏れる経路が出る)

import XCTest

final class PhysicalInstallSimulatorBuildWiringTests: XCTestCase {
    func testDevicectlInstallIsGuardedAgainstASimulatorBuild() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let client = try String(contentsOf: root.appendingPathComponent("Sources/FTBridgeClient/BridgeClient.swift"),
                                encoding: .utf8)
        let start = try XCTUnwrap(client.range(of: "public func install(packagePath: String) async throws -> String? {"))
        let body = client[start.upperBound...].prefix(1500)
        let check = try XCTUnwrap(body.range(of: "ReinstallPackageCheck.isSimulatorBuildOffPool(path: packagePath)"),
                                  "実機の install が Simulator 用ビルドを断っていない")
        let devicectl = try XCTUnwrap(body.range(of: "\"devicectl\", \"device\", \"install\""))
        XCTAssertLessThan(check.lowerBound, devicectl.lowerBound, "devicectl を撃った後に確かめても遅い")
    }
}
