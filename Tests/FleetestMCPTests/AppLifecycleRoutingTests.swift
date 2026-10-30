// ft_logs の bundleId 既定が別の台の起動を借りない・存在しない serial に印を書かない。

import XCTest
@testable import fleetest_mcp

final class AppLifecycleRoutingTests: XCTestCase {
    func testDoesNotBorrowALaunchMadeOnANamedDevice() {
        let launched = ["direct:android:0:14141JEC204922": "com.ftester.e2ey"]
        XCTAssertNil(MCPServer.borrowableLaunchedBundleID(launched: launched, platform: "android"))
    }

    func testBorrowsAnUnnamedSessionOfTheSamePlatformOnly() {
        XCTAssertEqual(MCPServer.borrowableLaunchedBundleID(
            launched: ["direct:android:0:": "a.b", "direct:android:0:SER": "c.d"], platform: "android"), "a.b")
        XCTAssertEqual(MCPServer.borrowableLaunchedBundleID(
            launched: ["profile:P:run:android": "a.b"], platform: "android"), "a.b")
        XCTAssertNil(MCPServer.borrowableLaunchedBundleID(launched: ["direct:ios:0:": "a.b"], platform: "android"))
        XCTAssertNil(MCPServer.borrowableLaunchedBundleID(
            launched: ["direct:android:0:": "a.b", "profile:P:run:android": "c.d"], platform: "android"))
    }
}
