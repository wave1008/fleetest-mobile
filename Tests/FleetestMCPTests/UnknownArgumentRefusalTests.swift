// ft_type / ft_long_press は未知の引数があれば撃たずに断る(sim9 F6: `ft_type {selector: …, text: …}` が
// selector を落として焦点のある別の欄へ打ち、「ignored」と言いながら成功していた)。他のツールは注記して撃つ

import XCTest
import FTCore
@testable import fleetest_mcp

final class UnknownArgumentRefusalTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
    }

    func testTypeWithAnUnknownTargetArgumentIsRefusedBeforeTouchingTheDevice() async {
        do {
            _ = try await server.call(tool: "ft_type", args: ["selector": "#field_single", "text": "hi"])
            XCTFail("ft_type with an unknown argument must be refused")
        } catch {
            let message = "\(error)"
            XCTAssertTrue(message.contains("selector"), message)
            XCTAssertTrue(message.contains("nothing was sent"), message)
        }
        XCTAssertFalse(driver.calls.contains { $0.hasPrefix("type(") }, "the text must not reach the driver: \(driver.calls)")
    }

    func testOtherToolsStillOnlyNote() {
        XCTAssertNil(MCPServer.unknownArgumentRefusal(tool: "ft_status", args: ["thisArgumentDoesNotExist": 1]))
        XCTAssertNil(MCPServer.unknownArgumentRefusal(tool: "ft_type", args: ["text": "hi"]))
        XCTAssertNotNil(MCPServer.unknownArgumentRefusal(tool: "ft_long_press", args: ["x": 1, "y": 1, "durationSeconds": 2]))
    }
}
