// ft_terminate / ft_clear_app_data / ft_logs / ft_install の寿命まわりの規律(純粋関数とソース走査)。

import XCTest
import FTCore
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

    /// iOS(Android 以外のドライバ)では Apple のアプリと SpringBoard を撃つ前に断り、普通のアプリは通す。
    /// `com.apple.` の接頭辞で断るのは Android 以外だけ(Android では普通のパッケージ名)= 分岐が AndroidDriver の外にあること
    func testAppleSystemAppRefusalIsIOSOnly() async {
        let server = MCPServer(write: { _ in }, makeDriver: { _ in FakeDriver() }, recordSnapshot: { _, _, _ in })
        let fake = FakeDriver()
        let refused = await server.clearAppDataSystemTargetRefusal("com.apple.mobilesafari", driver: fake, args: [:])
        XCTAssertTrue(refused?.contains("Apple system app") == true, refused ?? "nil")
        let springBoard = await server.clearAppDataSystemTargetRefusal(MCPServer.springboardBundleID, driver: fake, args: [:])
        XCTAssertNotNil(springBoard)
        let plain = await server.clearAppDataSystemTargetRefusal("com.example.app", driver: fake, args: [:])
        XCTAssertNil(plain)
    }

    /// iOS の Apple のアプリはドライバを作る前に断る(作ると、ブリッジの居ない udid でランナーの自動起動を払ってから断っていた)
    func testAppleAppIsRefusedBeforeTheDriverIsMade() async {
        let made = LockedValue(false)
        let server = MCPServer(write: { _ in }, makeDriver: { _ in made.withLock { $0 = true }; return FakeDriver() },
                               recordSnapshot: { _, _, _ in })
        do {
            _ = try await server.call(tool: "ft_clear_app_data", args: ["bundleId": "com.apple.mobilesafari"])
            XCTFail("断らなかった")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Apple system app"), error.localizedDescription)
        }
        XCTAssertFalse(made.value, "ドライバを作ってから断った")
    }
}
