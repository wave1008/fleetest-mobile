// 下書き・バッチの注記の修正(2026-10-30): launch の位置・別アプリの terminate・最後の手のアラート・アプリが前面を離れた要約・台の選択

import XCTest
import FTCore
@testable import fleetest_mcp

final class DraftBatchNotesTests: XCTestCase {

    private func entry(_ step: FlowStep?, summary: String, launch: Bool = false, bundleID: String? = nil) -> InteractionLog.Entry {
        InteractionLog.Entry(step: step, unresolved: nil, isLaunch: launch, bundleID: bundleID, summary: summary)
    }

    /// 実際の手の後の launch は condition の launchApp() に持ち上げない(順序が入れ替わる)
    func testALaunchAfterRealStepsIsNotTheConditionLaunch() {
        let tap = entry(FlowStep(action: "tap"), summary: "tap")
        let launch = entry(nil, summary: "launch a", launch: true, bundleID: "a")
        XCTAssertNil(MCPServer.conditionLaunchIndex(in: [tap, launch]))
        XCTAssertEqual(MCPServer.conditionLaunchIndex(in: [launch, tap]), 0)
        let declaration = entry(FlowStep(action: "irregularHandler"), summary: "irregularHandler")
        XCTAssertEqual(MCPServer.conditionLaunchIndex(in: [declaration, launch, tap]), 1)
    }

    func testATerminateOfAnotherAppBecomesATodo() {
        let other = entry(FlowStep(action: "terminate"), summary: "terminate com.other")
        let own = entry(FlowStep(action: "terminate"), summary: "terminate com.app")
        let out = MCPServer.terminatesOtherAppAsTodo([other, own], target: "com.app")
        XCTAssertNil(out[0].step)
        XCTAssertNotNil(out[1].step)
        let note = MCPServer.unrenderedStepNote(out[0], position: 0, isFirstLaunch: false, target: "com.app")
        XCTAssertTrue(note?.contains("stopped another app") == true, "\(note ?? "nil")")
    }

    func testDeviceKeysListTheRecordedDevices() {
        var log = InteractionLog()
        var a = entry(FlowStep(action: "tap"), summary: "tap"); a.deviceKey = "android:1"
        var b = entry(FlowStep(action: "tap"), summary: "tap"); b.deviceKey = "android:2"
        log.record(a); log.record(b)
        XCTAssertEqual(log.deviceKeys, ["android:1", "android:2"])
        XCTAssertEqual(log.latestDevice, "android:2")
    }

    private func alert(_ title: String) -> ElementInfo {
        ElementInfo(ref: 9, type: "alert", identifier: nil, label: title, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 0, y: 0, width: 100, height: 100), depth: 1)
    }

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "x", screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                         elements: elements, truncatedCount: 0)
    }

    /// 最後の手の前に居なかったアラートは、その手の結果でありうる = 「吸われた」と言わない
    func testAnAlertOpenedByTheLastStepIsNotCalledSwallowing() {
        let before = snapshot([])
        let final = snapshot([alert("確認")])
        XCTAssertFalse(MCPServer.batchAlertAppearedNote(beforeBatch: before, final: final).isEmpty)
        XCTAssertEqual(MCPServer.batchAlertAppearedNote(beforeBatch: before, final: final, beforeLastStep: []), "")
        XCTAssertFalse(MCPServer.batchAlertAppearedNote(
            beforeBatch: before, final: final, beforeLastStep: [alert("確認")]).isEmpty)
    }

    func testVerdictDoesNotSayPassedWhenTheAppLeftTheFront() {
        let verdict = MCPServer.batchVerdict(stepCount: 3, suspects: [], appLeftFront: true)
        XCTAssertFalse(verdict.contains("passed"), verdict)
        XCTAssertTrue(verdict.contains("no longer in front"), verdict)
    }

    func testKeyboardRefusalDoesNotPointAtPressEnterFirst() {
        let source = try! String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/FleetestMCPTests/DraftBatchNotesTests.swift", with: "Sources/fleetest-mcp/MCPServer+Snapshot.swift"))
        XCTAssertTrue(source.contains("Close the keyboard with ft_hide_keyboard"))
    }
}
