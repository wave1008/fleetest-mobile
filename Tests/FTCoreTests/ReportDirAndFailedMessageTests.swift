// 空の reportDir(--set / プロファイル / validate-profile)と `--failed` の空発話の文言。

import XCTest
@testable import FTCore

final class ReportDirAndFailedMessageTests: XCTestCase {

    func testSetOverrideRejectsBlankReportDir() {
        for token in ["reportDir=", "reportDir=   "] {
            XCTAssertThrowsError(try RunProfileSetOverride.parse([token])) { error in
                guard case RunProfileSetOverrideError.outOfRange(let key, _, _) = error else {
                    return XCTFail("outOfRange のはず: \(error)")
                }
                XCTAssertEqual(key, "reportDir")
            }
        }
        XCTAssertNoThrow(try RunProfileSetOverride.parse(["reportDir=out"]))
    }

    func testBlankReportDirJudgement() {
        XCTAssertTrue(RunProfileDocument.isBlankReportDir(""))
        XCTAssertTrue(RunProfileDocument.isBlankReportDir(" \n"))
        XCTAssertFalse(RunProfileDocument.isBlankReportDir("reports"))
    }

    func testNothingFailedMessageWithoutSelectionDoesNotSayOutsideSelection() {
        let withSelection = LastResultsStore.nothingFailedMessage(recordedCount: 5, failedCount: 2)
        XCTAssertTrue(withSelection.contains("outside this selection"))
        let noSelection = LastResultsStore.nothingFailedMessage(recordedCount: 5, failedCount: 2, hasSelection: false)
        XCTAssertFalse(noSelection.contains("outside this selection"))
        XCTAssertTrue(noSelection.contains("@Deleted or @Draft"))
    }

    func testNothingFailedMessageNamesStaleRecords() {
        let message = LastResultsStore.nothingFailedMessage(recordedCount: 5, failedCount: 0, hasSelection: false, staleCount: 4)
        XCTAssertTrue(message.contains("4 recorded failure(s)"))
        XCTAssertFalse(message.contains("every recorded scenario passed"))
    }
}
