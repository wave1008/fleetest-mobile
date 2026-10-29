// dry-run が一時フォルダへ捨てたレポートのパスを、tearDownDevice / afterAll の失敗行に載せない(処理の終わりに消える)

import XCTest
@testable import FTCore

final class TearDownOutcomeReportPathTests: XCTestCase {
    private let failed = DeviceTearDownOutcome(hook: "afterAll", className: "Foo", passed: false,
                                               reportPath: "/tmp/fleetest-dryrun-x/report.html", failure: "boom")

    func testDiscardedReportPathIsLeftOutOfTheLine() {
        let line = ScenarioHost.describe(failed.droppingReportPath(true))
        XCTAssertFalse(line.contains("report:"), line)
        XCTAssertTrue(line.contains("boom"), line)
    }

    /// 写しは他の欄を保つ(走らせなかった回の文面は変わらない)
    func testDroppingKeepsTheOtherFields() {
        var notRun = DeviceTearDownOutcome(hook: "afterAll", className: "Foo", passed: false,
                                           reportPath: "/tmp/x.html", failure: "no device")
        notRun.ran = false
        let dropped = notRun.droppingReportPath(true)
        XCTAssertNil(dropped.reportPath)
        XCTAssertFalse(dropped.ran)
        XCTAssertEqual(dropped.failure, "no device")
    }

    func testKeptReportPathStaysOnTheLine() {
        XCTAssertTrue(ScenarioHost.describe(failed.droppingReportPath(false)).contains("(report: /tmp/fleetest-dryrun-x/report.html)"))
    }
}
