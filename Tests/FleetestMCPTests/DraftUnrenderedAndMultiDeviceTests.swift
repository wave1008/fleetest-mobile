// ft_draft_scenario が、DSL の行にならない手(launch / activate)と別デバイスの手を黙って落とさない/混ぜないことの固定。
// 台本は実際の記録の形(SessionTools の ft_launch が書く Entry)と同じ。

import XCTest
import FTCore
@testable import fleetest_mcp

final class DraftUnrenderedAndMultiDeviceTests: XCTestCase {

    private func server() -> MCPServer {
        let fake = FakeDriver()
        let server = MCPServer(write: { _ in }, makeDriver: { _ in fake }, recordSnapshot: { _, _, _ in })
        server.settleWaitSeconds = 0
        return server
    }

    private func step(_ action: String, _ id: String, device: String?) -> InteractionLog.Entry {
        var flowStep = FlowStep(action: action)
        flowStep.locator = FTSelector.parse(id).primary
        return InteractionLog.Entry(step: flowStep, unresolved: nil, summary: "\(action) \"\(id)\"", deviceKey: device)
    }

    private func launch(_ bundleID: String, resume: Bool, device: String?) -> InteractionLog.Entry {
        InteractionLog.Entry(step: nil, unresolved: nil, isLaunch: !resume, bundleID: bundleID, platform: "ios",
                             summary: resume ? "activate \(bundleID) (resumed, not relaunched)" : "launch \(bundleID)",
                             deviceKey: device)
    }

    private func draft(_ server: MCPServer, _ args: [String: Any] = [:]) async throws -> String {
        try await server.call(tool: "ft_draft_scenario", args: args)
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    func testResumeLeavesATodoAtItsPosition() async throws {
        let server = server()
        server.interactions.record(launch("com.example.app", resume: false, device: "d1"))
        server.interactions.record(step("tap", "#a", device: "d1"))
        server.interactions.record(launch("com.example.app", resume: true, device: "d1"))
        server.interactions.record(step("tap", "#b", device: "d1"))
        let text = try await draft(server)
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let todo = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("// TODO: the exploration brought com.example.app") }, text)
        XCTAssertEqual(lines.firstIndex { $0.hasPrefix("tap(\"#a\"") }.map { $0 < todo }, true, text)
        XCTAssertEqual(lines.firstIndex { $0.hasPrefix("tap(\"#b\"") }.map { $0 > todo }, true, text)
    }

    func testMidwayRelaunchAndAnotherAppAreNotSilentlyDropped() async throws {
        let server = server()
        server.interactions.record(launch("com.example.app", resume: false, device: "d1"))
        server.interactions.record(step("tap", "#a", device: "d1"))
        server.interactions.record(launch("com.other.app", resume: false, device: "d1"))
        server.interactions.record(step("tap", "#b", device: "d1"))
        let text = try await draft(server, ["all": true])
        XCTAssertTrue(text.contains("restartApp(\"com.other.app\")"), text)
        XCTAssertTrue(text.contains("launch 2 different apps"), text)
        // 先頭の launch は condition の launchApp() が担う = TODO を足さない
        XCTAssertEqual(text.components(separatedBy: "launched the app again here").count - 1, 1, text)
    }

    func testOtherDevicesAreLeftOutAndSaid() async throws {
        let server = server()
        server.interactions.record(launch("com.example.app", resume: false, device: "direct:android:0:A"))
        server.interactions.record(step("tap", "#on_a", device: "direct:android:0:A"))
        server.interactions.record(step("tap", "#on_b", device: "direct:android:0:B"))
        let text = try await draft(server)
        XCTAssertTrue(text.contains("tap(\"#on_b\""), text)
        XCTAssertFalse(text.contains("#on_a\""), text)
        XCTAssertTrue(text.contains("covers only the device you drove last (direct:android:0:B)"), text)
        XCTAssertTrue(text.contains("direct:android:0:A"), text)
    }

    /// その台で launch していなければ、別の台のアプリ・OS で下書きを作らない(target の最後の引き先も台で絞る)
    func testTargetDoesNotComeFromAnotherDevice() async throws {
        let server = server()
        server.interactions.record(InteractionLog.Entry(step: nil, unresolved: nil, isLaunch: true,
                                                        bundleID: "com.android.only", platform: "android",
                                                        summary: "launch com.android.only", deviceKey: "direct:android:0:A"))
        server.interactions.record(step("tap", "#on_ios", device: "direct:ios:8123"))
        let text = try await draft(server)
        XCTAssertTrue(text.contains("tap(\"#on_ios\""), text)
        XCTAssertFalse(text.contains("com.android.only"), text)
        XCTAssertFalse(text.contains("platform: \"android\""), text)
    }

    /// ft_batch の irregularHandler の宣言は宣言した台の印を持つ(印が無いと別の台の下書きに入り、別の台の同じ宣言が
    /// この台の宣言を重複として落とす)
    func testIrregularHandlerDeclarationStaysOnItsDevice() async throws {
        let server = server()
        let declare = "irregularHandler '#popup' dismiss: '#close'"
        _ = try await server.call(tool: "ft_batch", args: ["platform": "android", "serial": "A", "steps": declare])
        _ = try await server.call(tool: "ft_batch", args: ["platform": "android", "serial": "B", "steps": declare])
        let handlers = server.interactions.entries.filter { $0.step?.action == "irregularHandler" }
        XCTAssertEqual(Set(handlers.compactMap(\.deviceKey)), ["android:A", "android:B"],
                       "\(handlers.map { $0.deviceKey ?? "nil" })")
    }

    /// terminate の後の「前面に来たアプリ」の注記は、そのデバイスで操作したアプリのときだけ(別の台の記録を数えない)
    func testFrontAppNoteCountsOnlyThisDevicesRecords() {
        let server = server()
        let a: [String: Any] = ["platform": "android", "serial": "A"]
        let b: [String: Any] = ["platform": "android", "serial": "B"]
        server.interactions.record(InteractionLog.Entry(step: nil, unresolved: nil, isLaunch: true, bundleID: "com.x",
                                                        platform: "android", summary: "launch com.x",
                                                        deviceKey: server.draftDeviceKey(a)))
        XCTAssertTrue(server.appWasDrivenOnThisDevice("com.x", args: a))
        XCTAssertFalse(server.appWasDrivenOnThisDevice("com.x", args: b))
    }

    /// 先に irregularHandler の宣言があっても、最初の launch は condition の launchApp() に写る = 「起動し直した」の TODO を出さない
    func testDeclarationBeforeTheFirstLaunchDoesNotMakeItARelaunch() async throws {
        let server = server()
        var declare = FlowStep(action: "irregularHandler")
        declare.locator = FTSelector.parse("#popup").primary
        server.interactions.record(InteractionLog.Entry(step: declare, unresolved: nil,
                                                        summary: "irregularHandler \"#popup\"", deviceKey: "d1"))
        server.interactions.record(launch("com.example.app", resume: false, device: "d1"))
        server.interactions.record(step("tap", "#a", device: "d1"))
        let text = try await draft(server, ["all": true])
        XCTAssertFalse(text.contains("launched the app again here"), text)
    }

    /// 範囲の先頭が resume(別のアプリの前面化)でも、対象アプリは最初の本当の launch から採る
    func testTargetPrefersTheFirstRealLaunchOverAResume() async throws {
        let server = server()
        server.interactions.record(launch("com.b", resume: true, device: "d1"))
        server.interactions.record(launch("com.a", resume: false, device: "d1"))
        server.interactions.record(step("tap", "#a", device: "d1"))
        let text = try await draft(server, ["all": true])
        XCTAssertFalse(text.contains("restartApp(\"com.a\")"), text)
        XCTAssertTrue(server.interactions.target(in: server.interactions.scope(all: true, device: "d1"), device: "d1").app
                      == "com.a", text)
    }

    /// 同じ iOS の台を profile: と udid: の両方で呼んでも、下書きは1台として扱う(sessionKey ではなく実体の udid で分ける)
    func testSameDeviceViaProfileAndUDIDIsOneDevice() {
        let server = server()
        let viaProfile: [String: Any] = ["profile": "ios-sim"]
        server.udids[MCPServer.sessionKey(viaProfile)] = "SIM-1"
        let viaUDID: [String: Any] = ["udid": "SIM-1"]
        XCTAssertNotEqual(MCPServer.sessionKey(viaProfile), MCPServer.sessionKey(viaUDID))
        XCTAssertEqual(server.draftDeviceKey(viaProfile), server.draftDeviceKey(viaUDID))
    }

    /// 警告に数えるのは範囲に入りえた手だけ(この台の直近の launch より前の別の台の手は、台で絞らなくても範囲の外)
    func testOtherDeviceStepsBeforeThisLaunchAreNotCounted() async throws {
        let server = server()
        server.interactions.record(step("tap", "#old", device: "dB"))
        server.interactions.record(launch("com.example.app", resume: false, device: "dA"))
        server.interactions.record(step("tap", "#a", device: "dA"))
        let scoped = try await draft(server)
        XCTAssertFalse(scoped.contains("were left out"), scoped)
        let all = try await draft(server, ["all": true])
        XCTAssertTrue(all.contains("1 recorded interaction(s) on other device(s)"), all)
    }

    /// SpringBoard への ft_launch は attach = 下書きの対象アプリにも起動の起点にもしない(アラートを閉じに行った手が対象を奪わない)
    func testSpringBoardAttachIsNotTheDraftTarget() async throws {
        let server = server()
        server.interactions.record(launch("com.example.app", resume: false, device: "d1"))
        server.interactions.record(InteractionLog.Entry(step: nil, unresolved: nil, isLaunch: false,
                                                        bundleID: MCPServer.springboardBundleID, platform: "ios",
                                                        summary: "launch com.apple.springboard", deviceKey: "d1"))
        server.interactions.record(step("tap", "#allow", device: "d1"))
        let text = try await draft(server)
        XCTAssertTrue(text.contains("Draft for com.example.app"), text)
        XCTAssertTrue(text.contains("attached to SpringBoard"), text)
        XCTAssertFalse(text.contains("different apps"), "SpringBoard への attach を別のアプリの起動に数えた: \(text)")
        XCTAssertEqual(server.interactions.target(in: [server.interactions.entries[1]], device: "d1").app, "com.example.app")
    }

    /// resume で走っていたかを確かめられなかった回は、下書きの記録でも断定しない(返答と同じ)
    func testUncheckedResumeIsNotRecordedAsAResume() async throws {
        let server = server()
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": "com.example.app", "resume": true])
        let summary = server.interactions.entries.last?.summary ?? ""
        XCTAssertTrue(summary.contains("could not be checked"), summary)
    }

    /// ft_launch com.apple.springboard は起動の記録(isLaunch)を立てない
    func testSpringBoardLaunchIsRecordedAsAnAttach() async throws {
        let server = server()
        _ = try await server.call(tool: "ft_launch", args: ["bundleId": MCPServer.springboardBundleID])
        XCTAssertEqual(server.interactions.entries.last?.isLaunch, false)
    }

    func testSingleDeviceHasNoDeviceWarning() async throws {
        let server = server()
        server.interactions.record(launch("com.example.app", resume: false, device: "d1"))
        server.interactions.record(step("tap", "#a", device: "d1"))
        let text = try await draft(server)
        XCTAssertFalse(text.contains("covers only the device"), text)
    }

    func testRecordActionTagsTheSessionKey() {
        let server = server()
        let args: [String: Any] = ["platform": "android", "serial": "S1"]
        server.recordAction(InteractionLog.Entry(step: FlowStep(action: "home"), unresolved: nil, summary: "home"), args: args)
        XCTAssertEqual(server.interactions.entries.last?.deviceKey, server.draftDeviceKey(args))
        XCTAssertEqual(server.draftDeviceKey(args), "android:S1", "実体(serial)で鍵を作る")
    }
}
