import XCTest
@testable import FTCore

final class RunTotalsLineTests: XCTestCase {
    func testWorkQueueChildStoppedBeforeAnyScenarioDoesNotClaimAPass() throws {
        let line = try XCTUnwrap(RunTotalsLine.noScenarioRan(ranCount: 0, workQueue: true, abortReason: "no device"))
        XCTAssertTrue(line.contains("ran no scenario"), line)
        XCTAssertFalse(line.contains("passed"), line)
    }

    func testOtherRunsKeepTheNormalLine() {
        XCTAssertNil(RunTotalsLine.noScenarioRan(ranCount: 1, workQueue: true, abortReason: "no device"))
        XCTAssertNil(RunTotalsLine.noScenarioRan(ranCount: 0, workQueue: false, abortReason: "no device"))
        XCTAssertNil(RunTotalsLine.noScenarioRan(ranCount: 0, workQueue: true, abortReason: nil))
    }
}
