// 手動操作の CLI(tap / press)の数値は parse 時点(validate())で断る。CLI ファズで --x 1e400 が Swift の
// EncodingError("Unable to encode Double.inf directly in JSON")をそのまま出していた。press の上限は MCP と同じ

import XCTest
import ArgumentParser
import FTCore
@testable import fleetest

final class ManualDriveNumberBoundsTests: XCTestCase {

    func testTapRejectsANonFiniteCoordinate() {
        XCTAssertThrowsError(try Tap.parse(["--x", "1e400", "--y", "10"])) { error in
            let message = Tap.message(for: error)
            XCTAssertTrue(message.contains("--x must be a finite number"), message)
        }
        XCTAssertNoThrow(try Tap.parse(["--x", "10", "--y", "20"]))
    }

    func testPressRejectsAnOutOfRangeHold() {
        for bad in ["0", "-1", "1e400", "\(BridgeAPI.defaultMaxGestureSeconds + 1)"] {
            XCTAssertThrowsError(try Press.parse(["--ref", "1", "--hold-seconds=\(bad)"]), bad) { error in
                XCTAssertTrue(Press.message(for: error).contains("--hold-seconds must be greater than 0"), bad)
            }
        }
        XCTAssertNoThrow(try Press.parse(["--ref", "1", "--hold-seconds", "\(BridgeAPI.defaultMaxGestureSeconds)"]))
    }
}
