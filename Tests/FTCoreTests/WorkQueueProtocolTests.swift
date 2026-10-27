import XCTest
@testable import FTCore

final class WorkQueueProtocolTests: XCTestCase {

    func testWantRoundTripAndExactWireForm() throws {
        let want = WorkQueueProtocol.Want(req: 7, lane: "iPhone 17", platform: "ios")
        let line = WorkQueueProtocol.encode(want)
        XCTAssertEqual(line, #"{"ftWork":{"lane":"iPhone 17","op":"want","platform":"ios","req":7}}"#)
        XCTAssertFalse(line.contains("\n"))
        XCTAssertEqual(WorkQueueProtocol.decodeWant(line), want)
    }

    func testReplyWithIDRoundTrip() {
        let reply = WorkQueueProtocol.Reply(req: 3, id: "Login.S0010")
        let line = WorkQueueProtocol.encode(reply)
        XCTAssertEqual(line, #"{"ftWork":{"id":"Login.S0010","req":3}}"#)
        let decoded = WorkQueueProtocol.decodeReply(line)
        XCTAssertEqual(decoded, reply)
        XCTAssertEqual(decoded?.scenarioID, "Login.S0010")
    }

    func testReplyNoneRoundTrip() {
        let reply = WorkQueueProtocol.Reply(req: 4, none: true)
        let line = WorkQueueProtocol.encode(reply)
        XCTAssertEqual(line, #"{"ftWork":{"none":true,"req":4}}"#)
        let decoded = WorkQueueProtocol.decodeReply(line)
        XCTAssertEqual(decoded, reply)
        XCTAssertNil(decoded?.scenarioID)
    }

    func testNonAsciiScenarioIDRoundTrips() {
        let reply = WorkQueueProtocol.Reply(req: 1, id: "ログイン.S0010")
        XCTAssertEqual(WorkQueueProtocol.decodeReply(WorkQueueProtocol.encode(reply)), reply)
    }

    func testDecodeToleratesTrailingCarriageReturn() {
        let line = WorkQueueProtocol.encode(WorkQueueProtocol.Reply(req: 2, none: true)) + "\r"
        XCTAssertNotNil(WorkQueueProtocol.decodeReply(line))
    }

    func testIsWorkLineAcceptsOnlyTheEnvelope() {
        XCTAssertTrue(WorkQueueProtocol.isWorkLine(#"{"ftWork":{"req":1,"none":true}}"#))
        XCTAssertFalse(WorkQueueProtocol.isWorkLine(#"{"kind":"step"}"#))
        XCTAssertFalse(WorkQueueProtocol.isWorkLine(#" {"ftWork":{}}"#))
        XCTAssertFalse(WorkQueueProtocol.isWorkLine("ftWork"))
        XCTAssertFalse(WorkQueueProtocol.isWorkLine(""))
    }

    func testRejectsOtherJSONAndMismatchedShapes() {
        XCTAssertNil(WorkQueueProtocol.decodeWant(#"{"kind":"step"}"#))
        XCTAssertNil(WorkQueueProtocol.decodeReply(#"{"kind":"step"}"#))
        XCTAssertNil(WorkQueueProtocol.decodeReply("not json"))
        // want の行は返事ではない・返事の行は want ではない
        let want = WorkQueueProtocol.encode(WorkQueueProtocol.Want(req: 1, lane: "a", platform: "ios"))
        let reply = WorkQueueProtocol.encode(WorkQueueProtocol.Reply(req: 1, id: "A.B"))
        XCTAssertNil(WorkQueueProtocol.decodeReply(want))
        XCTAssertNil(WorkQueueProtocol.decodeWant(reply))
        // 中身が id も none も持たない返事は返事として読まない
        XCTAssertNil(WorkQueueProtocol.decodeReply(#"{"ftWork":{"req":1}}"#))
        XCTAssertNil(WorkQueueProtocol.decodeReply(#"{"ftWork":{"req":1,"none":false}}"#))
    }
}
