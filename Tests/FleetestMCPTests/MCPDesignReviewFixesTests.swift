// 2026-09-25 の DSL / MCP 設計レビューで直した口:
// ft_launch / ft_clear_input の snapshotAfter・ft_batch の scroll: / swipePointToPoint・
// セッション状態の一本化(forgetDeviceState がフラグ類も捨てる)

import XCTest
@testable import FTCore
@testable import fleetest_mcp

final class MCPDesignReviewFixesTests: XCTestCase {

    private var driver: FakeDriver!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        driver = FakeDriver()
        let fake = driver!
        server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
    }

    private func body(_ content: [[String: Any]]) -> String {
        content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    // MARK: - snapshotAfter

    func testLaunchWithSnapshotAfterReturnsTheTree() async throws {
        let text = body(try await server.call(
            tool: "ft_launch", args: ["bundleId": "com.example.app", "snapshotAfter": true]))
        XCTAssertTrue(text.hasPrefix("Launched: com.example.app"), text)
        XCTAssertTrue(text.contains("id=login_btn"), "木が付いていない: \(text)")
        XCTAssertEqual(driver.calls.filter { $0.hasPrefix("launch(") }.count, 1)
    }

    func testLaunchWithoutSnapshotAfterStaysTextOnly() async throws {
        let text = body(try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"]))
        XCTAssertFalse(text.contains("id=login_btn"), text)
    }

    func testClearInputWithSnapshotAfterReturnsTheTree() async throws {
        let text = body(try await server.call(tool: "ft_clear_input", args: ["snapshotAfter": true]))
        XCTAssertTrue(text.hasPrefix("clearInput sent"), text)
        XCTAssertTrue(text.contains("id=login_btn"), "木が付いていない: \(text)")
    }

    // MARK: - ft_batch の scroll: / swipePointToPoint

    func testBatchTapWithScrollSearchesAndDraftsTheSameLine() async throws {
        driver.changeTreeOnEveryTap()
        let text = body(try await server.call(
            tool: "ft_batch", args: ["steps": "tap '#login_btn' scroll: .down maxSwipes: 3"]))
        XCTAssertTrue(text.contains("All 1 step(s) passed"), text)
        let draft = body(try await server.call(tool: "ft_draft_scenario", args: ["all": true]))
        XCTAssertTrue(draft.contains("tap(\"#login_btn\", scroll: .down, maxSwipes: 3)"), draft)
    }

    func testBatchMaxSwipesWithoutScrollIsRefused() async {
        do {
            _ = try await server.call(tool: "ft_batch", args: ["steps": "tap '#login_btn' maxSwipes: 3"])
            XCTFail("scroll: の無い maxSwipes: が通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("scroll:"), error.localizedDescription)
        }
        XCTAssertEqual(driver.calls, [], "弾いた手はドライバへ触れないこと")
    }

    func testBatchScrollWithoutASelectorIsRefused() async {
        do {
            _ = try await server.call(tool: "ft_batch", args: ["steps": "type 'abc' scroll: .down"])
            XCTFail("セレクタ無しの scroll: が通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("needs a selector"), error.localizedDescription)
        }
    }

    func testBatchNoScrollIsTheSameAsOmitting() async throws {
        _ = try await server.call(tool: "ft_batch", args: ["steps": "tap '#login_btn' scroll: .noScroll"])
        let draft = body(try await server.call(tool: "ft_draft_scenario", args: ["all": true]))
        XCTAssertTrue(draft.contains("tap(\"#login_btn\")"), draft)
    }

    func testBatchRunsSwipePointToPoint() async throws {
        let text = body(try await server.call(
            tool: "ft_batch",
            args: ["steps": "swipePointToPoint startX: 200 startY: 550 endX: 200 endY: 250 durationSeconds: 0.3"]))
        XCTAssertTrue(text.contains("All 1 step(s) passed"), text)
        XCTAssertTrue(driver.calls.contains { $0.hasPrefix("drag(200.0,550.0->200.0,250.0") }, "\(driver.calls)")
    }

    /// 操作系の waitSeconds は値があれば必ず書き戻す(省略時は 5 秒ではなく約 0.7 秒なので、5 を省くと意味が変わる)。
    /// 往復テストは書き戻し同士を比べるので、両側で同じく落とすとこの誤りを見逃す = ここで直接見る
    func testActionWaitSecondsIsAlwaysWrittenBack() {
        let selector = FTSelector.parse("#a")
        for action in ["tap", "clearInput", "doubleTap"] {
            let line = ScenarioCodeGen.command(
                for: FlowStep(action: action, locator: selector.primary, timeout: 5)) ?? ""
            XCTAssertTrue(line.contains("waitSeconds: 5"), line)
        }
        let typed = ScenarioCodeGen.command(
            for: FlowStep(action: "type", locator: selector.primary, text: "x", timeout: 5)) ?? ""
        XCTAssertTrue(typed.contains("waitSeconds: 5"), typed)
    }

    // MARK: - 待ち上限は waitSeconds(DSL と同じ名前)

    /// 3経路とも渡した waitSeconds を読むこと。外れた回の文言に出る秒数で見る
    /// (別の名前を読むと既定の 5 秒に化け、文言は "5s" になる)
    func testFtSnapshotWaitForHonoursWaitSeconds() async throws {
        let text = body(try await server.call(
            tool: "ft_snapshot", args: ["waitFor": "#never_appears", "waitSeconds": 0.0]))
        XCTAssertTrue(text.contains("did not appear within 0s"), text)
    }

    func testSnapshotAfterWaitForHonoursWaitSeconds() async throws {
        let text = body(try await server.call(
            tool: "ft_tap", args: ["x": 1.0, "y": 2.0, "snapshotAfter": true,
                                   "waitFor": "#never_appears", "waitSeconds": 0.0]))
        XCTAssertTrue(text.contains("did not appear within 0s"), text)
    }

    func testWaitForChangeHonoursWaitSeconds() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = body(try await server.call(
            tool: "ft_tap", args: ["x": 1.0, "y": 2.0, "snapshotAfter": true,
                                   "waitForChange": true, "waitSeconds": 0.0]))
        XCTAssertTrue(text.contains("timed out after 0s"), text)
    }

    // MARK: - ft_hide_keyboard

    /// Android は戻るキー(ブリッジの hideKeyboard)を撃ち、下書きに DSL の1行が残る
    func testHideKeyboardRunsAndIsDraftedAsADSLLine() async throws {
        server.bridges[MCPServer.sessionKey([:])] = "android"
        let text = body(try await server.call(tool: "ft_hide_keyboard", args: ["snapshotAfter": true]))
        XCTAssertTrue(text.hasPrefix("hideKeyboard sent."), text)
        XCTAssertTrue(text.contains("id=login_btn"), "木が付いていない: \(text)")
        XCTAssertTrue(driver.calls.contains("hideKeyboard"), "\(driver.calls)")
        let draft = body(try await server.call(tool: "ft_draft_scenario", args: ["all": true]))
        XCTAssertTrue(draft.contains("hideKeyboard()"), draft)
    }

    /// Android でもキーボードが出ていない(ドライバが確かめて送らなかった)なら、iOS と同じ答えにし、下書きにも残さない
    func testHideKeyboardOnAndroidWithNoKeyboardSendsNothing() async throws {
        server.bridges[MCPServer.sessionKey([:])] = "android"
        driver.keyboardShownForHide = false
        let text = body(try await server.call(tool: "ft_hide_keyboard", args: [:]))
        XCTAssertTrue(text.hasPrefix("The keyboard was not shown; nothing was sent."), text)
        XCTAssertFalse(driver.calls.contains("hideKeyboard"), "\(driver.calls)")
        let draft = body(try await server.call(tool: "ft_draft_scenario", args: ["all": true]))
        XCTAssertFalse(draft.contains("hideKeyboard()"), draft)
    }

    /// Android は送らなかった回も、木からキーボードが消えるのを待つ(dumpsys は閉じても木は数秒残す)= 木を読みに行く
    func testHideKeyboardWithNoKeyboardStillWaitsForTheTreeOnAndroid() async throws {
        server.bridges[MCPServer.sessionKey([:])] = "android"
        driver.keyboardShownForHide = false
        let before = driver.calls.count
        _ = try await server.call(tool: "ft_hide_keyboard", args: [:])
        XCTAssertTrue(driver.calls.dropFirst(before).contains("snapshot"), "\(driver.calls)")
    }

    /// ft_launch は waitForChange を持たない = waitFor が外れても waitForChange を勧めない(持つツールでは従来どおり勧める)
    func testLaunchWaitMissDoesNotSuggestAnArgumentItLacks() async throws {
        let text = body(try await server.call(tool: "ft_launch", args: [
            "bundleId": "com.example.app", "snapshotAfter": true, "waitFor": "#never_there",
            "waitSeconds": MCPServer.waitForQuietCutoffSeconds + 2]))
        // 画面が静かなまま待ちを早く打ち切った回(案内が出る経路)を通す
        XCTAssertTrue(text.contains("the wait stopped after"), text)
        XCTAssertFalse(text.contains("wait with waitForChange: true"), text)
        XCTAssertTrue(MCPServer.toolDeclares("waitForChange", tool: "ft_tap"))
        XCTAssertFalse(MCPServer.toolDeclares("waitForChange", tool: "ft_launch"))
    }

    /// SpringBoard への resume は attach するだけ = 「起動し直したかもしれない」と言わない
    func testSpringBoardResumeDoesNotWarnAboutAFreshStart() async throws {
        let text = body(try await server.call(tool: "ft_launch",
                                              args: ["bundleId": MCPServer.springboardBundleID, "resume": true]))
        XCTAssertTrue(text.contains("Activated: com.apple.springboard"), text)
        XCTAssertFalse(text.contains("could not check"), text)
    }

    /// 何も送らなかった回は操作前の木と比べない(比べると「操作が効かなかったかも」と矛盾する注記が並ぶ)
    func testHideKeyboardWithNoKeyboardDoesNotClaimTheActionMissed() async throws {
        server.bridges[MCPServer.sessionKey([:])] = "android"
        driver.keyboardShownForHide = false
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        let text = body(try await server.call(tool: "ft_hide_keyboard", args: ["snapshotAfter": true]))
        XCTAssertTrue(text.hasPrefix("The keyboard was not shown; nothing was sent."), text)
        XCTAssertFalse(text.contains("looked unchanged"), text)
    }

    /// ft_terminate の 409(セッションが無い = アプリは既に落ちている)は起動の記録も消す。次の ft_terminate は同じ文を繰り返さない
    func testTerminateNoSessionForgetsTheLaunch() async throws {
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        driver.terminateError = DriverError.badResponse(status: 409, body: "no session")
        do { _ = try await server.call(tool: "ft_terminate", args: [:]); XCTFail("409 は断るべき") } catch {}
        do {
            _ = try await server.call(tool: "ft_terminate", args: [:])
            XCTFail("起動の記録が残っている")
        } catch {
            XCTAssertTrue("\(error)".contains("no known target to terminate"), "\(error)")
        }
    }

    /// シミュレータでは、ランナーが 409(セッションが無い)を返してもアプリは生きていうるので simctl で止めて確かめ、成功として返す
    func testTerminateNoSessionOnASimulatorStopsTheAppDirectly() async throws {
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        server.udids[MCPServer.sessionKey([:])] = "SIM-UDID"
        server.isSimulatorUDID = { $0 == "SIM-UDID" }
        let stopped = LockedValue<[String]>([])
        server.stopAppOnSimulator = { bundleID, udid in stopped.withLock { $0.append("\(bundleID)@\(udid)") } }
        driver.terminateError = DriverError.badResponse(status: 409, body: "no session")
        let text = body(try await server.call(tool: "ft_terminate", args: [:]))
        XCTAssertTrue(text.hasPrefix("Terminated com.example.app"), text)
        XCTAssertTrue(text.contains("stopped on the simulator directly"), text)
        XCTAssertEqual(stopped.value, ["com.example.app@SIM-UDID"])
    }

    /// セッションで起動していないアプリでも、409 を simctl で止めた回は止まったことを確かめている = 未確認の文面にしない
    func testTerminateNoSessionWithoutALaunchStillSaysTerminated() async throws {
        _ = try await server.call(tool: "ft_snapshot", args: [:])
        server.udids[MCPServer.sessionKey([:])] = "SIM-UDID"
        server.isSimulatorUDID = { $0 == "SIM-UDID" }
        server.stopAppOnSimulator = { _, _ in }
        driver.terminateError = DriverError.badResponse(status: 409, body: "no session")
        let text = body(try await server.call(tool: "ft_terminate", args: ["bundleId": "com.example.app"]))
        XCTAssertTrue(text.hasPrefix("Terminated com.example.app"), text)
        XCTAssertFalse(text.contains("nothing about the result is checked"), text)
    }

    /// 実機は止まったことを確かめる手段が無いので、409 は断る(simctl へは回さない)
    func testTerminateNoSessionOnAPhysicalDeviceIsRefused() async throws {
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app"])
        server.udids[MCPServer.sessionKey([:])] = "PHYS-UDID"
        server.isSimulatorUDID = { _ in false }
        let stopped = LockedValue(0)
        server.stopAppOnSimulator = { _, _ in stopped.withLock { $0 += 1 } }
        driver.terminateError = DriverError.badResponse(status: 409, body: "no session")
        do {
            _ = try await server.call(tool: "ft_terminate", args: [:])
            XCTFail("実機の 409 は断るべき")
        } catch {
            XCTAssertTrue("\(error)".contains("may have crashed"), "\(error)")
        }
        XCTAssertEqual(stopped.value, 0)
    }

    /// ft_batch の hideKeyboard も、何も送らなかった回は ft_hide_keyboard と同じく「送らなかった」と言い、下書きに残さない
    func testBatchHideKeyboardWithNoKeyboardIsNotDrafted() async throws {
        server.bridges[MCPServer.sessionKey([:])] = "android"
        driver.keyboardShownForHide = false
        let text = body(try await server.call(tool: "ft_batch", args: ["steps": "hideKeyboard"]))
        XCTAssertTrue(text.contains("the keyboard was not shown; nothing was sent"), text)
        let draft = body(try await server.call(tool: "ft_draft_scenario", args: ["all": true]))
        XCTAssertFalse(draft.contains("hideKeyboard()"), draft)
    }

    /// iOS は背景を叩き、閉じなければ **Enter を送らずに**断る(エージェントが「閉じたい」だけで送信・検索を起こさない)。
    /// 代わりの手(ft_type pressEnter)と、その副作用を名指しする。下書きにも残さない
    func testHideKeyboardOnIOSDoesNotSendEnterWhenTappingDoesNotCloseIt() async throws {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        let title = ElementInfo(ref: 1, type: "staticText", identifier: "title", label: "見出し", value: nil,
                                placeholder: nil, enabled: true, frame: FTRect(x: 20, y: 60, width: 200, height: 30),
                                depth: 0)
        var withKeyboard = SnapshotResponse(sessionBundleID: "com.example.app", screen: screen,
                                            elements: [title], truncatedCount: 0)
        withKeyboard.keyboardFrame = FTRect(x: 0, y: 500, width: 400, height: 300)
        driver.snapshotResponse = withKeyboard
        do {
            _ = try await server.call(tool: "ft_hide_keyboard", args: [:])
            XCTFail("閉じないのに通った")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Enter was not sent"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("pressEnter"), error.localizedDescription)
        }
        XCTAssertTrue(driver.calls.contains { $0.hasPrefix("tap(x:") }, "背景を叩いていない: \(driver.calls)")
        XCTAssertFalse(driver.calls.contains("pressEnter"), "Enter を送った: \(driver.calls)")
        let draft = body(try await server.call(tool: "ft_draft_scenario", args: ["all": true]))
        XCTAssertFalse(draft.contains("hideKeyboard()"), draft)
    }

    /// 木がキーボードを申告しなくなるまで待つ(Android では executor の後続待ちが1回の呼び出しで捨てられるため)
    func testAwaitKeyboardLeftTreeWaitsUntilTheKeyboardIsGone() async throws {
        let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
        var withKeyboard = SnapshotResponse(sessionBundleID: "com.example.app", screen: screen,
                                            elements: [], truncatedCount: 0)
        withKeyboard.keyboardFrame = FTRect(x: 0, y: 500, width: 400, height: 300)
        let gone = SnapshotResponse(sessionBundleID: "com.example.app", screen: screen,
                                    elements: [], truncatedCount: 0)
        driver.scriptedSnapshots = [withKeyboard, withKeyboard, gone]
        let note = await server.awaitKeyboardLeftTree(driver)
        XCTAssertEqual(note, "")
        XCTAssertEqual(driver.calls.filter { $0.hasPrefix("snapshot") }.count, 3, "\(driver.calls)")
    }

    // MARK: - セッション状態

    /// 束ねる前は Set<String> の2つが forgetDeviceState の外にあった(前の機の状態が残っていた)
    func testForgetDeviceStateAlsoDropsTheFlags() {
        let key = MCPServer.sessionKey([:])
        server.backgroundedByNavigate.insert(key)
        server.webPageCeilingLatched.insert(key)
        server.systemAlertProbePending.insert(key)
        server.forgetDeviceState(key)
        XCTAssertFalse(server.backgroundedByNavigate.contains(key))
        XCTAssertFalse(server.webPageCeilingLatched.contains(key))
        XCTAssertFalse(server.systemAlertProbePending.contains(key))
        XCTAssertNil(server.sessions[key])
    }
}
