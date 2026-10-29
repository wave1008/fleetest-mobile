import XCTest
import FTCore
import FTAndroid

/// `BridgeSelfApps`(FTCore)はブリッジの識別子の写しを持つ(FTCore から FTAndroid も Runner のプロジェクトも参照できない)。
/// 写しが元とずれると、ブリッジ自身への launch / clearAppData が再び通って自滅する
final class BridgeSelfAppsSyncTests: XCTestCase {
    func testAndroidBridgePackageMatchesTheBridge() {
        XCTAssertEqual(BridgeSelfApps.androidBridgePackage, AndroidDriver.bridgePackage)
        XCTAssertTrue(BridgeSelfApps.isBridgeItself(AndroidDriver.bridgePackage))
    }

    /// Runner のプロジェクトが宣言するランナーの bundle ID(と XCTest が付ける `.xctrunner`)を全部ブリッジと見なす
    func testRunnerBundleIDsInTheProjectAreRecognised() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(contentsOf: root.appendingPathComponent("Runner/FleetestRunner.xcodeproj/project.xcproj"),
                                 encoding: .utf8)
        let prefix = try XCTUnwrap(project.firstMatch(of: /"FT_BUNDLE_ID_PREFIX": "([^"]+)"/)?.1)
        let runnerIDs = project.matches(of: /"PRODUCT_BUNDLE_IDENTIFIER": "\$\(FT_BUNDLE_ID_PREFIX\)(\.ftrunner[^"]*)"/)
            .map { String(prefix) + String($0.1) }
        XCTAssertEqual(runnerIDs.count, 2, "\(runnerIDs)")
        for id in runnerIDs {
            XCTAssertTrue(BridgeSelfApps.isBridgeItself(id), id)
        }
        // XCTest が UI テストのターゲットに付ける `.xctrunner`(実際に起動しているランナーの ID)
        let uiTests = try XCTUnwrap(runnerIDs.first { $0.hasSuffix(".uitests") })
        XCTAssertTrue(BridgeSelfApps.isBridgeItself(uiTests + ".xctrunner"))
    }
}
