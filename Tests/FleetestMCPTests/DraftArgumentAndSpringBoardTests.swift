// ft_draft_scenario の引数の検査・device 指定の文言・SpringBoard 上の tap・「効かなかった」警告つきの手の固定。

import XCTest
import FTCore
@testable import fleetest_mcp

final class DraftArgumentAndSpringBoardTests: XCTestCase {

    private func server() -> MCPServer {
        let fake = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
        return server
    }

    private func tap(_ id: String, device: String? = "ios:U1", warning: String? = nil) -> InteractionLog.Entry {
        var flowStep = FlowStep(action: "tap")
        flowStep.locator = FTSelector.parse(id).primary
        return InteractionLog.Entry(step: flowStep, unresolved: nil, summary: "tap \"\(id)\"",
                                    deviceKey: device, noEffectWarning: warning)
    }

    private func launch(_ bundleID: String, isLaunch: Bool = true, device: String? = "ios:U1") -> InteractionLog.Entry {
        InteractionLog.Entry(step: nil, unresolved: nil, isLaunch: isLaunch, bundleID: bundleID, platform: "ios",
                             summary: "launch \(bundleID)", deviceKey: device)
    }

    private func draft(_ server: MCPServer, _ args: [String: Any] = [:]) async throws -> String {
        try await server.call(tool: "ft_draft_scenario", args: args)
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    func testDropRangeUsesTheCountAfterLastN() async throws {
        let server = server()
        server.interactions.record(launch("com.example.app"))
        for index in 1...4 { server.interactions.record(tap("#b\(index)")) }
        let text = try await draft(server, ["lastN": 2, "drop": [3]])
        XCTAssertTrue(text.contains("out of range (1…2)"), text)
    }

    func testScenesOutOfRangeAndRepeatedAreReported() async throws {
        let server = server()
        server.interactions.record(launch("com.example.app"))
        server.interactions.record(tap("#a"))
        server.interactions.record(tap("#b"))
        let text = try await draft(server, ["scenes": [99, 2, 2]])
        XCTAssertTrue(text.contains("scenes 99, 2 is out of range"), text)
    }

    func testNamedDeviceIsNotCalledTheLastDriven() async throws {
        let server = server()
        server.interactions.record(launch("com.example.app", device: "ios:U1"))
        server.interactions.record(tap("#a", device: "ios:U1"))
        server.interactions.record(launch("com.example.app", device: "ios:U2"))
        server.interactions.record(tap("#b", device: "ios:U2"))
        let text = try await draft(server, ["device": "ios:U1"])
        XCTAssertTrue(text.contains("covers only the device you named (ios:U1)"), text)
        XCTAssertFalse(text.contains("you drove last"), text)
    }

    func testBareUdidResolvesToTheUniqueKey() async throws {
        let server = server()
        server.interactions.record(launch("com.example.app", device: "ios:U1"))
        server.interactions.record(tap("#a", device: "ios:U1"))
        server.interactions.record(tap("#b", device: "ios:U2"))
        let text = try await draft(server, ["device": "U1"])
        XCTAssertFalse(text.contains("No interactions recorded"), text)
        XCTAssertTrue(text.contains("tap(\"#a\""), text)
    }

    func testTapOnSpringBoardBecomesATapAppIconTodo() async throws {
        let server = server()
        server.interactions.record(launch("com.example.app"))
        server.interactions.record(launch(MCPServer.springboardBundleID, isLaunch: false))
        server.interactions.record(tap("#FT E2E RN"))
        let text = try await draft(server)
        XCTAssertTrue(text.contains("tapAppIcon(\"FT E2E RN\")"), text)
        XCTAssertFalse(text.contains("tap(\"#FT E2E RN\""), text)
    }

    /// 長押し(ref の ft_long_press は action "press" で記録される)も SpringBoard の上なら行にしない
    func testLongPressOnSpringBoardBecomesATodo() async throws {
        let server = server()
        server.interactions.record(launch("com.example.app"))
        server.interactions.record(launch(MCPServer.springboardBundleID, isLaunch: false))
        var entry = tap("#FT E2E RN")
        entry.step?.action = "press"
        server.interactions.record(entry)
        let text = try await draft(server)
        XCTAssertTrue(text.contains("tapAppIcon(\"FT E2E RN\")"), text)
        // 長押しの行の書式に依らず、TODO 以外の行にアイコンのセレクタが残らないこと
        let code = try XCTUnwrap(text.range(of: "import FTDSL").map { String(text[$0.lowerBound...]) }, text)
        XCTAssertFalse(code.split(separator: "\n").contains { !$0.contains("TODO") && $0.contains("#FT E2E RN") }, text)
    }

    func testNoEffectWarningLeavesATodoBeforeTheStep() async throws {
        let server = server()
        server.interactions.record(launch("com.example.app"))
        server.interactions.record(tap("#row", warning: "#row is disabled"))
        let text = try await draft(server)
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let todo = try XCTUnwrap(lines.firstIndex { $0.contains("the tool warned that this step probably did nothing") }, text)
        XCTAssertEqual(lines.firstIndex { $0.hasPrefix("tap(\"#row\"") }.map { $0 > todo }, true, text)
    }
}
