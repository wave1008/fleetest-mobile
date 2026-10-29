// MCP の全ツールを「下書き(ft_draft_scenario)に DSL の行を残す」か「残さない(理由つき)」かのどちらかに分類して固定する。
// ツールを足して記録を書き忘れると、DSL では書ける操作が下書きから黙って消える(ft_fold・ft_terminate・
// ft_clear_app_data が実際にそうだった)。**行を残すツールは実際に撃って下書きに行が出ることまで見る**
// (分類だけだと記録の呼び出しを消しても通る)。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPDraftCoverageTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        fresh()
    }

    /// ツールごとにまっさらなサーバー・ドライバで撃つ(記録が前のツールの行と混ざらないように)
    private func fresh() {
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake },
                           recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
    }

    /// 行を残すツール → (撃つ引数, 下書きに出るはずの行の先頭)。ft_launch は condition の `launchApp()` に固定で出るので、
    /// 記録されたことは手順の一覧の行(`1. launch …`)で見る
    private static var drafted: [String: (args: [String: Any], line: String)] { [
        "ft_launch": (["bundleId": "com.example.app"], "1. launch com.example.app"),
        "ft_tap": (["x": 120.0, "y": 640.0], "tap(x: 120, y: 640)"),
        "ft_long_press": (["x": 120.0, "y": 640.0, "holdSeconds": 2.0], "tap(x: 120, y: 640, holdSeconds: 2)"),
        "ft_double_tap": (["x": 120.0, "y": 640.0], "doubleTap(x: 120, y: 640)"),
        "ft_type": (["text": "hello"], "type(\"hello\")"),
        "ft_clear_input": ([:], "clearInput()"),
        "ft_swipe": (["finger": "up"], "swipe(.up)"),
        "ft_drag": (["fromX": 10.0, "fromY": 10.0, "toX": 10.0, "toY": 60.0], "swipePointToPoint("),
        "ft_pinch": (["scale": 2.0], "pinchOut("),
        "ft_gesture": (["fingers": [["x": 10.0, "y": 20.0,
                                     "steps": [["x": 15.0, "y": 20.0, "durationSeconds": 0.3]]]]], "gesture"),
        "ft_navigate": (["target": "home"], "home()"),
        "ft_hide_keyboard": ([:], "hideKeyboard()"),
        "ft_rotate": (["orientation": "landscape"], "rotateTo(.landscape)"),
        "ft_open_url": (["url": "myapp://x"], "openURL(\"myapp://x\")"),
        "ft_scroll_to": (["selector": "#login_btn"], "scrollTo(\"#login_btn\""),
        "ft_batch": (["steps": "tap x: 10 y: 20"], "tap(x: 10, y: 20)"),
        "ft_terminate": ([:], "terminateApp()"),
        "ft_clear_app_data": (["bundleId": "com.example.app"], "clearAppData(\"com.example.app\")"),
        // fold は Android の折りたたみ機の観測台本で撃つ(testFoldIsDrafted)。ここでは分類だけ
        "ft_fold": ([:], "fold()"),
    ] }

    /// 行を残さないツールと、その理由
    private static let notDrafted: [String: String] = [
        "ft_snapshot": "observation only",
        "ft_screenshot": "observation only",
        "ft_capture_element": "observation only (saves an image of an element)",
        "ft_status": "observation only",
        "ft_list_apps": "observation only",
        "ft_list_devices": "observation only",
        "ft_logs": "observation only",
        "ft_install": "environment setup before the explored flow, not one of its steps",
        "ft_doctor": "not a device operation",
        "ft_draft_scenario": "not a device operation (it is the draft itself)",
        "ft_dry_run": "not a device operation",
        "ft_dsl_commands": "not a device operation",
        "ft_list_projects": "not a device operation",
        "ft_list_scenarios": "not a device operation",
        "ft_run_scenario": "runs a scenario that is already written",
        "ft_start_run": "runs a scenario that is already written",
        "ft_run_status": "not a device operation",
        "ft_stop_run": "not a device operation",
        "ft_results": "not a device operation",
        "ft_services": "not a device operation (SUT servers)",
    ]

    func testEveryToolIsClassified() {
        let declared = Set(MCPServer.toolDefinitions.compactMap { $0["name"] as? String })
        let classified = Set(Self.drafted.keys).union(Self.notDrafted.keys)
        XCTAssertTrue(Set(Self.drafted.keys).isDisjoint(with: Self.notDrafted.keys))
        XCTAssertEqual(declared, classified,
                       "ツールを足したら、下書きに行を残すか(drafted)残さない理由(notDrafted)を決めて載せる")
    }

    func testEachDraftedToolLeavesItsLine() async throws {
        for (tool, entry) in Self.drafted.sorted(by: { $0.key < $1.key }) where tool != "ft_fold" {
            fresh()
            if tool != "ft_launch" {
                _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
            }
            // ft_scroll_to は木を読むので、探す対象を先に見せておく
            if tool == "ft_scroll_to" { _ = try await server.call(tool: "ft_snapshot", args: [:]) }
            // ft_hide_keyboard は何も送らなかった回(キーボードが出ていない)を下書きに残さない。偽ドライバの iOS の木には
            // キーボードが無いので、Android(偽ドライバの hideKeyboardIfShown は既定で「出ていた = 送った」)で撃つ
            if tool == "ft_hide_keyboard" { server.bridges[MCPServer.sessionKey([:])] = "android" }
            do {
                _ = try await server.call(tool: tool, args: entry.args)
            } catch {
                XCTFail("\(tool) failed: \(error.localizedDescription)")
                continue
            }
            // ft_clear_app_data / ft_terminate の後は「直近の ft_launch 以降」に入るよう all で全部出す
            let text = draft(try await server.call(tool: "ft_draft_scenario", args: ["all": true]))
            let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            XCTAssertTrue(lines.contains { $0.hasPrefix(entry.line) }, "\(tool) → \(entry.line) が無い:\n\(text)")
        }
    }

    func testFoldIsDrafted() async throws {
        driver.scriptedFoldObservations = [.state(.unfolded), .state(.folded)]
        _ = try await server.call(tool: "ft_launch", args: ["platform": "android", "bundleId": "com.example.app"])
        _ = try await server.call(tool: "ft_fold", args: ["platform": "android", "state": "fold"])
        let text = draft(try await server.call(tool: "ft_draft_scenario", args: ["platform": "android"]))
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(lines.contains(Self.drafted["ft_fold"]!.line), text)
    }

    private func draft(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}
