// ステップ実行器の期待(RefExpectationScope)が BridgeClient の最新の ref の表と食い違えば、要求を送らずに staleRef で断ることの固定。
// ブリッジへ添える expect は自分の表から作るので、ステップ実行器が古い木の ref を撃つ誤りはこの照合でしか断てない。

import XCTest
@testable import FTBridgeClient
import FTCore

final class BridgeClientStepExpectationTests: XCTestCase {

    /// ref 1 = button #send の木を撮らせてから、応答を OK へ戻す
    private func client() async throws -> (RecordingStubServer, BridgeClient) {
        let element = ElementInfo(ref: 1, type: "button", identifier: "send", label: "Send", value: nil,
                                  placeholder: nil, enabled: true,
                                  frame: FTRect(x: 10, y: 20, width: 100, height: 44), depth: 1)
        let snapshot = SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 390, height: 844),
                                        elements: [element], truncatedCount: 0)
        let stub = try RecordingStubServer(body: String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self))
        let client = BridgeClient(port: stub.port, timeoutSeconds: 5, token: "")
        _ = try await client.snapshot()
        stub.setBody(#"{"ok":true}"#)
        return (stub, client)
    }

    private func assertRefusedWithoutSending(_ path: String, _ stub: RecordingStubServer,
                                             _ body: () async throws -> Void) async {
        do {
            try await RefExpectationScope.$expected.withValue(RefExpectation(identifier: "cancel", type: "button")) {
                try await body()
            }
            XCTFail("\(path): 食い違う期待なのに断らなかった")
        } catch {
            guard case DriverError.staleRef? = error as? DriverError else {
                return XCTFail("\(path): staleRef になっていない: \(error)")
            }
        }
        XCTAssertFalse(stub.paths.contains(path), "\(path): 断ったのに要求を送った: \(stub.paths)")
    }

    func testContradictingExpectationIsRefusedBeforeSending() async throws {
        let (stub, client) = try await client()
        defer { stub.stop() }
        await assertRefusedWithoutSending("POST /tap", stub) { try await client.tap(ref: 1) }
        await assertRefusedWithoutSending("POST /press", stub) { try await client.press(ref: 1, duration: 0.5) }
        await assertRefusedWithoutSending("POST /type", stub) { try await client.type(ref: 1, text: "x") }
        await assertRefusedWithoutSending("POST /clear", stub) { try await client.clearInput(ref: 1) }
    }

    func testMatchingOrAbsentExpectationIsSent() async throws {
        let (stub, client) = try await client()
        defer { stub.stop() }
        try await RefExpectationScope.$expected.withValue(RefExpectation(identifier: "send", type: "button")) {
            try await client.tap(ref: 1)
        }
        XCTAssertTrue(stub.paths.contains("POST /tap"), "一致する期待なのに送っていない: \(stub.paths)")
        try await client.press(ref: 1, duration: 0.5)
        XCTAssertTrue(stub.paths.contains("POST /press"), "期待が無いのに送っていない: \(stub.paths)")
    }
}
