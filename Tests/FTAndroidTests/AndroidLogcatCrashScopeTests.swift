// crash バッファの絞り込み: 現在の pid ではなく「パッケージ名を名乗る行を出したプロセス」の行を残す
// (落ちたアプリを起動し直すと pid が変わり、`--pid` は前のプロセスのクラッシュを捨てていた)。

import XCTest
@testable import FTAndroid

final class AndroidLogcatCrashScopeTests: XCTestCase {
    private let raw = """
        --------- beginning of crash
        10-30 02:57:01.100  4242  4242 E AndroidRuntime: FATAL EXCEPTION: main
        10-30 02:57:01.100  4242  4242 E AndroidRuntime: Process: com.ftester.e2e, PID: 4242
        10-30 02:57:01.100  4242  4242 E AndroidRuntime: java.lang.RuntimeException: FT_E2E intentional crash
        10-30 02:57:01.100  4242  4242 E AndroidRuntime: \tat com.x.Y.z(Y.java:1)
        10-30 02:58:00.000  7777  7777 E AndroidRuntime: Process: com.ftester.e2e.flutter, PID: 7777
        10-30 02:58:00.000  7777  7777 E AndroidRuntime: java.lang.Error: other
        """

    func testKeepsTheStackOfTheCrashedProcessEvenThoughItIsNotRunningAnyMore() {
        let scoped = AndroidLogcat.crashScoped(rawOutput: raw, packageName: "com.ftester.e2e")
        XCTAssertTrue(scoped.contains("FT_E2E intentional crash"), scoped)
        XCTAssertTrue(scoped.contains("Y.java:1"), scoped)
    }

    func testDoesNotPullInASiblingPackageWithTheSamePrefix() {
        let scoped = AndroidLogcat.crashScoped(rawOutput: raw, packageName: "com.ftester.e2e")
        XCTAssertFalse(scoped.contains("java.lang.Error: other"), scoped)
        XCTAssertFalse(scoped.contains("7777"), scoped)
    }

    func testAPackageWithNoCrashYieldsNothing() {
        XCTAssertEqual(AndroidLogcat.crashScoped(rawOutput: raw, packageName: "com.nonexistent.app"), "")
    }
}
