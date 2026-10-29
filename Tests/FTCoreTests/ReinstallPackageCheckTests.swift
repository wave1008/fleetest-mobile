// 実機の入れ直しの前に断る判定(ReinstallPackageCheck)・ブリッジ自身の判定(BridgeSelfApps)・install のパス確認。

import XCTest
@testable import FTCore

final class ReinstallPackageCheckTests: XCTestCase {
    func testSimulatorBuildByDTPlatformNameIsRefused() {
        let plist: [String: Any] = ["CFBundleIdentifier": "com.sutec.mobile", "DTPlatformName": "iphonesimulator"]
        XCTAssertEqual(ReinstallPackageCheck.judge(infoPlist: plist, expectedBundleID: "com.sutec.mobile"), .simulatorBuild)
    }

    func testSimulatorBuildBySupportedPlatformsIsRefused() {
        let plist: [String: Any] = ["CFBundleIdentifier": "a.b", "CFBundleSupportedPlatforms": ["iPhoneSimulator"]]
        XCTAssertEqual(ReinstallPackageCheck.judge(infoPlist: plist, expectedBundleID: "a.b"), .simulatorBuild)
    }

    func testDeviceBuildWithSameBundleIDIsOK() {
        let plist: [String: Any] = ["CFBundleIdentifier": "a.b", "DTPlatformName": "iphoneos",
                                    "CFBundleSupportedPlatforms": ["iPhoneOS"]]
        XCTAssertEqual(ReinstallPackageCheck.judge(infoPlist: plist, expectedBundleID: "a.b"), .ok)
    }

    func testDifferentBundleIDAndUnreadable() {
        XCTAssertEqual(ReinstallPackageCheck.judge(infoPlist: ["CFBundleIdentifier": "x.y"], expectedBundleID: "a.b"),
                       .differentApp(packageBundleID: "x.y"))
        XCTAssertEqual(ReinstallPackageCheck.judge(infoPlist: nil, expectedBundleID: "a.b"), .unreadable)
        XCTAssertEqual(ReinstallPackageCheck.judge(infoPlist: [:], expectedBundleID: "a.b"), .unreadable)
    }

    func testBridgeSelfApps() {
        XCTAssertTrue(BridgeSelfApps.isBridgeItself("com.example.ftbridge"))
        XCTAssertTrue(BridgeSelfApps.isBridgeItself("io.github.wave1008.ftrunner.uitests.xctrunner"))
        XCTAssertTrue(BridgeSelfApps.isBridgeItself("io.github.wave1008.ftrunner"))
        XCTAssertFalse(BridgeSelfApps.isBridgeItself("com.ftester.e2e.ios"))
        XCTAssertFalse(BridgeSelfApps.isBridgeItself("com.example.ftbridgefoo"))
        // 利用者自身の UI テストのランナーは巻き込まない(末尾 .xctrunner を一律に当てない)
        XCTAssertFalse(BridgeSelfApps.isBridgeItself("com.acme.AppUITests.xctrunner"))
    }

    func testInstallPackagePathExistence() {
        XCTAssertFalse(InstallPackagePath.exists("/nonexistent/x.app", fileExists: { _ in false }))
        XCTAssertTrue(InstallPackagePath.exists("/a/b.app", fileExists: { $0 == "/a/b.app" }))
    }

    /// uninstall を止めるかの線引き(MCP の ft_clear_app_data と DSL の clearAppData が共有):
    /// 読めないときだけ出所で分かれ、Simulator 用・別アプリは出所に関わらず止める
    func testBlocksUninstallDependsOnTheSourceOnlyWhenUnreadable() {
        XCTAssertFalse(ReinstallPackageCheck.ok.blocksUninstall(packageNamedByCaller: false))
        XCTAssertTrue(ReinstallPackageCheck.unreadable.blocksUninstall(packageNamedByCaller: false))
        XCTAssertFalse(ReinstallPackageCheck.unreadable.blocksUninstall(packageNamedByCaller: true))
        XCTAssertTrue(ReinstallPackageCheck.simulatorBuild.blocksUninstall(packageNamedByCaller: true))
        XCTAssertTrue(ReinstallPackageCheck.differentApp(packageBundleID: "b").blocksUninstall(packageNamedByCaller: true))
    }

    /// DSL の clearAppData も止めるかを `blocksUninstall` で決める(答えの表を自分の switch に写さない = MCP と判定がずれない)
    func testDSLClearAppDataDecidesWithTheSharedJudgement() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FTDSL/CommandsAppControl.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(code.contains("guard verdict.blocksUninstall(packageNamedByCaller: false) else { return nil }"))
    }

    /// パッケージの読み(.ipa は unzip = 同期の外部コマンド)を、MCP / DSL の非同期の経路で直接呼ばない(協調スレッドプールを塞ぐ)。
    /// `inspectOffPool` / `isSimulatorBuildOffPool` を通す
    func testAsyncCallersReadPackagesOffThePool() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        for file in ["Sources/fleetest-mcp/MCPServer+SessionTools.swift", "Sources/FTDSL/CommandsAppControl.swift"] {
            let code = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(code.contains("ReinstallPackageCheck.inspect("), "\(file) が同期の inspect を呼んでいる")
            XCTAssertFalse(code.contains("AppPackageReader.open("), "\(file) が同期の AppPackageReader.open を呼んでいる")
        }
    }
}
