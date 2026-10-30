import XCTest
@testable import FTCore

final class StaleFramePreviousValueTests: XCTestCase {
    func testPreviousValueReadIsStale() {
        XCTAssertTrue(StaleFrameDetector.showsPreviousValue(
            observed: "swipe=left", expected: "swipe=right", previous: "swipe=left"))
    }

    func testOneCharMisreadOfPreviousStillStale() {
        XCTAssertTrue(StaleFrameDetector.showsPreviousValue(
            observed: "zoom=1.8x", expected: "zoom=0.5x", previous: "zoom=1.8x "))
    }

    func testUnrelatedTextIsNotStale() {
        XCTAssertFalse(StaleFrameDetector.showsPreviousValue(
            observed: "hello", expected: "swipe=right", previous: "swipe=left"))
    }

    func testNoPreviousIsNotStale() {
        XCTAssertFalse(StaleFrameDetector.showsPreviousValue(
            observed: "swipe=left", expected: "swipe=right", previous: nil))
    }

    func testPreviousEqualToExpectedIsNotStale() {
        XCTAssertFalse(StaleFrameDetector.showsPreviousValue(
            observed: "swipe=left", expected: "swipe=left", previous: "swipe=left"))
    }

    func testEmptyObservedIsNotStale() {
        XCTAssertFalse(StaleFrameDetector.showsPreviousValue(
            observed: "", expected: "swipe=right", previous: "swipe=left"))
    }
}
