// ft_logs all: true が main(現在の pid)と crash(前のプロセスも含む)を別々に読んで束ねる処理と、
// ft_terminate / ft_clear_app_data が常駐パッケージを見分ける dumpsys の読み。

import XCTest
@testable import FTAndroid

final class AndroidLogcatCrashMergeTests: XCTestCase {
    func testMergeKeepsTimeOrderAndStability() {
        let main = ["10-30 12:00:03.000  200  200 I Tag: main late", "10-30 12:00:01.000  200  200 I Tag: main early"]
            .sorted()
        let crash = ["10-30 12:00:02.000  100  100 E AndroidRuntime: FATAL EXCEPTION: main"]
        let merged = AndroidLogcat.mergedByTimestamp(main, crash)
        XCTAssertEqual(merged.count, 3)
        XCTAssertTrue(merged[1].contains("FATAL EXCEPTION"), "crash の行が時刻の位置に入る: \(merged)")
        XCTAssertTrue(AndroidLogcat.mergedByTimestamp([], crash).first?.contains("FATAL") == true)
        XCTAssertEqual(AndroidLogcat.mergedByTimestamp(main, []), main)
    }

    func testPersistentFlagParsing() {
        let systemui = "Packages:\n  Package [com.android.systemui] (abc):\n    flags=[ SYSTEM HAS_CODE PERSISTENT ALLOW_CLEAR_USER_DATA ]\n"
        let settings = "  Package [com.android.settings] (abc):\n    flags=[ SYSTEM HAS_CODE ALLOW_CLEAR_USER_DATA ]\n"
        let legacy = "    pkgFlags=[ SYSTEM PERSISTENT ]\n"
        XCTAssertTrue(AndroidDriver.packageDumpIsPersistent(systemui))
        XCTAssertFalse(AndroidDriver.packageDumpIsPersistent(settings))
        XCTAssertTrue(AndroidDriver.packageDumpIsPersistent(legacy))
        XCTAssertFalse(AndroidDriver.packageDumpIsPersistent("    flags=[ HAS_CODE ]\n    name=PERSISTENT_thing\n"))
    }
}
