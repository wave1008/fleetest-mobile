// ActionCountingDriver.swift
// シナリオ実行中にデバイスへ実際に送った操作の回数を数える AppDriver の包み(モニターの「アクション/秒」)。

import Foundation

/// 包みと親(ScenarioEvent.actions を作る側)が共有する数え箱。**1シナリオ実行(子プロセス)で1つ**。
public final class ActionCounter: Sendable {
    private let total = LockedValue<Int>(0)

    public init() {}

    public func increment() { total.withLock { $0 += 1 } }

    /// 前回の `take()` からの増分を返して 0 に戻す
    public func take() -> Int {
        total.withLock { value in
            let taken = value
            value = 0
            return taken
        }
    }
}

/// **数えるのは「画面へ入力を送る」操作が正常に返ったときだけ**(throw は数えない)。
/// 数える: tap(ref/x,y) / type / clearInput / hideKeyboard / pressEnter / swipe(2形) / drag / doubleTap / pinch / gesture /
/// press(2形) / hold / back / home / openAppSwitcher / launch / terminate / openURL / rotate / setHingeAngle。
/// 数えない: 読み取り(snapshot・hitTest・tapProbe・screenshot・status・systemAlert 等)・waitForSettle・応答計測・
/// ツール内部の向け直し(activate / attach)・install / uninstall / clearAppData / addMedia・設定(captureKeyboardState…・
/// raiseElementLimit…)・restoreOrientationIfNeeded・acknowledgeOpenURLConsentIfPresent・continueAfterFold。
/// 数える側は `counted { }` を通る行だけ(下の「数える操作」の節)。
///
/// **全要件を明示的に転送する**(要件に既定実装があるものも含む。書き漏らすと存在型越しの呼び出しが既定実装へ
/// 静的ディスパッチされ、中のドライバの実装が呼ばれない = `AppDriverDefaultDispatchTests`)。
/// **二重計上しない前提**: 1回の呼び出しはこの包みを1回だけ通る(内側のドライバ同士の委譲は包みを通らない)。
/// 包みは主ドライバ・fallback・typeDriver・homeScreenDriver をそれぞれ包むが、同じ `ActionCounter` を共有する
public final class ActionCountingDriver: AppDriver {
    private let base: AppDriver
    private let counter: ActionCounter

    public init(base: AppDriver, counter: ActionCounter) {
        self.base = base
        self.counter = counter
    }

    private func counted<T>(_ operation: () async throws -> T) async throws -> T {
        let result = try await operation()
        counter.increment()
        return result
    }

    // MARK: 数える操作

    public func launch(bundleID: String) async throws { try await counted { try await base.launch(bundleID: bundleID) } }
    public func terminate() async throws { try await counted { try await base.terminate() } }
    public func openAppSwitcher() async throws { try await counted { try await base.openAppSwitcher() } }
    public func home() async throws { try await counted { try await base.home() } }
    public func back() async throws { try await counted { try await base.back() } }
    public func tap(ref: Int) async throws { try await counted { try await base.tap(ref: ref) } }
    public func tap(x: Double, y: Double) async throws { try await counted { try await base.tap(x: x, y: y) } }
    public func type(ref: Int?, text: String) async throws { try await counted { try await base.type(ref: ref, text: text) } }
    public func clearInput(ref: Int?) async throws { try await counted { try await base.clearInput(ref: ref) } }
    public func hideKeyboard() async throws { try await counted { try await base.hideKeyboard() } }
    public func openURL(_ url: String, bundleID: String?) async throws {
        try await counted { try await base.openURL(url, bundleID: bundleID) }
    }
    public func pressEnter() async throws { try await counted { try await base.pressEnter() } }
    public func swipe(_ direction: FTSwipeDirection) async throws { try await counted { try await base.swipe(direction) } }
    public func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {
        try await counted { try await base.swipe(direction, intent: intent, path: path) }
    }
    public func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
                     pressSeconds: Double, durationSeconds: Double) async throws {
        try await counted {
            try await base.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                                pressSeconds: pressSeconds, durationSeconds: durationSeconds)
        }
    }
    public func doubleTap(x: Double, y: Double) async throws { try await counted { try await base.doubleTap(x: x, y: y) } }
    public func pinch(frame: FTRect?, identifier: String?, scale: Double, durationSeconds: Double) async throws {
        try await counted {
            try await base.pinch(frame: frame, identifier: identifier, scale: scale, durationSeconds: durationSeconds)
        }
    }
    public func gesture(_ request: GestureRequest) async throws { try await counted { try await base.gesture(request) } }
    public func rotate(to orientation: FTOrientation) async throws -> FTOrientation {
        try await counted { try await base.rotate(to: orientation) }
    }
    public func setHingeAngle(degrees: Double) async throws { try await counted { try await base.setHingeAngle(degrees: degrees) } }
    public func press(ref: Int, duration: Double) async throws { try await counted { try await base.press(ref: ref, duration: duration) } }
    public func press(x: Double, y: Double, duration: Double) async throws {
        try await counted { try await base.press(x: x, y: y, duration: duration) }
    }
    public func hold(x: Double, y: Double, duration: Double) async throws {
        try await counted { try await base.hold(x: x, y: y, duration: duration) }
    }

    // MARK: 数えない(読み取り・設定・ツール内部の操作。素通し)

    public func status() async throws -> StatusResponse { try await base.status() }
    @discardableResult
    public func install(packagePath: String) async throws -> String? { try await base.install(packagePath: packagePath) }
    public func uninstall(bundleID: String) async throws { try await base.uninstall(bundleID: bundleID) }
    public func activate(bundleID: String) async throws { try await base.activate(bundleID: bundleID) }
    public func attach(bundleID: String) async throws { try await base.attach(bundleID: bundleID) }
    public func snapshot() async throws -> SnapshotResponse { try await base.snapshot() }
    public func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse {
        try await base.snapshot(bypassingCache: bypassingCache)
    }
    public func hitTest(ref: Int) async throws -> HitTestAnswer { try await base.hitTest(ref: ref) }
    public func clearAppData(bundleID: String) async throws { try await base.clearAppData(bundleID: bundleID) }
    public func addMedia(path: String) async throws { try await base.addMedia(path: path) }
    public func acknowledgeOpenURLConsentIfPresent(bundleID: String) async {
        await base.acknowledgeOpenURLConsentIfPresent(bundleID: bundleID)
    }
    public func captureKeyboardStateOnNextSnapshot() { base.captureKeyboardStateOnNextSnapshot() }
    public func raiseElementLimitOnNextSnapshot(_ max: Int?) { base.raiseElementLimitOnNextSnapshot(max) }
    public var reachedEdgeOnLastSwipe: Bool? { base.reachedEdgeOnLastSwipe }
    public var lastTapHitAreaMiss: TapHitAreaMiss? { base.lastTapHitAreaMiss }
    public func tapProbe(x: Double, y: Double) async -> TapProbeResponse? { await base.tapProbe(x: x, y: y) }
    public func waitForSettle(_ request: WaitForSettleRequest, timeoutSeconds: Double) async throws -> WaitForSettleResponse {
        try await base.waitForSettle(request, timeoutSeconds: timeoutSeconds)
    }
    public func prepareResponseMeasurement(quietMs: Int, timeoutMs: Int, observeMs: Int) async throws -> ResponsePrepareResult {
        try await base.prepareResponseMeasurement(quietMs: quietMs, timeoutMs: timeoutMs, observeMs: observeMs)
    }
    public func collectResponseMeasurement() async throws -> ResponseCollectResult {
        try await base.collectResponseMeasurement()
    }
    public func fetchResponseObservation(firstDownTimeMs: Int) async throws -> ResponseObservation {
        try await base.fetchResponseObservation(firstDownTimeMs: firstDownTimeMs)
    }
    public func stopResponseObservation() async throws { try await base.stopResponseObservation() }
    public func restoreOrientationIfNeeded() async throws { try await base.restoreOrientationIfNeeded() }
    public func foldObservation() async -> FoldObservation? { await base.foldObservation() }
    public func continueAfterFold() async { await base.continueAfterFold() }
    public func screenshot() async throws -> Data { try await base.screenshot() }
    public func isAppForeground(bundleID: String) async throws -> Bool { try await base.isAppForeground(bundleID: bundleID) }
    public func systemAlert() async throws -> SystemAlertProbeResponse? { try await base.systemAlert() }
    public func systemUICovering() async throws -> SystemUICoveringResponse? { try await base.systemUICovering() }
    public func foregroundAppID() async throws -> String? { try await base.foregroundAppID() }
    public var lastActionNote: String? { base.lastActionNote }
    public var lastLaunchTiming: LaunchTiming? { base.lastLaunchTiming }
    public var supportsCacheBypass: Bool { base.supportsCacheBypass }
    public var treeLagsBehindMotion: Bool { base.treeLagsBehindMotion }
    public var pointScale: Double { base.pointScale }
    public var verifiesTypedText: Bool { base.verifiesTypedText }
    public var tapsWithSystemTouch: Bool { base.tapsWithSystemTouch }
    public func backGestureEdgeWidths() async -> (left: Double, right: Double, bottom: Double)? {
        await base.backGestureEdgeWidths()
    }
}
