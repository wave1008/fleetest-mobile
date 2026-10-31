// 探索 p F6: 端末の一瞬の切断の後、ft_terminate が「nothing was launched here」と言った(切断の案内が起動の記録まで捨てていた)。
// 物理端末が同じ serial で戻ったときだけ記録を返す。Emulator は serial が port の番号で別の AVD に再利用されうるので返さない。

import XCTest
import FTCore
import FTBridgeClient
@testable import fleetest_mcp

final class LaunchRecordSurvivesReconnectTests: XCTestCase {

    private func facts() -> ConnectionFacts {
        ConnectionFacts(scan: { _ in [] }, mayBeListening: { _, _ in true }, ownerAlive: { _, _ in nil },
                        probeStatus: { _, _ in .timedOut }, androidListed: { [] })
    }

    private func vanish(serial: String) async -> MCPServer {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() }, recordSnapshot: { _, _, _ in })
        let key = "direct:android:\(serial)"
        server.launchedBundleIDs[key] = "com.example.app"
        server.connectedAndroidSerials[key] = serial
        _ = await server.androidConnectionLostHint(
            DriverError.notDelivered(context: DriverErrorContext(bridge: .android, physicalDevice: true), detail: "device offline"),
            key: key, connection: "serial \(serial)", serial: serial, facts: facts(), mayHaveTakenEffect: false)
        XCTAssertNil(server.launchedBundleIDs[key], "切断の案内は従来どおり記憶を捨てる")
        return server
    }

    func testPhysicalDeviceKeepsTheLaunchRecordForTheSameSerial() async {
        let server = await vanish(serial: "14141JEC204922")
        XCTAssertEqual(server.launchRecordAcrossAndroidDisconnect?.bundleID, "com.example.app")
        XCTAssertEqual(MCPServer.restoredLaunchRecord(saved: server.launchRecordAcrossAndroidDisconnect, serial: "14141JEC204922"),
                       "com.example.app")
    }

    func testAnotherSerialDoesNotInheritTheRecord() async {
        let server = await vanish(serial: "14141JEC204922")
        XCTAssertNil(MCPServer.restoredLaunchRecord(saved: server.launchRecordAcrossAndroidDisconnect, serial: "93MAY0CY1M"))
    }

    func testEmulatorSerialsAreNeverKept() async {
        let server = await vanish(serial: "emulator-5554")
        XCTAssertNil(server.launchRecordAcrossAndroidDisconnect, "emulator-<port> は別の AVD に再利用されうる")
    }

    func testNoRecordMeansNothingToKeep() {
        XCTAssertNil(MCPServer.launchRecordSurvivingDisconnect(serial: "14141JEC204922", bundleID: nil))
    }

    /// 復元の配線: ドライバを作った直後に、保留した記録を返し、保留を空にする
    func testDriverCreationRestoresAndClearsTheHeldRecord() throws {
        let source = try MCPServerSourceText.combined()
        let start = try XCTUnwrap(source.range(of: "connectedAndroidSerials[key] = serial\n            // 一瞬の切断"))
        let body = String(source[start.lowerBound...].prefix(700))
        XCTAssertTrue(body.contains("restoredLaunchRecord(saved: launchRecordAcrossAndroidDisconnect, serial: serial)"), body)
        XCTAssertTrue(body.contains("launchRecordAcrossAndroidDisconnect = nil"), body)
    }
}
