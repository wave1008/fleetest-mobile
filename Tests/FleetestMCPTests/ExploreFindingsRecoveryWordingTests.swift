// 探索所見(2026-10-31)の文言・診断の固定: 実機の案内に --physical・Mac 側の待受が残るのにトンネルを開き直せと言わない・
// 背面の in-app ブリッジを busy と読まない・ft_list_devices は「MCP からは動かせない」と断定しない。

import XCTest
import FTBridgeClient
@testable import fleetest_mcp

final class ExploreFindingsRecoveryWordingTests: XCTestCase {

    func testTunnelOnlyMessageNamesPhysicalFlag() {
        let text = MCPServer.connectionLostMessage(connection: "port 8154", running: [], bridge: "xcuitest",
                                                   udid: "PHYS", tunnelOnly: true)
        XCTAssertTrue(text.contains("bridge up --device PHYS --physical"), text)
    }

    func testPhysicalRunnerGoneDoesNotSuggestReopeningTheTunnel() {
        let text = MCPServer.connectionLostMessage(connection: "port 8154", running: [], bridge: "xcuitest",
                                                   udid: "PHYS", tunnelOnly: false, physicalRunnerGone: true)
        XCTAssertTrue(text.contains("bridge up --device PHYS --physical"), text)
        XCTAssertTrue(text.contains("still listening"), text)
        XCTAssertFalse(text.contains("re-opened"), text)
        XCTAssertFalse(text.contains("may well still be running"), text)
    }

    func testBackgroundedInAppPortIsNotBusyAndAllowsRebuild() {
        let diagnosis = MCPServer.UDIDBridgeDiagnosis(
            listeningButUnresponsive: [], heldByRunPID: nil, lookup: .simulator,
            backgroundedInAppPorts: [8130])
        XCTAssertTrue(MCPServer.nothingListensFor(diagnosis))
        let text = MCPServer.noResponsiveBridgeMessage(udid: "SIM", diagnosis: diagnosis)
        XCTAssertTrue(text.hasPrefix("no running bridge is on udid SIM."), text)
        XCTAssertTrue(text.contains("port 8130 is held by an app's in-app bridge"), text)
        XCTAssertFalse(text.contains("busy"), text)
    }

    func testInAppOnlyLedgerIsBackgroundedButALiveRunnerPidIsNot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString)")
        let state = root.appendingPathComponent(".fleetest")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(MCPServer.isBackgroundedInAppBridgeOnly(port: 9301, repoRoot: root), "台帳が無ければ違う")
        try "SIM com.example".write(to: InAppBridgeState.url(stateDir: state, port: 9301), atomically: true, encoding: .utf8)
        XCTAssertTrue(MCPServer.isBackgroundedInAppBridgeOnly(port: 9301, repoRoot: root))
        try "\(getpid())".write(to: state.appendingPathComponent("bridge-9301.pid"), atomically: true, encoding: .utf8)
        XCTAssertFalse(MCPServer.isBackgroundedInAppBridgeOnly(port: 9301, repoRoot: root), "生きたランナーが居れば busy でありうる")
    }

    func testPhysicalBusyMessageOffersTheStuckTunnelExit() {
        let physical = MCPServer.bridgeBusyOnUDIDMessage(
            udid: "P", diagnosis: .init(listeningButUnresponsive: [8154], heldByRunPID: nil, lookup: .physical))
        XCTAssertTrue(physical.contains("bridge down --port 8154 --force"), physical)
        let sim = MCPServer.bridgeBusyOnUDIDMessage(
            udid: "S", diagnosis: .init(listeningButUnresponsive: [8130], heldByRunPID: nil, lookup: .simulator))
        XCTAssertFalse(sim.contains("--force"), sim)
    }

    func testListDevicesDoesNotClaimUndrivable() {
        let row = DeviceInventory.Row(name: "d", platform: "ios", identifier: "U1", running: true, physical: true,
                                      registered: true, bridges: [])
        let text = DeviceInventory.line(row)
        XCTAssertTrue(text.contains("no bridge"), text)
        XCTAssertFalse(text.contains("not drivable"), text)
        XCTAssertTrue(text.contains("--physical"), text)
    }
}
