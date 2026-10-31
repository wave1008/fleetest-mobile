// 容器の外で動き続ける表示(ティッカー・時計)を、スクロール探索が「動いた」と数えないことを固定する。
// 数えると端を検知できず(指定なしの探索)、動いていない一覧を逆走査で引き戻した。

import XCTest
@testable import FTCore

/// 一覧は一切動かない。毎回の snapshot で #ticker のラベルだけが変わる。
/// `listFrame` を画面中央から外すと、画面中央を含む容器が採れない画面(木全体で比べるしかない画面)になる
private final class StaticListWithTickerDriver: AppDriver {
    private let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
    private let listFrame: FTRect
    private let declaresScrollable: Bool
    private var reads = 0
    private(set) var swipes = 0
    private(set) var drags = 0

    init(listFrame: FTRect, declaresScrollable: Bool) {
        self.listFrame = listFrame
        self.declaresScrollable = declaresScrollable
    }

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
    func swipe(_ direction: FTSwipeDirection) async throws { swipes += 1 }
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws { drags += 1 }

    func snapshot() async throws -> SnapshotResponse {
        reads += 1
        let top = listFrame.y
        let elements = [
            ElementInfo(ref: 1, type: "staticText", identifier: "ticker", label: "t\(reads)", value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: 0, width: 400, height: 30), depth: 0),
            ElementInfo(ref: 2, type: "scrollView", identifier: "list", label: nil, value: nil,
                        placeholder: nil, enabled: true, frame: listFrame, depth: 0,
                        scrollable: declaresScrollable ? true : nil),
            ElementInfo(ref: 3, type: "button", identifier: "row_01", label: nil, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 16, y: top + 10, width: 368, height: 56), depth: 1),
            ElementInfo(ref: 4, type: "button", identifier: "row_02", label: nil, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 16, y: top + 90, width: 368, height: 56), depth: 1),
            ElementInfo(ref: 5, type: "button", identifier: "row_ghost", label: nil, value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: 16, y: -1000, width: 368, height: 56), depth: 1),
        ]
        return SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements, truncatedCount: 0)
    }
}

/// 申告された一覧が `movingReads` 回目の読みまで毎回ずれ、その後は止まる(途中で動いて末尾で止まる探索)
private final class ListStoppingDriver: AppDriver {
    private let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
    private let movingReads: Int
    private var reads = 0

    init(movingReads: Int) { self.movingReads = movingReads }

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
              pressSeconds: Double, durationSeconds: Double) async throws {}

    func snapshot() async throws -> SnapshotResponse {
        reads += 1
        let label = "row \(min(reads, movingReads))"
        let elements = [
            ElementInfo(ref: 1, type: "scrollView", identifier: "list", label: nil, value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 0, y: 60, width: 400, height: 740), depth: 0, scrollable: true),
            ElementInfo(ref: 2, type: "button", identifier: "row", label: label, value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 16, y: 100, width: 368, height: 56), depth: 1),
        ]
        return SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements, truncatedCount: 0)
    }
}

final class ScrollSearchTickerOutsideContainerTests: XCTestCase {
    /// 最後の払いで動いたときだけ「まだ動いていた」と言う
    func testExhaustedWhileMovingLooksAtTheLastSwipeNotTheWholeSearch() async throws {
        func exhausted(movingReads: Int) async throws -> StepExecutor.ScrollSearchResult {
            let executor = StepExecutor(driver: ListStoppingDriver(movingReads: movingReads), isAndroid: false, tunables: RunTunables())
            let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_nosuch"), direction: "up", maxSwipes: 3)
            var phase = StepExecutor.PhaseAccumulator()
            return try await executor.runScrollSearch(step: step, phase: &phase)
        }
        let moving = try await exhausted(movingReads: 1000)
        XCTAssertTrue(moving.exhaustedWhileMoving, "最後まで動いていた探索")
        let stopped = try await exhausted(movingReads: 3)
        XCTAssertFalse(stopped.exhaustedWhileMoving, "末尾で止まった探索に「端に着いていない」と言った")
    }

    private func search(_ driver: StaticListWithTickerDriver) async throws -> StepExecutor.ScrollSearchResult {
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "row_nosuch"), direction: "up", maxSwipes: 6)
        var phase = StepExecutor.PhaseAccumulator()
        return try await executor.runScrollSearch(step: step, phase: &phase)
    }

    /// 申告された容器(画面中央を含む)がある画面: 容器の中だけを比べるので、ティッカーが動いても 2 周で端と読む
    func testDeclaredContainerIgnoresTickerOutsideIt() async throws {
        let driver = StaticListWithTickerDriver(listFrame: FTRect(x: 0, y: 60, width: 400, height: 740),
                                                declaresScrollable: true)
        let result = try await search(driver)
        XCTAssertTrue(result.stoppedUnmoving, "ティッカーの動きを「動いた」と数え、端を検知できなかった")
        XCTAssertFalse(result.contentEverMoved)
        XCTAssertEqual(driver.drags, 0, "動いていない探索で逆走査を撃った")
        XCTAssertLessThan(driver.swipes, 6, "上限まで払い続けた")
    }

    /// 申告が無く形から採る画面(Compose iOS)も同じ
    func testShapeInferredContainerIgnoresTickerOutsideIt() async throws {
        let driver = StaticListWithTickerDriver(listFrame: FTRect(x: 0, y: 60, width: 400, height: 740),
                                                declaresScrollable: false)
        let result = try await search(driver)
        XCTAssertTrue(result.stoppedUnmoving)
        XCTAssertEqual(driver.drags, 0)
    }

    /// 画面中央を含む容器が採れない画面(木全体で比べるしかない)でも、位置の動きを1度も観測していなければ逆走査を撃たず、
    /// 「まだ動いていた」とも言わない
    func testNoRegionAndNoObservedMovementDoesNotSweepOrClaimMoving() async throws {
        let driver = StaticListWithTickerDriver(listFrame: FTRect(x: 0, y: 40, width: 400, height: 300),
                                                declaresScrollable: false)
        let result = try await search(driver)
        XCTAssertFalse(result.found)
        XCTAssertEqual(driver.drags, 0, "位置の動きを観測していない探索が逆走査で一覧を引き戻した")
        XCTAssertFalse(result.reverseSweepRan)
        XCTAssertFalse(result.exhaustedWhileMoving, "動いていない一覧に「まだ動いていた」と言った")
    }

    func testRegionPicksTheDeclaredContainerThenTheShapeThenNil() async throws {
        let declared = try await StaticListWithTickerDriver(listFrame: FTRect(x: 0, y: 60, width: 400, height: 740),
                                                            declaresScrollable: true).snapshot()
        let step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "x"), direction: "up")
        XCTAssertEqual(StepExecutor.searchContentRegion(step, in: declared), FTRect(x: 0, y: 60, width: 400, height: 740))
        let offCentre = try await StaticListWithTickerDriver(listFrame: FTRect(x: 0, y: 40, width: 400, height: 300),
                                                             declaresScrollable: false).snapshot()
        XCTAssertNil(StepExecutor.searchContentRegion(step, in: offCentre), "画面中央を含まない容器を比べる領域に採った")
    }
}
