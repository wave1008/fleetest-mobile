// 順方向で1度も動かなかったスクロール探索は逆走査(飛び越しの救済)を撃たないことを固定する(端で打ち切る側と弾切れ側の両方)。

import XCTest
@testable import FTCore

/// 順方向のスワイプ(swipe)では絶対に動かず、逆走査の drag を1回でも受けたら位置が変わって
/// 目的の要素("row_target")が現れる偽ドライバ —— 「探索の開始位置が既にこの向きの端で、目的は反対側にある」。
/// **内容は「drag が来たか」だけで決める**(settledSignature の内部ポーリング回数に依存する台本は避ける)。
/// row_ghost は容器(list)の外に常駐させる —— overflowingContainer が逆走査の容器を
/// 特定するための材料(clippingContainer の推測条件 = 同深さの子を2つ以上容器内に持つこと)
private final class EdgeStartTargetOnOtherSideDriver: AppDriver {
    private let screen: FTRect
    private(set) var drags = 0

    init(screen: FTRect) { self.screen = screen }

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func terminate() async throws {}
    func screenshot() async throws -> Data { Data() }
    func type(ref: Int?, text: String) async throws {}
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws { drags += 1 }

    func snapshot() async throws -> SnapshotResponse {
        let offset: Double = drags == 0 ? 0 : 60
        var elements = [
            ElementInfo(ref: 1, type: "scrollView", identifier: "list", label: nil, value: nil,
                       placeholder: nil, enabled: true,
                       frame: FTRect(x: 0, y: 0, width: 400, height: 800), depth: 0,
                       scrollable: true),
            ElementInfo(ref: 2, type: "button", identifier: "row_01", label: nil, value: nil,
                       placeholder: nil, enabled: true,
                       frame: FTRect(x: 16, y: 40 - offset, width: 368, height: 56), depth: 1),
            ElementInfo(ref: 3, type: "button", identifier: "row_02", label: nil, value: nil,
                       placeholder: nil, enabled: true,
                       frame: FTRect(x: 16, y: 120 - offset, width: 368, height: 56), depth: 1),
            ElementInfo(ref: 4, type: "button", identifier: "row_ghost", label: nil, value: nil,
                       placeholder: nil, enabled: true,
                       frame: FTRect(x: 16, y: -1000, width: 368, height: 56), depth: 1)
        ]
        if drags > 0 {
            elements.append(ElementInfo(ref: 5, type: "button", identifier: "row_target", label: nil,
                                        value: nil, placeholder: nil, enabled: true,
                                        frame: FTRect(x: 16, y: 400, width: 368, height: 56), depth: 1))
        }
        return SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements,
                                truncatedCount: 0)
    }
}

final class ScrollReverseSweepEdgeStartTests: XCTestCase {
    /// **開始位置が既にこの向きの端なら、反対側を探さずに失敗する**(SE3 の探索で実測: 先頭で
    /// `scrollTo(direction: .up)` が逆走査で下の行を見つけて成功した = 「上にある」の確認にならない)。
    /// 逆走査は飛び越しの救済で、1度も動いていなければ何も通り過ぎていない
    func testNoReverseSweepWhenTheForwardSearchNeverMoved() async throws {
        let driver = EdgeStartTargetOnOtherSideDriver(
            screen: FTRect(x: 0, y: 0, width: 400, height: 800))
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_target"),
                            direction: "up", maxSwipes: 6)
        var phase = StepExecutor.PhaseAccumulator()

        let result = try await executor.runScrollSearch(step: step, phase: &phase)

        XCTAssertFalse(result.found, "指定と逆の側にある要素を見つけて成功している")
        XCTAssertTrue(result.stoppedUnmoving)
        XCTAssertFalse(result.contentEverMoved, "順方向は1度も動いていないはず")
        XCTAssertEqual(driver.drags, 0, "1度も動かなかった探索で逆走査のドラッグを撃った")
        XCTAssertFalse(result.reverseSweepRan)

        let message = StepExecutor.scrollNotFoundMessage(step, result, defaultMaxSwipes: 8)
        XCTAssertTrue(message.contains("nothing moved at all"), message)
        XCTAssertTrue(message.contains("the opposite direction was not searched"), message)
        // 指の向き up = スクロールの向き down で探した → 反対のスクロールの向きは .up
        XCTAssertTrue(message.contains("search with direction: .up"), message)
        // tap / exist の引数名は scroll:(direction: ではない)
        var tapStep = step
        tapStep.action = "tap"
        let tapMessage = StepExecutor.scrollNotFoundMessage(tapStep, result, defaultMaxSwipes: 8)
        XCTAssertTrue(tapMessage.contains("search with scroll: .up"), tapMessage)
        XCTAssertFalse(message.contains("reverse sweep"), message)
    }

    /// 弾切れ(maxSwipes を使い切った)側の逆走査も同じ条件で撃たない。maxSwipes: 1 は2周目の比較の前に
    /// ループを抜けるので、端で打ち切る側の guard を通らずにこちらへ来る(F26 の再現は maxSwipes: 1 だった)
    func testNoReverseSweepWhenSwipesRunOutWithoutAnyMovement() async throws {
        let driver = EdgeStartTargetOnOtherSideDriver(
            screen: FTRect(x: 0, y: 0, width: 400, height: 800))
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_target"),
                            direction: "up", maxSwipes: 1)
        var phase = StepExecutor.PhaseAccumulator()

        let result = try await executor.runScrollSearch(step: step, phase: &phase)

        XCTAssertFalse(result.found, "指定と逆の側にある要素を見つけて成功している")
        XCTAssertEqual(driver.drags, 0, "1度も動かなかった探索で逆走査のドラッグを撃った")
    }

    /// 逆走査の最初の1本が撃てずに諦めた回は「逆走査した・画面は戻した位置のまま」と言わない(何も動かしていない)
    func testSweepThatCouldNotSendADragIsNotReported() async throws {
        let driver = DragRefusingDriver(screen: FTRect(x: 0, y: 0, width: 400, height: 800))
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_target"),
                            direction: "up", maxSwipes: 6)
        var phase = StepExecutor.PhaseAccumulator()

        let result = try await executor.runScrollSearch(step: step, phase: &phase)

        XCTAssertFalse(result.found)
        XCTAssertTrue(result.contentEverMoved, "順方向は動いてから端に着く台本")
        XCTAssertGreaterThan(driver.dragAttempts, 0, "逆走査の経路に入っていない")
        XCTAssertFalse(result.reverseSweepRan, "1本も撃てなかったのに撃ったことにした")
        let message = StepExecutor.scrollNotFoundMessage(step, result, defaultMaxSwipes: 8)
        XCTAssertFalse(message.contains("reverse sweep"), message)
    }
}

/// 送り(swipe)は1回だけ動いて端に着き、ドラッグ(逆走査)は必ず投げる偽ドライバ。row_ghost は容器の外に常駐させる
/// (overflowingContainer が逆走査の容器を推測する材料)
private final class DragRefusingDriver: AppDriver {
    private let screen: FTRect
    private var offset = 0.0
    private(set) var dragAttempts = 0
    struct Refused: Error {}

    init(screen: FTRect) { self.screen = screen }

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func terminate() async throws {}
    func screenshot() async throws -> Data { Data() }
    func type(ref: Int?, text: String) async throws {}
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws { offset = 100 }
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws {
        dragAttempts += 1
        throw Refused()
    }

    func snapshot() async throws -> SnapshotResponse {
        func row(_ ref: Int, _ id: String, _ y: Double) -> ElementInfo {
            ElementInfo(ref: ref, type: "button", identifier: id, label: nil, value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 16, y: y - offset, width: 368, height: 56), depth: 1)
        }
        let elements = [
            ElementInfo(ref: 1, type: "scrollView", identifier: "list", label: nil, value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 0, y: 0, width: 400, height: 800), depth: 0, scrollable: true),
            row(2, "row_01", 140), row(3, "row_02", 220),
            ElementInfo(ref: 4, type: "button", identifier: "row_ghost", label: nil, value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 16, y: -1000, width: 368, height: 56), depth: 1),
        ]
        return SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements, truncatedCount: 0)
    }
}
