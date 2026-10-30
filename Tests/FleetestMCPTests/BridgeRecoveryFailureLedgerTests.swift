// 自動の起動し直しの失敗を永久に覚えない(負荷テスト 2026-10-30 b F4)と、起動し直しの注記が事実だけを言うこと
// (b F1 / a F3 / c F1)・失われた宛先の断りが「端末が落ちた」と言わないこと(b F2)の固定。

import XCTest
@testable import fleetest_mcp

final class BridgeRecoveryFailureLedgerTests: XCTestCase {

    func testNoMemoryNeverBlocks() {
        XCTAssertFalse(BridgeRecoveryFailureLedger.blocksRetry(remembered: false, key: "ledger-test-none"))
    }

    /// 旗だけが立っていて控えが無い(控えより前に立った旗)は従来どおり止める
    func testFlagWithoutEntryBlocks() {
        XCTAssertTrue(BridgeRecoveryFailureLedger.blocksRetry(remembered: true, key: "ledger-test-noentry"))
    }

    func testFailureBlocksOnlyWithinTheCooldown() {
        let key = "ledger-test-cooldown"
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        BridgeRecoveryFailureLedger.record(key: key, detail: "port 8123 is in use", now: t0)
        let cooldown = BridgeRecoveryFailureLedger.retryCooldownSeconds
        XCTAssertTrue(BridgeRecoveryFailureLedger.blocksRetry(
            remembered: true, key: key, now: t0.addingTimeInterval(cooldown - 1)))
        XCTAssertFalse(BridgeRecoveryFailureLedger.blocksRetry(
            remembered: true, key: key, now: t0.addingTimeInterval(cooldown + 1)))
    }

    func testNoteCarriesTheReasonOnlyWhileBlocking() {
        let key = "ledger-test-note"
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        BridgeRecoveryFailureLedger.record(key: key, detail: "port 8123 is in use", now: t0)
        let during = BridgeRecoveryFailureLedger.note(key: key, now: t0.addingTimeInterval(5))
        XCTAssertTrue(during.contains("port 8123 is in use"), during)
        XCTAssertTrue(during.contains("again automatically"), during)
        XCTAssertEqual(BridgeRecoveryFailureLedger.note(key: key, now: t0.addingTimeInterval(500)), "")
        XCTAssertEqual(BridgeRecoveryFailureLedger.note(key: "ledger-test-unknown"), "")
    }

    /// 既定値はリテラルで固定する(他のテストが差し替え口で値を明示しても production の既定を通る)
    func testCooldownDefaultIsPinned() {
        XCTAssertEqual(BridgeRecoveryFailureLedger.retryCooldownSeconds, 60)
    }

    func testNoRunningBridgeMessageCarriesTheFailureReason() {
        let udid = "LEDGER-TEST-UDID"
        BridgeRecoveryFailureLedger.record(key: udid, detail: "port 8123 is in use")
        let text = MCPServer.noResponsiveBridgeMessage(udid: udid, diagnosis: .unknown)
        XCTAssertTrue(text.contains("port 8123 is in use"), text)
    }

    func testRebuildNotesDoNotClaimTheAppWasRelaunched() {
        for note in [MCPServer.bridgeRebuiltNote, MCPServer.bridgeStartedForUDIDNote] {
            XCTAssertFalse(note.contains("relaunched"), note)
            XCTAssertFalse(note.contains("back at its start"), note)
            XCTAssertTrue(note.contains("resume: true"), note)
            XCTAssertTrue(note.contains("ref"), note)
        }
    }

    func testLostTargetRefusalDoesNotSayTheDeviceIsDown() {
        let text = MCPServer.lostTargetRefusal(survivors: [], deviceNoun: "iOS devices", unitNoun: "ports",
                                               otherPlatform: nil)
        XCTAssertTrue(text.contains("no longer reachable"), text)
        XCTAssertTrue(text.contains("does not mean the device is down"), text)
    }

    // MARK: - connectionLostMessage

    func testSimulatorMessageNamesTheUDIDAndResume() {
        let text = MCPServer.connectionLostMessage(connection: "port 8123", running: [], bridge: "xcuitest",
                                                   udid: "SIM-UDID", tunnelOnly: false)
        XCTAssertTrue(text.contains("bridge up --device SIM-UDID"), text)
        XCTAssertTrue(text.contains("resume: true"), text)
        XCTAssertTrue(text.contains("udid SIM-UDID"), text)
    }

    /// 実機でトンネルだけが消えた形で「ランナーが exited / simulator」と言わない
    func testTunnelOnlyMessageDoesNotClaimTheRunnerExited() {
        let text = MCPServer.connectionLostMessage(connection: "port 8127", running: [], bridge: "xcuitest",
                                                   udid: "PHYS-UDID", tunnelOnly: true)
        XCTAssertFalse(text.contains("exited"), text)
        XCTAssertFalse(text.contains("simulator"), text)
        XCTAssertTrue(text.contains("not checked"), text)
        XCTAssertTrue(text.contains("udid PHYS-UDID"), text)
    }
}
