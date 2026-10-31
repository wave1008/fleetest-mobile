import XCTest
import FTCore
@testable import FTDSL

/// appIs の待ち: 読めない間は待ち続け(遷移の途中)、期限まで読めなければ「違う」でなく「読めなかった」と言う
final class AppIsForegroundPollTests: XCTestCase {
    func testKeepsPollingThroughAnUnreadableForeground() async throws {
        let calls = LockedValue(0)
        let matched = try await pollForegroundMatch(waitSeconds: 5) {
            let n = calls.withLock { $0 += 1; return $0 }
            if n == 1 { throw ForegroundUnreadable() }
            return true
        }
        XCTAssertTrue(matched)
        XCTAssertEqual(calls.withLock { $0 }, 2)
    }

    func testNeverReadableThrowsInsteadOfReportingNoMatch() async {
        do {
            _ = try await pollForegroundMatch(waitSeconds: 0) { throw ForegroundUnreadable() }
            XCTFail("投げるはず")
        } catch {
            XCTAssertEqual(error as? ForegroundUnreadable, ForegroundUnreadable())
        }
    }

    /// tapAppIcon: 読めないまま期限が来たら「前面に来なかった」(nil = 判定材料なしだと緑になる)
    func testArrivalCountsUnreadableAsNotForeground() async throws {
        let arrived = try await pollForegroundArrival(waitSeconds: 0) { throw ForegroundUnreadable() }
        XCTAssertEqual(arrived, false)
    }

    func testArrivalStaysUnknownWhenTheDriverNeverAnswers() async throws {
        struct NoAnswer: Error {}
        let arrived = try await pollForegroundArrival(waitSeconds: 0) { throw NoAnswer() }
        XCTAssertNil(arrived)
    }

    func testAnotherAppInFrontStaysFalse() async throws {
        let matched = try await pollForegroundMatch(waitSeconds: 0) { false }
        XCTAssertFalse(matched)
    }
}
