import XCTest
import FTCore
import FTEmulatorGrpc
@testable import FTAndroid

/// 途中で失敗した gRPC のジェスチャを adb で撃ち直さない(届いていれば二重に効く)・前面を読めないときに「前面でない」と答えない
final class GestureDeliveryTests: XCTestCase {
    private struct SendFailure: Error {}
    private let context = DriverErrorContext(bridge: .android, physicalDevice: false)

    func testSendFailureIsDeliveryUnknown() async throws {
        let outcome = try await EmulatorControl.delivery { throw SendFailure() }
        guard case .deliveryUnknown = outcome else { return XCTFail("\(outcome)") }
    }

    func testCompletedSendIsPerformed() async throws {
        let outcome = try await EmulatorControl.delivery {}
        XCTAssertEqual(outcome, .performed)
    }

    func testFailureBeforeAnyTouchIsNotSent() async throws {
        let outcome = try await EmulatorControl.delivery {
            throw EmulatorGrpcSession.GestureNotStarted(cause: SendFailure())
        }
        XCTAssertEqual(outcome, .notSent)
    }

    func testCancellationIsNotAGrpcFailure() async {
        do {
            _ = try await EmulatorControl.delivery { throw CancellationError() }
            XCTFail("投げ直すはず")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    /// 接続できない gRPC はタッチを1つも送っていない = adb で撃ってよい(接続の失敗がここで確定することの実地の確認)
    func testUnreachableControllerIsReportedAsNotStarted() async throws {
        let endpoint = EmulatorEndpoint(serial: "emulator-0", avdID: "x", grpcPort: 1, token: "x", pid: 0)
        for attempt in 0..<2 {
            do {
                if attempt == 0 {
                    try await EmulatorGrpcSession.drag(endpoint: endpoint, fromX: 0, fromY: 0, toX: 1, toY: 1, durationMs: 50)
                } else {
                    try await EmulatorGrpcSession.longPress(endpoint: endpoint, x: 0, y: 0, durationMs: 50)
                }
                XCTFail("接続できないはず")
            } catch {
                XCTAssertTrue(error is EmulatorGrpcSession.GestureNotStarted, "\(error)")
            }
        }
    }

    func testOnlyNotSentFallsBackToAdb() throws {
        XCTAssertFalse(try AndroidDriver.gestureFinished(.notSent, verb: "drag", context: context))
        XCTAssertTrue(try AndroidDriver.gestureFinished(.performed, verb: "drag", context: context))
    }

    func testDeliveryUnknownThrowsTheCaseThatCarriesTheNote() {
        XCTAssertThrowsError(try AndroidDriver.gestureFinished(.deliveryUnknown(detail: "x"), verb: "drag",
                                                               context: context)) { error in
            guard case DriverError.bridgeUnreachable(_, let detail) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("whether it was performed is unknown"), detail)
        }
    }

    func testUnreadableForegroundIsNotReportedAsAnotherApp() {
        XCTAssertThrowsError(try AndroidDriver.isForeground(bundleID: "a", front: nil)) { error in
            XCTAssertEqual(error as? ForegroundUnreadable, ForegroundUnreadable())
        }
        XCTAssertEqual(try AndroidDriver.isForeground(bundleID: "a", front: "a"), true)
        XCTAssertEqual(try AndroidDriver.isForeground(bundleID: "a", front: "b"), false)
    }
}
