// ブリッジ自身(BridgeSelfApps)の断りは MCP・DSL だけでなく、ライブ操作(launch/activate/clearAppData)と CLI の
// `fleetest launch` にも掛かる(撃つとブリッジが自滅する。判定は共有・文言は呼び手ごと)

import XCTest
@testable import fleetest

final class BridgeSelfRefusalLiveAndCLITests: XCTestCase {
    func testLiveControlRefusesTheBridgeButNotAnApp() {
        XCTAssertThrowsError(try ApiLiveServe.refuseBridgeItself("com.example.ftbridge")) { error in
            XCTAssertTrue("\(error)".contains("own bridge, not your app"), "\(error)")
        }
        XCTAssertNoThrow(try ApiLiveServe.refuseBridgeItself("com.example.app"))
    }

    /// 走査: ライブ操作の clearAppData は追従が無いと launchGuard を通らないので、自分でも断る。CLI の launch は撃つ前に断る
    func testWiringOfTheLiveClearAndCLILaunch() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/fleetest")
        let live = try String(contentsOf: root.appendingPathComponent("ApiLiveCommand.swift"), encoding: .utf8)
        let clear = try XCTUnwrap(live.range(of: "case \"clearAppData\":"))
        let clearBody = live[clear.upperBound...].prefix(600)
        XCTAssertTrue(clearBody.contains("try Self.refuseBridgeItself(bundle)"), String(clearBody))
        let cli = try String(contentsOf: root.appendingPathComponent("ManualDriveCommands.swift"), encoding: .utf8)
        let launch = try XCTUnwrap(cli.range(of: "struct Launch: AsyncParsableCommand"))
        XCTAssertTrue(cli[launch.upperBound...].prefix(900).contains("BridgeSelfApps.isBridgeItself(bundleID)"))
    }
}
