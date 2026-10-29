// `tap(sel, waitSeconds: N)` でも、容器の外に報告された要素(ghost)を送り戻してから撃つこと。
// 待ち付きの分岐は「ghost が消えるのを待つだけ」で、既定の再試行の救済(2周目以降に1回送る)を
// 持たず、容器の外のまま期限が尽きて画面外を撃って ok になっていた(sendGhostRescue へ共通化)。

import XCTest
@testable import FTCore

final class TapGhostRescueWithWaitTests: XCTestCase {

    func testTapWithWaitSecondsRescuesAGhostByScrollingFirst() async {
        let driver = GhostUntilScrolledDriver()
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "row_30"), timeout: 4,
                            occlusionGuard: false)
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables()).execute(step)

        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "\(outcome.status)")
        XCTAssertGreaterThan(driver.scrolls, 0, "待ち付きの tap が ghost を送り戻さなかった")
        XCTAssertEqual(driver.tappedWhileGhost, false, "容器の外にいる間に撃った")
        XCTAssertEqual(driver.tapCount, 1)
        XCTAssertTrue(outcome.driverFallback?.contains("extra swipe") == true, outcome.driverFallback ?? "-")
    }

    func testTapWithoutWaitSecondsStillRescues() async {
        let driver = GhostUntilScrolledDriver()
        let step = FlowStep(action: "tap", locator: FlowLocator(id: "row_30"), occlusionGuard: false)
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables()).execute(step)

        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "\(outcome.status)")
        XCTAssertGreaterThan(driver.scrolls, 0)
        XCTAssertEqual(driver.tappedWhileGhost, false)
    }

    /// 送っても戻らない ghost に、待ち付きの分岐が既定の分岐より多く送らない(既定は attempt 1..N-1 で送る = N-1 回。
    /// 1回多いと行き過ぎて対象を容器の外へ押し戻す)
    func testWaitPathSendsNoMoreRescuesThanTheDefaultPath() async {
        let waiting = GhostUntilScrolledDriver()
        waiting.staysGhost = true
        _ = await StepExecutor(driver: waiting, isAndroid: false, tunables: RunTunables())
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "row_30"), timeout: 3, occlusionGuard: false))
        let plain = GhostUntilScrolledDriver()
        plain.staysGhost = true
        _ = await StepExecutor(driver: plain, isAndroid: false, tunables: RunTunables())
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "row_30"), occlusionGuard: false))
        XCTAssertEqual(plain.scrolls, StepExecutor.defaultLocatorRetryAttempts - 1)
        XCTAssertEqual(waiting.scrolls, plain.scrolls)
    }
}

/// 待つ・掴むだけのコマンドは、待ち付きでも ghost の救済を送らない(画面を動かさない。入口で waitForSettle に上限を付けるのはこのため)
final class WaitOnlyCommandsDoNotRescueTests: XCTestCase {
    func testWaitForSettleDoesNotScroll() async {
        let driver = GhostUntilScrolledDriver()
        driver.staysGhost = true
        _ = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .execute(FlowStep(action: "waitForSettle", locator: FlowLocator(id: "row_30"), timeout: 2, occlusionGuard: false))
        XCTAssertEqual(driver.scrolls, 0, "待つだけのコマンドが画面を送った")
    }

    /// 待ちの有無で変えない(待ち無しの既定の再試行も送らない)
    func testSelectWithoutWaitDoesNotScroll() async {
        let driver = GhostUntilScrolledDriver()
        driver.staysGhost = true
        _ = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .execute(FlowStep(action: "select", locator: FlowLocator(id: "row_30"), occlusionGuard: false))
        XCTAssertEqual(driver.scrolls, 0, "掴むだけのコマンドが画面を送った")
    }

    /// 掴むだけの select は何も送らない = 「操作が飲まれたかも」も容器の外で撃った印も付けない
    func testSelectOfAGhostCarriesNoSwallowedInteractionNote() async {
        let driver = GhostUntilScrolledDriver()
        driver.staysGhost = true
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .execute(FlowStep(action: "select", locator: FlowLocator(id: "row_30"), occlusionGuard: false))
        XCTAssertFalse(outcome.notes.contains(.actedOutsideContainer), "\(outcome.notes)")
        XCTAssertFalse((outcome.driverFallback ?? "").contains("interaction may be swallowed"), outcome.driverFallback ?? "")
    }

    func testSelectWithWaitDoesNotScroll() async {
        let driver = GhostUntilScrolledDriver()
        driver.staysGhost = true
        _ = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .execute(FlowStep(action: "select", locator: FlowLocator(id: "row_30"), timeout: 2, occlusionGuard: false))
        XCTAssertEqual(driver.scrolls, 0, "掴むだけのコマンドが画面を送った")
    }
}

/// 送りの上限に達した後に別の要素(スピナー)だけが動き出しても、「対象だけ動かない」と読んで待ちを早く終えない
/// (比べるのは送った直後の1回だけ。古い控えと比べ続けると、送っていない間のアニメーションで立っていた)
final class TapGhostRescueLateAnimationTests: XCTestCase {
    func testLateSpinnerDoesNotEndTheWaitEarly() async {
        let driver = GhostUntilScrolledDriver()
        driver.staysGhost = true
        driver.spinnerStartsAfterSends = StepExecutor.defaultLocatorRetryAttempts - 1
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "row_30"), timeout: 2, occlusionGuard: false))
        let text = "\(outcome.status) \(outcome.driverFallback ?? "")"
        XCTAssertFalse(text.contains("did not move when the container was swiped"), text)
    }
}

/// 待ちを明示した tap は、送りが効かず「対象だけ動かない」と分かっても待ちを打ち切らない(送りをやめるだけ)。
/// スピナーが回り続ける画面で1回目の送りの直後に抜けると、落ち着く前の残像(容器の外)を叩いていた
final class TapGhostRescueWaitsOutTheTimeoutTests: XCTestCase {
    func testWaitIsUsedUpAfterTheRescueGivesUp() async {
        let driver = SpinnerGhostSettlesLateDriver()
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .execute(FlowStep(action: "tap", locator: FlowLocator(id: "row_30"), timeout: 4, occlusionGuard: false))
        XCTAssertTrue(StepExecutor.isSuccess(outcome.status), "\(outcome.status)")
        XCTAssertEqual(driver.tappedWhileOutside, false, "落ち着く前の容器の外の残像を叩いた")
        XCTAssertEqual(driver.scrolls, 1, "対象だけ動かないと分かった後も送り続けた")
    }
}

/// スピナー(row_02)は読むたびに動く。row_30 は容器の外(y=783)に居続け、送っても動かず、読み始めから一定回数の後に
/// 容器の中(y=400)へ落ち着く(送りとは無関係 = 木の遅れが解けた形)
private final class SpinnerGhostSettlesLateDriver: AppDriver {
    private(set) var scrolls = 0
    private(set) var reads = 0
    private(set) var tappedWhileOutside: Bool?
    private let screen = FTRect(x: 0, y: 0, width: 390, height: 844)
    private var settled: Bool { reads >= 14 }

    private func el(_ ref: Int, _ type: String, _ depth: Int, _ y: Double, _ h: Double, id: String) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 0, y: y, width: 390, height: h), depth: depth)
    }
    func snapshot() async throws -> SnapshotResponse {
        reads += 1
        let elements = [el(1, "scrollView", 1, 230, 462, id: "list_rows"),
                        el(2, "cell", 2, 240, 60, id: "row_01"),
                        el(3, "cell", 2, 300 + Double(reads % 5) * 3, 60, id: "row_02"),
                        el(4, "cell", 2, settled ? 400 : 783, 60, id: "row_30")]
        return SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements, truncatedCount: 0)
    }
    func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse { try await snapshot() }
    func swipe(_ direction: FTSwipeDirection) async throws { scrolls += 1 }
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws { scrolls += 1 }
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws { scrolls += 1 }
    func tap(ref: Int) async throws { tappedWhileOutside = !settled }
    func tap(x: Double, y: Double) async throws { tappedWhileOutside = !settled }
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func type(ref: Int?, text: String) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}

/// 送り(swipe / drag)の前は row_30 が容器の外(y=783)、送った後は容器の中(y=400)に報告するドライバ
private final class GhostUntilScrolledDriver: AppDriver {
    private(set) var scrolls = 0
    private(set) var tapCount = 0
    private(set) var tappedWhileGhost: Bool?
    /// true = 送っても容器の外のまま(救済が効かない ghost)
    var staysGhost = false
    /// この本数を送り終えた後、2枚目の読みからスピナー(row_02 の位置)を毎回動かす(nil = 動かさない)
    var spinnerStartsAfterSends: Int?
    private var readsAfterSends = 0
    private let screen = FTRect(x: 0, y: 0, width: 390, height: 844)

    private func el(_ ref: Int, _ type: String, _ depth: Int, _ y: Double, _ h: Double, id: String) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 0, y: y, width: 390, height: h), depth: depth)
    }
    private func tree() -> [ElementInfo] {
        [el(1, "scrollView", 1, 230, 462, id: "list_rows"),
         el(2, "cell", 2, 240, 60, id: "row_01"),
         el(3, "cell", 2, 300 + spinnerOffset(), 60, id: "row_02"),
         el(4, "cell", 2, scrolls > 0 && !staysGhost ? 400 : 783, 60, id: "row_30")]
    }
    private func spinnerOffset() -> Double {
        guard let after = spinnerStartsAfterSends, scrolls >= after else { return 0 }
        return readsAfterSends >= 2 ? Double(readsAfterSends % 5) * 3 : 0
    }
    func snapshot() async throws -> SnapshotResponse {
        if let after = spinnerStartsAfterSends, scrolls >= after { readsAfterSends += 1 }
        return SnapshotResponse(sessionBundleID: nil, screen: screen, elements: tree(), truncatedCount: 0)
    }
    func snapshot(bypassingCache: Bool) async throws -> SnapshotResponse { try await snapshot() }
    func swipe(_ direction: FTSwipeDirection) async throws { scrolls += 1 }
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws { scrolls += 1 }
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws { scrolls += 1 }
    func tap(ref: Int) async throws { tapCount += 1; tappedWhileGhost = scrolls == 0 }
    func tap(x: Double, y: Double) async throws { tapCount += 1; tappedWhileGhost = scrolls == 0 }
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func type(ref: Int?, text: String) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}
