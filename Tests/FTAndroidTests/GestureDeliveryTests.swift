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

    /// up が届かず指が残った事実を応答に載せる(届いた回は載せない)
    func testUnreleasedFingerIsStatedInTheDetail() async throws {
        let stuck = try await EmulatorControl.delivery {
            throw EmulatorGrpcSession.GestureInterrupted(cause: SendFailure(), fingerReleased: false)
        }
        guard case .deliveryUnknown(let detail) = stuck else { return XCTFail("\(stuck)") }
        XCTAssertTrue(detail.contains("finger may still be pressed"), detail)
        let released = try await EmulatorControl.delivery {
            throw EmulatorGrpcSession.GestureInterrupted(cause: SendFailure(), fingerReleased: true)
        }
        guard case .deliveryUnknown(let detail2) = released else { return XCTFail("\(released)") }
        XCTAssertFalse(detail2.contains("finger"), detail2)
    }

    func testInterruptedByCancellationRethrows() async {
        do {
            _ = try await EmulatorControl.delivery {
                throw EmulatorGrpcSession.GestureInterrupted(cause: CancellationError(), fingerReleased: false)
            }
            XCTFail("投げ直すはず")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    }

    /// ソース走査: 座標の drag / long-press は gRPC の前に端末の応答を確かめ、adb の swipe を協調プールに載せない(探索 b F2)
    func testCoordinateGesturesGateOnDeviceAnswerAndLeaveThePool() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FTAndroid/AndroidDriver.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for signature in ["public func drag(fromX", "public func press(x: Double, y: Double, duration: Double)"] {
            let start = try XCTUnwrap(source.range(of: signature), signature)
            let body = String(source[start.lowerBound...].prefix(2500))
            let end = body.range(of: "\n    }\n")?.lowerBound ?? body.endIndex
            let region = String(body[..<end])
            guard let gate = region.range(of: "requireDeviceAnswersOffPool()"),
                  let grpc = region.range(of: "EmulatorControl.") else { return XCTFail("\(signature): 門か gRPC が見当たらない") }
            XCTAssertTrue(gate.lowerBound < grpc.lowerBound, "\(signature): 門が gRPC より後ろにある")
            XCTAssertTrue(region.contains("offCooperativePool"), "\(signature): adb の swipe が協調プール上")
            XCTAssertFalse(region.contains("try adb(["), "\(signature): 同期の adb を直に撃っている")
        }
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
            guard case DriverError.deliveryUnknown(_, let detail) = error else { return XCTFail("\(error)") }
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
