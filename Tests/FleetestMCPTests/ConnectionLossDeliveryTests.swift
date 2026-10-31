// 接続断の案内が「届いたか分からない」を言う・言わない分岐を、差し替えドライバ + `connectionFacts` で `call()` 経由に通す。
// (従来は `makeDriver` があると診断全体が止まり、iOS / Android の分岐が単体で一度も通らなかった)
// 言う: bridgeUnreachable(応答の途中で切れた)・deliveryUnknown(ブリッジ以外の理由で届いたか不明)。
// 言わない: bridgeConnectionRefused・notDelivered(送る前に断った = 何も送っていない)。

import XCTest
import FTCore
import FTBridgeClient
@testable import fleetest_mcp

final class ConnectionLossDeliveryTests: XCTestCase {

    private static let unknownPhrase = "unknown whether"
    private let androidContext = DriverErrorContext(bridge: .android, physicalDevice: false)
    private let iosContext = DriverErrorContext(bridge: .iosXCUITest, physicalDevice: false)

    private func facts(listening: Bool = true, ownerAlive: Bool? = nil,
                       probe: BridgeDiscovery.StatusProbe = .timedOut,
                       androidListed: [String]? = ["emulator-5554"],
                       running: [BridgeDiscovery.Found] = []) -> ConnectionFacts {
        ConnectionFacts(scan: { _ in running },
                        mayBeListening: { _, _ in listening },
                        ownerAlive: { _, _ in ownerAlive },
                        probeStatus: { _, _ in probe },
                        androidListed: { androidListed })
    }

    /// iOS(port 8100)。鍵は呼び出しの引数から本物の `sessionKey` で作る
    private func failingTapOnIOS(_ error: Error, facts: ConnectionFacts) async -> String {
        let driver = FakeDriver()
        driver.tapError = error
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        server.connectionFacts = facts
        let args: [String: Any] = ["port": 8100, "x": 10.0, "y": 20.0]
        let key = MCPServer.sessionKey(args)
        server.connections[key] = "port 8100"
        server.connectedPorts[key] = 8100
        return await message(of: server, tool: "ft_tap", args: args)
    }

    private func failingTapOnAndroid(_ error: Error, facts: ConnectionFacts) async -> String {
        let driver = FakeDriver()
        driver.tapError = error
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        server.connectionFacts = facts
        let args: [String: Any] = ["platform": "android", "serial": "emulator-5554", "x": 10.0, "y": 20.0]
        let key = MCPServer.sessionKey(args)
        server.connections[key] = "serial emulator-5554"
        server.connectedAndroidSerials[key] = "emulator-5554"
        return await message(of: server, tool: "ft_tap", args: args)
    }

    /// StepExecutor へ委ねた手も配達の案内を失わない(`MCPError` に畳むと案内が消える)
    func testAHideKeyboardThatLostTheConnectionKeepsTheDeliveryNote() async {
        let driver = FakeDriver()
        driver.hideKeyboardError = DriverError.bridgeUnreachable(context: androidContext, detail: "connection lost")
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        server.connectionFacts = facts()
        let args: [String: Any] = ["platform": "android", "serial": "emulator-5554"]
        let key = MCPServer.sessionKey(args)
        server.connections[key] = "serial emulator-5554"
        server.connectedAndroidSerials[key] = "emulator-5554"
        let text = await message(of: server, tool: "ft_hide_keyboard", args: args)
        XCTAssertTrue(text.contains("hideKeyboard failed: "), text)
        XCTAssertTrue(text.contains(Self.unknownPhrase), text)
    }

    func testExecutorFailureKeepsTheThrownDriverError() throws {
        let cause = DriverError.deliveryUnknown(context: androidContext, detail: "grpc")
        let kept = MCPServer.executorFailure(StepOutcome(status: .failed("x"), thrownDriverError: cause), prefix: "p: ", suffix: " s")
        let annotated = try XCTUnwrap(kept as? MCPAnnotatedError, "DriverError を畳んでいる")
        XCTAssertEqual(annotated.errorDescription, "p: x s")
        XCTAssertTrue(annotated.underlying is DriverError)
        XCTAssertTrue(MCPServer.executorFailure(StepOutcome(status: .failed("x"))) is MCPError)
    }

    /// 接続拒否は包まない(包むと接続の記憶が消え、次の呼び出しが起動し直せない)
    func testExecutorFailureLeavesARefusedConnectionForTheNextCall() {
        let refused = DriverError.bridgeConnectionRefused(context: iosContext, detail: "")
        XCTAssertTrue(MCPServer.executorFailure(StepOutcome(status: .failed("x"), thrownDriverError: refused)) is MCPError)
    }

    /// 接続断では閉じたかも分からないので、Enter を勧めない
    func testAHideKeyboardThatLostTheConnectionDoesNotSuggestEnter() async {
        let text = await failingHideKeyboardOnIOS(DriverError.bridgeUnreachable(context: iosContext, detail: "connection lost"))
        XCTAssertTrue(text.contains("hideKeyboard failed: "), text)
        XCTAssertFalse(text.contains("pressEnter"), text)
    }

    /// 3つの呼び手が全部 `executorFailure` を通る(戻すと配達の注記が黙って消える)
    func testEveryDelegatedGestureThrowsThroughExecutorFailure() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest-mcp/MCPServer+GesturesTools.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "throw Self.executorFailure(outcome").count - 1, 3)
        XCTAssertFalse(source.contains("throw MCPError(reason)"))
    }

    private func failingHideKeyboardOnIOS(_ error: Error) async -> String {
        let driver = FakeDriver()
        driver.tapError = error   // iOS はキーボードの外を叩いて閉じる
        driver.snapshotResponse.keyboardShown = true
        driver.snapshotResponse.keyboardFrame = FTRect(x: 0, y: 500, width: 390, height: 300)
        let server = MCPServer(write: { _ in }, makeDriver: { _ in driver }, recordSnapshot: { _, _, _ in })
        server.connectionFacts = facts()
        let args: [String: Any] = ["port": 8100]
        let key = MCPServer.sessionKey(args)
        server.connections[key] = "port 8100"
        server.connectedPorts[key] = 8100
        return await message(of: server, tool: "ft_hide_keyboard", args: args)
    }

    /// 全 case の表(`default` を置かない宣言と対で、配達の二値を等号で固定する)
    func testDeliveryIsUnknownForEveryCase() {
        let unknown: [DriverError] = [.bridgeUnreachable(context: androidContext, detail: ""), .deliveryUnknown(context: androidContext, detail: "")]
        let known: [DriverError] = [.bridgeConnectionRefused(context: androidContext, detail: ""), .badResponse(status: 500, body: ""),
                                    .bridgeIdentityMismatch(""), .staleRef(detail: ""), .systemAlertBlocked(detail: ""),
                                    .notDelivered(context: androidContext, detail: "")]
        XCTAssertTrue(unknown.allSatisfy(\.deliveryIsUnknown))
        XCTAssertFalse(known.contains(where: \.deliveryIsUnknown))
    }

    private func message(of server: MCPServer, tool: String, args: [String: Any]) async -> String {
        do {
            _ = try await server.call(tool: tool, args: args)
            XCTFail("失敗するはずの呼び出しが成功した")
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - iOS

    func testIOSRefusedSaysNothingListensAndNoDeliveryUnknown() async {
        let text = await failingTapOnIOS(
            DriverError.bridgeConnectionRefused(context: iosContext, detail: "refused"), facts: facts())
        XCTAssertTrue(text.contains("no longer listening"), text)
        XCTAssertFalse(text.contains(Self.unknownPhrase), text)
    }

    func testIOSUnreachableBusyKeepsTheConnectionAndWarnsAboutRepeating() async {
        let text = await failingTapOnIOS(
            DriverError.bridgeUnreachable(context: iosContext, detail: "timed out"),
            facts: facts(listening: true, probe: .timedOut))
        XCTAssertTrue(text.contains("likely busy"), text)
        XCTAssertTrue(text.contains("may already have been performed"), text)
    }

    func testIOSUnreachableWedgedSaysTheBridgeIsGone() async {
        let text = await failingTapOnIOS(
            DriverError.bridgeUnreachable(context: iosContext, detail: "cut"),
            facts: facts(listening: true, probe: .transportFailed))
        XCTAssertTrue(text.contains("failed almost immediately"), text)
        XCTAssertTrue(text.contains(Self.unknownPhrase), text)
    }

    func testIOSUnreachableVanishedSaysNoLongerListeningAndWarnsAboutRepeating() async {
        let text = await failingTapOnIOS(
            DriverError.bridgeUnreachable(context: iosContext, detail: "cut"),
            facts: facts(listening: false, running: []))
        XCTAssertTrue(text.contains("no longer listening"), text)
        XCTAssertTrue(text.contains(Self.unknownPhrase), text)
    }

    func testIOSDeliveryUnknownAddsTheNote() async {
        let text = await failingTapOnIOS(
            DriverError.deliveryUnknown(context: iosContext, detail: "x"), facts: facts())
        XCTAssertTrue(text.contains(Self.unknownPhrase), text)
    }

    func testIOSNotDeliveredAddsNoNote() async {
        let text = await failingTapOnIOS(
            DriverError.notDelivered(context: iosContext, detail: "x"), facts: facts())
        XCTAssertFalse(text.contains(Self.unknownPhrase), text)
    }

    // MARK: - Android

    func testAndroidUnreachableAndDeliveryUnknownWarn() async {
        let unreachable = await failingTapOnAndroid(
            DriverError.bridgeUnreachable(context: androidContext, detail: "cut"), facts: facts())
        XCTAssertTrue(unreachable.contains(Self.unknownPhrase), unreachable)
        let unknown = await failingTapOnAndroid(
            DriverError.deliveryUnknown(context: androidContext, detail: "grpc"), facts: facts())
        XCTAssertTrue(unknown.contains(Self.unknownPhrase), unknown)
    }

    func testAndroidNotDeliveredAndRefusedDoNotWarn() async {
        let notDelivered = await failingTapOnAndroid(
            DriverError.notDelivered(context: androidContext, detail: "adb forward failed"), facts: facts())
        XCTAssertFalse(notDelivered.contains(Self.unknownPhrase), notDelivered)
        XCTAssertTrue(notDelivered.contains("nothing was sent"), notDelivered)
        let refused = await failingTapOnAndroid(
            DriverError.bridgeConnectionRefused(context: androidContext, detail: "refused"), facts: facts())
        XCTAssertFalse(refused.contains(Self.unknownPhrase), refused)
    }

    func testAndroidDeviceGoneIsNamedAndNotDeliveredStillDoesNotWarn() async {
        let text = await failingTapOnAndroid(
            DriverError.notDelivered(context: androidContext, detail: "device offline"),
            facts: facts(androidListed: []))
        XCTAssertTrue(text.contains("no longer connected"), text)
        XCTAssertFalse(text.contains(Self.unknownPhrase), text)
    }

    func testAndroidUnreadableDeviceListDoesNotClaimTheDeviceIsGone() async {
        let text = await failingTapOnAndroid(
            DriverError.notDelivered(context: androidContext, detail: "x"), facts: facts(androidListed: nil))
        XCTAssertFalse(text.contains("no longer connected"), text)
    }

    // MARK: - DriverError の分類と文面

    func testFailureKindOfTheNewCases() {
        XCTAssertEqual(DriverError.notDelivered(context: androidContext, detail: "").stepFailureKind, .driverUnreachable)
        XCTAssertEqual(DriverError.deliveryUnknown(context: androidContext, detail: "").stepFailureKind, .driverError)
    }

    func testDescriptionsStateDeliveryFirstHand() {
        XCTAssertTrue((DriverError.notDelivered(context: androidContext, detail: "d").errorDescription ?? "")
            .contains("nothing was sent"))
        XCTAssertTrue((DriverError.deliveryUnknown(context: androidContext, detail: "d").errorDescription ?? "")
            .contains("unknown"))
    }

    func testAnnotatedErrorWithFullMessageReplacesTheUnderlyingText() {
        let error = MCPAnnotatedError(underlying: DriverError.notDelivered(context: androidContext, detail: "d"),
                                      suffix: "", fullMessage: "whole")
        XCTAssertEqual(error.localizedDescription, "whole")
    }
}
