// 端を申告しない構成(iOS の XCUITest)で、scrollToEdge の端の確かめが引っ張って更新に化けないことの固定(`EdgeProbe`)。
// 実測(E2EX-CMP の引っ張って更新): 上端に着いた送りでは更新は走らず、**着いた後の全力の送り1本ごとに1回**走る。
// 端の確定に要る「署名の2回不変」の確かめを、引っ張りの閾値より短いドラッグで撃てば走らない。

import XCTest
@testable import FTCore

/// 端を申告しない(`reachedEdgeOnLastSwipe == nil`)縦の一覧。全力の送りは慣性込みで指の移動量 + `fling` 動き、
/// 上端(offset 0)で全力の送りを受けると引っ張って更新が1回走る。短いドラッグは端では何も起こさない
private final class PullToRefreshListDriver: AppDriver {
    private var offset: Double
    private let fling: Double
    private let withIDs: Bool
    private(set) var pulls = 0
    private(set) var fullSwipes = 0
    private(set) var drags: [FTSwipePath] = []
    var reachedEdgeOnLastSwipe: Bool? { nil }
    private let rowHeight = 56.0, top = 182.0, rows: Int
    private var maxOffset: Double { Double(rows) * rowHeight - 658 }

    init(startAtBottom: Bool = true, fling: Double = 200, withIDs: Bool = true, rows: Int = 40) {
        self.fling = fling
        self.withIDs = withIDs
        self.rows = rows
        offset = 0
        if startAtBottom { offset = maxOffset }
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
    func swipe(_ direction: FTSwipeDirection) async throws { try await swipe(direction, intent: .edge, path: nil) }
    func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent, path: FTSwipePath?) async throws {
        fullSwipes += 1
        let travel = path.map { abs($0.toY - $0.fromY) } ?? 400
        move(finger: direction, by: travel + fling, pullsAtTop: true)
    }
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
              pressSeconds: Double, durationSeconds: Double) async throws {
        drags.append(FTSwipePath(fromX: fromX, fromY: fromY, toX: toX, toY: toY))
        move(finger: toY > fromY ? .down : .up, by: abs(toY - fromY), pullsAtTop: false)
    }
    private func move(finger: FTSwipeDirection, by distance: Double, pullsAtTop: Bool) {
        if finger == .down {
            if offset == 0 { if pullsAtTop { pulls += 1 }; return }
            offset = max(0, offset - distance)
        } else if finger == .up {
            offset = min(maxOffset, offset + distance)
        }
    }
    func snapshot() async throws -> SnapshotResponse {
        var elements = [
            ElementInfo(ref: 1, type: "scrollView", identifier: nil, label: nil, value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 0, y: 0, width: 402, height: 874), depth: 0, scrollable: true),
            // 送っても動かない見出し(容器の中に載る = CMP の XCUITest の形)
            ElementInfo(ref: 2, type: "staticText", identifier: "txt_screen_title", label: "引っ張って更新", value: nil,
                        placeholder: nil, enabled: true, frame: FTRect(x: 56, y: 80, width: 144, height: 28), depth: 1),
            // 一覧の枠(動かない。行はこの中を動く = E2EX-CMP の #box_refresh)
            ElementInfo(ref: 3, type: "other", identifier: "box_list", label: nil, value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 0, y: top, width: 402, height: 658), depth: 1),
        ]
        for k in 0..<rows {
            let y = top + Double(k) * rowHeight - offset
            guard y >= top - rowHeight, y < 840 else { continue }
            elements.append(ElementInfo(ref: elements.count + 1, type: "other",
                                        identifier: withIDs ? String(format: "row_%02d", k) : nil,
                                        label: String(format: "更新行 %02d", k), value: nil, placeholder: nil,
                                        enabled: true, frame: FTRect(x: 0, y: y, width: 402, height: 56), depth: 1))
        }
        return SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: elements, truncatedCount: 0)
    }
}

final class EdgeProbeTests: XCTestCase {

    private func scrollToTop() -> FlowStep { FlowStep(action: "scrollToEdge", direction: "down", maxSwipes: 20) }

    /// 下端から上端へ戻す: 上端に着いた後の確かめは短いドラッグ2本 = 引っ張って更新は1回も走らない
    func testTheEdgeIsConfirmedWithShortDragsSoNoPullToRefreshFires() async {
        let driver = PullToRefreshListDriver()
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables()).execute(scrollToTop())
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.pulls, 0, "確かめの全力の送りが上端で引っ張った: \(outcome.driverFallback ?? "-")")
        // 確かめ = 署名の2回不変。最後に動いてから `edgeClaimGraceAfterMove` 経つ前に不変が揃うと、猶予の後にもう1本撃つ
        // (テストのドライバは時間を進めないので3本。デバイスでは短いドラッグ自体が 1 秒かかる)
        XCTAssertTrue((2...3).contains(driver.drags.count), "確かめは短いドラッグ 2〜3 本: \(driver.drags.count)")
        XCTAssertTrue(driver.drags.allSatisfy { $0.toY - $0.fromY == EdgeProbe.distance })
        XCTAssertTrue(outcome.notes.contains(.edgeProbedGently), "\(outcome.notes)")
        XCTAssertTrue(outcome.driverFallback?.contains("short drag") == true, outcome.driverFallback ?? "-")
    }

    /// **1本目で上端に着く短い一覧**(比べる基準が無い): 先頭の行が動かない枠の上端に揃ったのを読み、確かめを短いドラッグにする
    func testAShortListReachingTheTopOnTheFirstSwipeIsReadFromTheFlushFrame() async {
        let driver = PullToRefreshListDriver(rows: 20)   // 下端からの残り 462pt = 1本で上端
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables()).execute(scrollToTop())
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.fullSwipes, 1, "上端に着いた後に全力の送りを撃った")
        XCTAssertEqual(driver.pulls, 0)
        XCTAssertTrue(outcome.driverFallback?.contains("flush with the edge of its frame") == true, outcome.driverFallback ?? "-")
    }

    /// 窓の狭い一覧(1本で窓1枚より多く動く = 前後で共通の行が残らない)でも、上端で揃ったのを読む
    func testANarrowViewportListThatJumpsMoreThanAWindowStillReadsTheFlush() async {
        let driver = PullToRefreshListDriver(fling: 2000)   // 1本目で下端から上端まで(1582pt)飛ぶ = 共通の行が残らない
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables()).execute(scrollToTop())
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.pulls, 0, outcome.driverFallback ?? "-")
        XCTAssertFalse(driver.drags.isEmpty)
    }

    func testFlushAgainstAStaticFrame() {
        let box = ElementInfo(ref: 9, type: "other", identifier: "box", label: nil, value: nil, placeholder: nil,
                              enabled: true, frame: FTRect(x: 0, y: 182, width: 402, height: 658), depth: 0)
        let before = [box, element("row_05", y: 0), element("row_06", y: 56)]
        let atTop = [box, element("row_00", y: 182), element("row_05", y: 462)]
        let midway = [box, element("row_02", y: 200), element("row_05", y: 368)]
        XCTAssertTrue(EdgeProbe.flushAgainstStaticFrame(before: before, after: atTop, region: nil, finger: .down))
        XCTAssertFalse(EdgeProbe.flushAgainstStaticFrame(before: before, after: midway, region: nil, finger: .down))
        // 動かない枠が無ければ読まない
        XCTAssertFalse(EdgeProbe.flushAgainstStaticFrame(before: Array(before.dropFirst()), after: Array(atTop.dropFirst()),
                                                         region: nil, finger: .down))
    }

    /// 動いた量を測れない(id の無い行)ときは今までどおり全力の送りで確かめる(引っ張りは残る = 既知の取りこぼし)
    func testWithoutStableIDsTheConfirmationStaysAFullSwipe() async {
        let driver = PullToRefreshListDriver(withIDs: false)
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables()).execute(scrollToTop())
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(driver.drags.isEmpty)
        XCTAssertFalse(outcome.notes.contains(.edgeProbedGently))
    }

    /// 既に上端から始めた送りで、慣性の大きい一覧の途中でも短いドラッグは端でなければ中身を動かし、全力の送りへ戻る
    /// (= 外れても端を早く確定しない。損は時間だけ)
    func testAProbeAwayFromTheEdgeMovesTheContentAndFullSwipesResume() async {
        let driver = PullToRefreshListDriver(fling: -150)   // 慣性が無く指の移動量より動かない一覧 = 毎回「届かない」に見える
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables()).execute(scrollToTop())
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertEqual(driver.pulls, 0)
        XCTAssertGreaterThan(driver.fullSwipes, 2, "短いドラッグで動いたのに全力の送りへ戻っていない")
        XCTAssertNil(outcome.driverFallback.flatMap { $0.contains("stopped at the limit") ? $0 : nil },
                     "端に届かず上限で止まった: \(outcome.driverFallback ?? "-")")
    }

    // MARK: - 純粋関数

    private func element(_ id: String?, y: Double, x: Double = 0) -> ElementInfo {
        ElementInfo(ref: 1, type: "other", identifier: id, label: nil, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: x, y: y, width: 100, height: 40), depth: 0)
    }

    func testDisplacementIsTheLargestMoveAmongSharedIDsSoFixedHeadersDoNotHideIt() {
        let before = [element("title", y: 80), element("row_05", y: 0), element("row_06", y: 56)]
        let after = [element("title", y: 80), element("row_05", y: 462), element("row_06", y: 518)]
        XCTAssertEqual(EdgeProbe.contentDisplacement(before: before, after: after, region: nil, vertical: true), 462)
    }

    func testOnlyFixedElementsSharedWhileNewContentAppearedIsUnmeasurable() {
        let before = [element("title", y: 80), element("row_30", y: 300)]
        let after = [element("title", y: 80), element("row_02", y: 300)]
        XCTAssertNil(EdgeProbe.contentDisplacement(before: before, after: after, region: nil, vertical: true))
        XCTAssertNil(EdgeProbe.contentDisplacement(before: [element("a", y: 1)], after: [element("b", y: 2)],
                                                   region: nil, vertical: true))
        XCTAssertEqual(EdgeProbe.contentDisplacement(before: [element("a", y: 1)], after: [element("a", y: 1)],
                                                     region: nil, vertical: true), 0)
    }

    func testDuplicateIDsAndElementsOutsideTheRegionAreNotCounted() {
        let before = [element("dup", y: 0), element("dup", y: 50), element("out", y: 900), element("row", y: 100)]
        let after = [element("dup", y: 400), element("dup", y: 450), element("out", y: 100), element("row", y: 110)]
        XCTAssertEqual(EdgeProbe.contentDisplacement(before: before, after: after,
                                                     region: FTRect(x: 0, y: 0, width: 402, height: 800), vertical: true), 10)
    }

    func testStoppedShortAndProbePath() {
        XCTAssertTrue(EdgeProbe.stoppedShort(displacement: 462, fingerTravel: 524))
        XCTAssertFalse(EdgeProbe.stoppedShort(displacement: 724, fingerTravel: 524))
        XCTAssertFalse(EdgeProbe.stoppedShort(displacement: 0, fingerTravel: 0))
        let container = FTRect(x: 0, y: 100, width: 400, height: 600)
        XCTAssertEqual(EdgeProbe.path(in: container, finger: .down, avoiding: [], moved: []),
                       FTSwipePath(fromX: 200, fromY: 400, toX: 200, toY: 430))
        XCTAssertEqual(EdgeProbe.path(in: container, finger: .left, avoiding: [], moved: []),
                       FTSwipePath(fromX: 200, fromY: 400, toX: 170, toY: 400))
    }

    /// 始点・終点を押せる型の要素の上に置かない(短いドラッグは要素の外へ出ないのでタップに化けうる)
    func testTheProbeStartsAwayFromButtons() throws {
        let container = FTRect(x: 0, y: 100, width: 400, height: 600)
        let card = ElementInfo(ref: 1, type: "button", identifier: "card", label: nil, value: nil, placeholder: nil,
                               enabled: true, frame: FTRect(x: 0, y: 300, width: 400, height: 200), depth: 1)
        let path = try XCTUnwrap(EdgeProbe.path(in: container, finger: .down, avoiding: [card], moved: []))
        XCTAssertFalse(StepExecutor.frame(card.frame, containsX: path.fromX, y: path.fromY), "\(path)")
        XCTAssertFalse(StepExecutor.frame(card.frame, containsX: path.toX, y: path.toY), "\(path)")
        // 容器の全部が押せる要素なら撃たない(呼び手は全力の送りのまま)
        let wall = ElementInfo(ref: 2, type: "cell", identifier: nil, label: nil, value: nil, placeholder: nil,
                               enabled: true, frame: container, depth: 1)
        XCTAssertNil(EdgeProbe.path(in: container, finger: .down, avoiding: [wall], moved: []))
    }

    /// 行が全部押せる型の一覧(SE3 の SwiftUI の表 = 全行 clickable)でも、**動いた行の上から**始めて撃つ(スクロールが取るので
    /// タップにならない)。一覧に重なった**動かない**浮動ボタンは避ける
    func testTheProbeStartsOnMovedRowsButAvoidsAStaticFloatingButton() throws {
        let table = FTRect(x: 16, y: 228, width: 343, height: 264)
        let rows = (1...5).map { k in   // 5 行で表(264pt)を埋める
            ElementInfo(ref: k, type: "clickable", identifier: "row_0\(k)", label: nil, value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 16, y: 228 + Double(k - 1) * 56, width: 343, height: 56), depth: 1)
        }
        let fab = ElementInfo(ref: 9, type: "button", identifier: "fab", label: nil, value: nil, placeholder: nil,
                              enabled: true, frame: FTRect(x: 16, y: 284, width: 343, height: 112), depth: 2)
        XCTAssertNil(EdgeProbe.path(in: table, finger: .down, avoiding: rows, moved: []), "動いた行が分からなければ押せる行の上は避ける")
        let path = try XCTUnwrap(EdgeProbe.path(in: table, finger: .down, avoiding: rows + [fab],
                                                moved: ["row_01", "row_02", "row_03", "row_04", "row_05"]))
        XCTAssertFalse(StepExecutor.frame(fab.frame, containsX: path.fromX, y: path.fromY), "\(path)")
        XCTAssertFalse(StepExecutor.frame(fab.frame, containsX: path.toX, y: path.toY), "\(path)")
        XCTAssertTrue(rows.contains { StepExecutor.frame($0.frame, containsX: path.fromX, y: path.fromY) }, "\(path)")
    }

    /// 1ページずつ吸着する一覧(先頭が枠いっぱい)では揃いを読まない = 途中のページを端と確定しない
    func testAFullPageFlushWithTheFrameIsNotReadAsTheEdge() {
        let box = ElementInfo(ref: 9, type: "other", identifier: "box", label: nil, value: nil, placeholder: nil,
                              enabled: true, frame: FTRect(x: 0, y: 182, width: 402, height: 658), depth: 0)
        func page(_ id: String, y: Double) -> ElementInfo {
            ElementInfo(ref: 1, type: "other", identifier: id, label: nil, value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 0, y: y, width: 402, height: 658), depth: 1)
        }
        XCTAssertFalse(EdgeProbe.flushAgainstStaticFrame(before: [box, page("p3", y: 182)], after: [box, page("p2", y: 182), page("p3", y: 840)],
                                                         region: nil, finger: .down))
    }

    /// **上端(scrollToTop)だけ**: 下端・横の端は従来どおり全力の送りで確かめる
    func testOtherEdgesKeepFullSwipes() async {
        let driver = PullToRefreshListDriver(startAtBottom: false)
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .execute(FlowStep(action: "scrollToEdge", direction: "up", maxSwipes: 20))
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(driver.drags.isEmpty, "下端で短いドラッグを撃った")
    }

    /// **Android では使わない**(距離は pt で詰めた値・Android の木は px)
    func testAndroidKeepsFullSwipesForTheConfirmation() async {
        let driver = PullToRefreshListDriver()
        let outcome = await StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables()).execute(scrollToTop())
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(driver.drags.isEmpty, "Android で短いドラッグを撃った")
    }

    /// 既定の定数(根拠は EdgeProbe の doc)。変えるなら閾値とタッチの遊びの両方を見直すこと
    func testTheProbeConstantsArePinned() {
        XCTAssertEqual(EdgeProbe.distance, 30)
        XCTAssertEqual(EdgeProbe.durationSeconds, 1.0)
    }
}
