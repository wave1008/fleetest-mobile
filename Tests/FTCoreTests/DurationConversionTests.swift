import XCTest
@testable import FTCore

final class DurationConversionTests: XCTestCase {
    func testMillisecondsTruncate() {
        XCTAssertEqual(continuousClockMilliseconds(.milliseconds(1500)), 1500)
        XCTAssertEqual(continuousClockMilliseconds(.microseconds(1999)), 1)
        XCTAssertEqual(continuousClockMilliseconds(.zero), 0)
        XCTAssertEqual(continuousClockMilliseconds(.seconds(3) + .microseconds(1)), 3000)
    }

    func testSecondsKeepTheFraction() {
        XCTAssertEqual(durationSeconds(.milliseconds(1500)), 1.5, accuracy: 1e-9)
        XCTAssertEqual(durationSeconds(.zero), 0)
    }

    /// 既定を固定する(`FocusWait` から分けたので、片方を変えても他方は変わらない)
    func testKeyboardGoneRereadIntervalIsPinned() {
        XCTAssertEqual(KeyboardWait.goneRereadSeconds, 0.15)
    }

    /// 期限切れは呼び手の値・先に終われば op の値(録画の待ちの形)
    func testDeadlineRaceReturnsTheCallersTimeoutValue() async {
        let late: Int = await DeadlineRace.first(seconds: 0.01, onTimeout: -1) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return 1
        }
        XCTAssertEqual(late, -1)
        let early: Int = await DeadlineRace.first(seconds: 5, onTimeout: -1) { 1 }
        XCTAssertEqual(early, 1)
    }
}
