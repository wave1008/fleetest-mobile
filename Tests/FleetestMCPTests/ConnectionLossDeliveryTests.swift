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
