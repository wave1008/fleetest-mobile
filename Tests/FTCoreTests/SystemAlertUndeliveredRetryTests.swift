import XCTest
@testable import FTCore

/// ステップ開始の確認の後に出たシステムアラートで、ブリッジが**届けずに**断った(`DriverError.systemAlertBlocked`)タップは、
/// 登録(iosAlertHandler)で閉じてから撃ち直す。届いたか分からない失敗(理由の無い 422)は撃ち直さない
final class SystemAlertUndeliveredRetryTests: XCTestCase {

    private func target() -> ElementInfo {
        ElementInfo(ref: 1, type: "button", identifier: "target", label: nil, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 0)
    }

    private func alertTree() -> [ElementInfo] {
        [ElementInfo(ref: 100, type: "alert", identifier: nil, label: "写真ライブラリへのアクセス", value: nil,
                     placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 0, width: 300, height: 200), depth: 0),
         ElementInfo(ref: 9, type: "button", identifier: nil, label: "許可しない", value: nil, placeholder: nil,
                     enabled: true, frame: FTRect(x: 0, y: 0, width: 10, height: 10), depth: 1)]
    }

    /// 開始の確認では居ない → 撃つと断られる → 閉じて(fallback.tap)撃ち直す
    private func make(refusal: Error, register: Bool) -> (StepExecutor, FakeAppDriver, CallLog) {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[target()]])
        primary.tapErrors = [refusal]
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [alertTree()])
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: false),
                                      SystemAlertProbeResponse(present: true, title: "写真ライブラリへのアクセス",
                                                               buttons: ["許可しない"]),
                                      SystemAlertProbeResponse(present: false)]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false, tunables: RunTunables())
        if register {
            executor.systemAlertWatchlist.register(SystemAlertRule(alert: "*写真ライブラリ*", button: "許可しない"))
        }
        return (executor, primary, log)
    }

    private let blocked = DriverError.systemAlertBlocked(detail: "a system alert is in front of the app")

    func testAnUndeliveredTapIsSentAgainAfterTheRegisteredAlertIsClosed() async {
        let (executor, _, log) = make(refusal: blocked, register: true)
        let outcome = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 5))
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "\(outcome.status)")
        XCTAssertEqual(log.entries.filter { $0.contains(".tap(") },
                       ["primary.tap(ref:1)", "fallback.tap(ref:9)", "primary.tap(ref:1)"],
                       "閉じてから撃ち直すこと: \(log.entries)")
        XCTAssertTrue(outcome.notes.contains(.systemAlertRetried), "\(outcome.notes)")
    }

    /// 登録が無ければ閉じない(撃ち直しもしない)。失敗の経路は覆い
    func testWithoutARegistrationItIsNeitherClosedNorSentAgain() async {
        let (executor, _, log) = make(refusal: blocked, register: false)
        let outcome = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 5))
        XCTAssertFalse(StepExecutor.isSuccess(outcome.status))
        XCTAssertEqual(outcome.failureKind, .systemUICovered)
        XCTAssertEqual(log.entries.filter { $0.contains(".tap(") }, ["primary.tap(ref:1)"], "\(log.entries)")
        XCTAssertFalse(outcome.notes.contains(.systemAlertRetried))
    }

    /// 登録のボタンがアラートに無く閉じられない回は、覆いで落ち、撃ち直しの注記を立てない(撃ち直していない)
    func testWhenTheAlertCannotBeClosedNoRetryIsRecorded() async {
        let log = CallLog()
        let primary = FakeAppDriver(name: "primary", log: log, snapshotElements: [[target()]])
        primary.tapErrors = [blocked]
        let fallback = FakeAppDriver(name: "fallback", log: log, snapshotElements: [alertTree()])
        // 開始の確認では居ない → 断られた後はずっと出ている(登録のボタンが無いので閉じられない)
        fallback.systemAlertFrames = [SystemAlertProbeResponse(present: false),
                                      SystemAlertProbeResponse(present: true, title: "写真ライブラリへのアクセス",
                                                               buttons: ["許可しない"])]
        let executor = StepExecutor(driver: primary, fallbackDriver: fallback, isAndroid: false, tunables: RunTunables())
        executor.systemAlertWatchlist.register(SystemAlertRule(alert: "*写真ライブラリ*", button: "Appの使用中は許可"))
        let outcome = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 1))
        XCTAssertFalse(StepExecutor.isSuccess(outcome.status))
        XCTAssertEqual(outcome.failureKind, .systemUICovered)
        XCTAssertFalse(outcome.notes.contains(.systemAlertRetried), "閉じられなかったのに撃ち直しを記録した")
        XCTAssertEqual(log.entries.filter { $0.hasPrefix("primary.tap") }, ["primary.tap(ref:1)"])
    }

    /// 理由の付かない 422(入力・ドラッグ等 = 途中まで届いたかもしれない)は、登録があっても撃ち直さない
    func testAnUnstructuredRefusalIsNotSentAgain() async {
        let (executor, _, log) = make(refusal: DriverError.badResponse(status: 422, body: "a system alert is in front"),
                                      register: true)
        let outcome = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "target"), timeout: 5))
        XCTAssertFalse(StepExecutor.isSuccess(outcome.status))
        XCTAssertEqual(log.entries.filter { $0.hasPrefix("primary.tap") }, ["primary.tap(ref:1)"], "\(log.entries)")
    }

    /// ブリッジの理由はクライアントで型へ写る(文言の一致で分岐しない)
    func testTheReasonRoundTrips() throws {
        let data = try JSONEncoder().encode(ErrorResponse(error: "x", reason: BridgeAPI.systemAlertBlockedReason))
        XCTAssertEqual(try JSONDecoder().decode(ErrorResponse.self, from: data).reason, "system-alert-blocked")
        XCTAssertEqual(DriverError.systemAlertBlocked(detail: "x").stepFailureKind, .systemUICovered)
    }
}

/// ランナー(SPM ターゲットではない)の配線をソース走査で固定する: 理由を付けるのは `/tap` だけ・付ける口は全部同じ関数を通る
final class SystemAlertUndeliveredRunnerWiringTests: XCTestCase {

    private func runnerSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Runner/FleetestRunnerUITests/\(name)"), encoding: .utf8)
    }

    func testOnlyTheTapRouteCarriesTheNotDeliveredReason() throws {
        let guardSource = try runnerSource("InterruptionGuard.swift")
        XCTAssertTrue(guardSource.contains(#"path == "/tap" ? BridgeAPI.systemAlertBlockedReason : nil"#))
        let router = try runnerSource("BridgeRouter.swift")
        // 監視(InterruptionGuard)が遮りを控えた 422 は3箇所。全部が要求の経路で理由を決める
        let monitored = router.components(separatedBy: "InterruptionGuard.message(blocked), status: 422").count - 1
        XCTAssertEqual(monitored, 3)
        XCTAssertEqual(router.components(separatedBy: "InterruptionGuard.notDeliveredReason(path: request.path)").count - 1, 4,
                       "監視の3箇所 + 撃つ前の門の断りの写し替え")
        let pinch = try runnerSource("CoordinatePinch.swift")
        XCTAssertTrue(pinch.contains("reason: BridgeAPI.systemAlertBlockedReason"), "撃つ前の門が理由を付けていない")
    }
}
