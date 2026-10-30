// ft_terminate / ft_clear_app_data / ft_logs / ft_install の寿命まわりの規律(純粋関数とソース走査)。

import XCTest
@testable import fleetest_mcp

final class SessionLifetimeToolsTests: XCTestCase {
    func testRecentReportBeforeLaunchIsNotThisRunsCrash() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lifetime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.ips")
        try Data("x".utf8).write(to: file)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30)], ofItemAtPath: file.path)
        XCTAssertTrue(CrashLogs.isFromBeforeLaunch(path: file.path, launchedAt: now.addingTimeInterval(-10)))
        XCTAssertFalse(CrashLogs.isFromBeforeLaunch(path: file.path, launchedAt: now.addingTimeInterval(-60)))
        XCTAssertFalse(CrashLogs.isFromBeforeLaunch(path: file.path, launchedAt: nil))
        XCTAssertTrue(CrashLogs.olderThanLaunchText(bundleID: "com.x", launchedAt: now, waited: 4.2).contains("earlier run"))
    }

    func testPhysicalDeviceGuidanceUsesSystemCrashLogsDomain() {
        let text = CrashLogs.physicalDeviceText(bundleID: "com.x", udid: "U")
        XCTAssertTrue(text.contains("--domain-type systemCrashLogs"), text)
        XCTAssertFalse(text.contains("<container path>"), text)
    }

    func testTerminateAndClearRefuseSystemTargetsBeforeSending() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/fleetest-mcp/MCPServer+SessionTools.swift").standardized
        let source = try String(contentsOf: url, encoding: .utf8)
        // SpringBoard を ft_terminate の対象にしない(リスプリングで端末がロック画面に落ちる)
        XCTAssertTrue(source.contains("if terminateBundleID == MCPServer.springboardBundleID {"))
        // Android の terminate は名乗った相手を名指しで止める(ドライバの控え currentPackage に頼らない)
        XCTAssertTrue(source.contains("let stopsByName = terminateDriver is AndroidDriver"))
        XCTAssertTrue(source.contains(".isPersistentPackage(bundleID: terminateBundleID)"))
        XCTAssertTrue(source.contains("bundleID.hasPrefix(\"com.apple.\")"))
    }
}
