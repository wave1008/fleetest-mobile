import XCTest
@testable import FTCore

final class DurationConversionTests: XCTestCase {
    func testMillisecondsTruncate() {
        XCTAssertEqual(DurationConversion.milliseconds(.milliseconds(1500)), 1500)
        XCTAssertEqual(DurationConversion.milliseconds(.microseconds(1999)), 1)
        XCTAssertEqual(DurationConversion.milliseconds(.zero), 0)
        XCTAssertEqual(DurationConversion.milliseconds(.seconds(3) + .microseconds(1)), 3000)
    }

    func testSecondsKeepTheFraction() {
        XCTAssertEqual(DurationConversion.seconds(.milliseconds(1500)), 1.5, accuracy: 1e-9)
        XCTAssertEqual(DurationConversion.seconds(.zero), 0)
    }
}
