// ft_launch / ft_clear_app_data / ft_terminate / ft_install の撃つ前の門と、resume の文言。

import XCTest
import FTCore
@testable import fleetest_mcp

final class SessionToolGuardsTests: XCTestCase {
    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
    }

    func testBridgeItselfIsRefusedBeforeLaunchAndClear() async {
        for (tool, id) in [("ft_launch", "com.example.ftbridge"), ("ft_clear_app_data", "com.example.ftbridge"),
                           ("ft_launch", "io.github.wave1008.ftrunner.uitests.xctrunner")] {
            do {
                _ = try await server.call(tool: tool, args: ["bundleId": id])
                XCTFail("\(tool) \(id) was not refused")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("fleetest's own bridge"), error.localizedDescription)
            }
        }
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("launch(") || $0.hasPrefix("clearAppData(") }, "\(driver.calls)")
    }

    func testSimulatorBuildIsRefusedBeforeUninstall() async throws {
        driver.clearAppDataError = DriverError.badResponse(
            status: 501, body: "clearAppData is simulator-only on iOS (devicectl has no equivalent)")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ft-simbuild-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("S.app").path
        try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.app", "DTPlatformName": "iphonesimulator"]
        FileManager.default.createFile(atPath: app + "/Info.plist",
            contents: try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
        do {
            _ = try await server.call(tool: "ft_clear_app_data",
                                      args: ["bundleId": "com.example.app", "packagePath": app])
            XCTFail("a Simulator build was accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Simulator build"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("NOT uninstalled"), error.localizedDescription)
        }
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("uninstall(") }, "\(driver.calls)")
    }

    /// ft_install と同じく、packagePath の相対パスは消す前に断る(MCP サーバの作業ディレクトリで解かれてしまう)
    func testClearAppDataRefusesARelativePackagePathBeforeUninstall() async throws {
        driver.clearAppDataError = DriverError.badResponse(
            status: 501, body: "clearAppData is simulator-only on iOS (devicectl has no equivalent)")
        do {
            _ = try await server.call(tool: "ft_clear_app_data",
                                      args: ["bundleId": "com.example.app", "packagePath": "build/A.ipa"])
            XCTFail("a relative path was accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("must be an absolute path"), error.localizedDescription)
        }
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("uninstall(") }, "\(driver.calls)")
    }

    func testResumeSummaryDependsOnWhetherItWasRunning() {
        XCTAssertTrue(MCPServer.resumeSummary(bundleID: "a.b", wasRunning: true).contains("resumed without relaunching"))
        let fresh = MCPServer.resumeSummary(bundleID: "a.b", wasRunning: false)
        XCTAssertTrue(fresh.contains("NOT running"), fresh)
        XCTAssertFalse(fresh.contains("resumed without relaunching"), fresh)
        let unknown = MCPServer.resumeSummary(bundleID: "a.b", wasRunning: nil)
        XCTAssertTrue(unknown.contains("could not check"), unknown)
        XCTAssertFalse(unknown.contains("resumed without relaunching"), unknown)
    }

    func testRelativePackagePathRefusal() {
        XCTAssertNotNil(MCPServer.relativePackagePathRefusal("relative/x.app"))
        XCTAssertNil(MCPServer.relativePackagePathRefusal("/a/x.app"))
        XCTAssertNil(MCPServer.relativePackagePathRefusal("~/a/x.app"), "~ は展開してから見る")
    }

    /// terminate の 409(ランナーにセッションが無い)は、このセッションで起動していたかで言い分ける
    func testTerminateNoSessionWordingDependsOnWhetherItWasLaunchedHere() {
        let launched = MCPServer.terminateNoSessionRefusal(bundleID: "a.b", launchedHere: true)
        XCTAssertTrue(launched.contains("lost its session"), launched)
        XCTAssertFalse(launched.contains("was not launched"), launched)
        // 回復の控えは消えている = ft_snapshot で確かめろと言わない(言うと「先に起動しろ」が返る)
        XCTAssertFalse(launched.contains("Check with ft_snapshot"), launched)
        let notLaunched = MCPServer.terminateNoSessionRefusal(bundleID: "a.b", launchedHere: false)
        XCTAssertTrue(notLaunched.contains("was not launched through ft_launch"), notLaunched)
    }
}
