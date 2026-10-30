// アプリの寿命まわり: clearAppData が別アプリのセッションを閉じない・devicectl openURL へ渡す URL の形。

import XCTest
@testable import FTBridgeClient

final class AppLifecycleFixesTests: XCTestCase {
    func testClearingAnotherAppDoesNotCloseTheRunnerSession() {
        XCTAssertTrue(BridgeClient.shouldCloseSessionBeforeClearing(sessionBundleID: "a.b", clearing: "a.b"))
        XCTAssertFalse(BridgeClient.shouldCloseSessionBeforeClearing(sessionBundleID: "a.b", clearing: "c.d"))
        XCTAssertFalse(BridgeClient.shouldCloseSessionBeforeClearing(sessionBundleID: nil, clearing: "c.d"))
    }

    func testOnlyNonASCIIIsPercentEncodedForDevicectl() {
        XCTAssertEqual(BridgeClient.encodingNonASCII("app://s?q=日&x=%20a#f"), "app://s?q=%E6%97%A5&x=%20a#f")
        XCTAssertEqual(BridgeClient.encodingNonASCII("app://s?x=%20a"), "app://s?x=%20a")
    }
}
