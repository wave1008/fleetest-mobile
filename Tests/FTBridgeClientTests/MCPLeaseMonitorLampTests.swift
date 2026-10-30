// モニターの実行中のランプ(inMCP)は MCP の印だけで点く。ライブ操作の印はモニターでデバイスを選ぶだけで立つので数えない

import XCTest
@testable import FTBridgeClient
import FTCore

final class MCPLeaseMonitorLampTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private let pid = ProcessInfo.processInfo.processIdentifier

    func testMCPLeaseLightsTheLamp() {
        let dir = tempDir()
        MCPDeviceLease.write(stateDir: dir, key: "UDID-A", pid: pid, role: .mcp)
        XCTAssertTrue(MCPDeviceLease.hasMCPHolder(stateDir: dir, key: "UDID-A", excluding: []))
        XCTAssertFalse(MCPDeviceLease.hasMCPHolder(stateDir: dir, key: "UDID-B", excluding: []), "別の鍵では点かない")
        XCTAssertFalse(MCPDeviceLease.hasMCPHolder(stateDir: dir, key: "UDID-A", excluding: [pid]),
                       "モニター自身・拡張の pid は除く")
    }

    func testLiveControlLeaseDoesNotLightTheLamp() {
        let dir = tempDir()
        MCPDeviceLease.write(stateDir: dir, key: "UDID-A", pid: pid, role: .live(lastAction: Date()))
        XCTAssertFalse(MCPDeviceLease.hasMCPHolder(stateDir: dir, key: "UDID-A", excluding: []))
        XCTAssertNotNil(MCPDeviceLease.holderPID(stateDir: dir, key: "UDID-A", excluding: []),
                        "使用中(inSession)としては数える = 判定の軸が別")
    }
}
