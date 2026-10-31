// type + 末尾改行の Enter が失敗したとき、本文は打たれ済みであることを言う(言わないと type を撃ち直して二重に入れる)。

import XCTest
import FTCore
@testable import FTAndroid

final class EnterAfterTypedBodyTests: XCTestCase {
    private let context = DriverErrorContext(bridge: .android, physicalDevice: false)

    func testBadResponseSaysTheTextWasTyped() {
        let mapped = AndroidDriver.enterAfterTypedBody(.badResponse(status: 409, body: "no field has input focus"))
        guard case .badResponse(let status, let body) = mapped else { return XCTFail("\(mapped)") }
        XCTAssertEqual(status, 409)
        XCTAssertTrue(body.contains("already typed"), body)
        XCTAssertTrue(body.contains("no field has input focus"), body)
    }

    func testNotDeliveredEnterBecomesDeliveryUnknownBecauseTheBodyWasSent() {
        let mapped = AndroidDriver.enterAfterTypedBody(.notDelivered(context: context, detail: "offline"))
        guard case .deliveryUnknown(_, let detail) = mapped else { return XCTFail("\(mapped)") }
        XCTAssertTrue(detail.contains("already typed"), detail)
    }

    func testUnreachableKeepsItsCaseAndAddsTheSentence() {
        let mapped = AndroidDriver.enterAfterTypedBody(.bridgeUnreachable(context: context, detail: "cut"))
        guard case .bridgeUnreachable(_, let detail) = mapped else { return XCTFail("\(mapped)") }
        XCTAssertTrue(detail.contains("already typed"), detail)
    }

    func testStaleRefIsLeftAlone() {
        guard case .staleRef = AndroidDriver.enterAfterTypedBody(.staleRef(detail: "x")) else { return XCTFail() }
    }

    func testGestureFinishedUnknownIsDeliveryUnknownNotBridgeUnreachable() {
        XCTAssertThrowsError(try AndroidDriver.gestureFinished(.deliveryUnknown(detail: "x"), verb: "drag", context: context)) {
            guard case DriverError.deliveryUnknown = $0 else { return XCTFail("\($0)") }
        }
    }
}
