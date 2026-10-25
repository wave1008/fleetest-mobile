// 座標タップは下書き(`ft_draft_scenario`)でも**実行できる行**になること。
//
// `// TODO: no stable selector` へ落とさない —— 実測では操作可能要素の 9.3% が書けるセレクタを
// 持たないので、そこを TODO のままにすると**その画面を通るシナリオが再生できない**。
//
// **ただし用途で重みが違う**(ユーザー方針): 対話的な探索では座標のほうが速い
// ことがありそれでよいが、**シナリオに残す目的ではセレクタが最優先**。そこで行は出しつつ、
// 置き換えるべきであることを行末コメントに残す。

import XCTest
import FTCore
@testable import fleetest_mcp

final class MCPCoordinateDraftTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake },
                           recordSnapshot: { _, _, _ in })
    }

    private func bodyText(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    func testCoordinateTapBecomesARunnableLineWithAReplaceMeNote() async throws {
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        _ = try await server.call(tool: "ft_tap", args: ["x": 120.0, "y": 640.0])

        let text = bodyText(try await server.call(tool: "ft_draft_scenario", args: [:]))

        XCTAssertTrue(text.contains("tap(x: 120, y: 640)"), text)
        XCTAssertFalse(text.contains("TODO: no stable selector"),
                       "座標は書けるようになったので TODO へ落とさない: \(text)")
        // **セレクタ最優先の方針を行に残す**(テストを書く目的ではここが判断材料になる)
        XCTAssertTrue(text.contains("replace with a selector"), text)
    }

    /// ref で叩いた手は従来どおりセレクタ行(座標の導入で退行していないこと)
    func testRefTapStillBecomesASelectorLine() async throws {
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        _ = try await server.call(tool: "ft_tap", args: ["ref": 1])

        let text = bodyText(try await server.call(tool: "ft_draft_scenario", args: [:]))

        XCTAssertTrue(text.contains("tap(\"#login_btn\")"), text)
        XCTAssertFalse(text.contains("x:"), text)
    }

    /// 読んだ木で、押した点に書けるセレクタの要素があればその行(ライブ操作の操作記録と同じ `PointTarget`)。
    /// FakeDriver の `#login_btn` の枠は (10, 20, 100, 40)
    func testCoordinateTapOnANamedElementBecomesItsSelector() async throws {
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        _ = try await server.call(tool: "ft_tap", args: ["x": 60.0, "y": 40.0])
        _ = try await server.call(tool: "ft_long_press", args: ["x": 60.0, "y": 40.0, "holdSeconds": 2.0])
        _ = try await server.call(tool: "ft_double_tap", args: ["x": 60.0, "y": 40.0])

        let text = bodyText(try await server.call(tool: "ft_draft_scenario", args: [:]))

        XCTAssertTrue(text.contains("tap(\"#login_btn\")"), text)
        XCTAssertTrue(text.contains("tap(\"#login_btn\", holdSeconds: 2)"), text)
        XCTAssertTrue(text.contains("doubleTap(\"#login_btn\")"), text)
        XCTAssertFalse(text.contains("x: 60"), text)
    }

    private func draft(after calls: [(String, [String: Any])], platform: String? = nil) async throws -> String {
        let base: [String: Any] = platform.map { ["platform": $0] } ?? [:]
        _ = try await server.call(tool: "ft_launch", args: base.merging(["bundleId": "com.example.app"]) { $1 })
        for (tool, args) in calls { _ = try await server.call(tool: tool, args: args) }
        return bodyText(try await server.call(tool: "ft_draft_scenario", args: base))
    }

    /// 座標の長押しは TODO に落とさず `tap(x:y:holdSeconds:)` になる(置き換えの注記つき)
    func testCoordinateLongPressBecomesTapWithHoldSeconds() async throws {
        let text = try await draft(after: [("ft_long_press", ["x": 120.0, "y": 640.0, "holdSeconds": 2.0])])
        XCTAssertTrue(text.contains("tap(x: 120, y: 640, holdSeconds: 2)"), text)
        XCTAssertFalse(text.contains("TODO: no stable selector"), text)
        XCTAssertTrue(text.contains("replace with a selector"), text)
    }

    /// 座標の doubleTap は `doubleTap(x:y:)`
    func testCoordinateDoubleTapBecomesDoubleTapXY() async throws {
        let text = try await draft(after: [("ft_double_tap", ["x": 120.0, "y": 640.0])])
        XCTAssertTrue(text.contains("doubleTap(x: 120, y: 640)"), text)
        XCTAssertFalse(text.contains("TODO: no stable selector"), text)
        XCTAssertTrue(text.contains("replace with a selector"), text)
    }

    /// ft_fold の開閉・角度が下書きに残る
    func testFoldUnfoldAndHingeAreRecorded() async throws {
        driver.scriptedFoldObservations = [.state(.unfolded), .state(.folded), .state(.unfolded), .state(.unfolded)]
        server.settleWaitSeconds = 0
        let text = try await draft(after: [
            ("ft_fold", ["platform": "android", "state": "fold"]),
            ("ft_fold", ["platform": "android", "state": "unfold"]),
            ("ft_fold", ["platform": "android", "degrees": 130.0]),
        ], platform: "android")
        // 行単位で見る(`contains("fold()")` は `unfold()` にも当たる)
        let lines = Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        XCTAssertTrue(lines.contains("fold()"), text)
        XCTAssertTrue(lines.contains("unfold()"), text)
        XCTAssertTrue(lines.contains("hinge(130)"), text)
    }
}
