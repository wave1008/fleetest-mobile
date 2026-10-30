// 渡した scrollFrame が探索と別の軸にしか動かないときの失敗文・横向きの低い縦の一覧の候補・クリップ寄せの空振り停止を固定する。

import XCTest
@testable import FTCore

final class ScrollSearchAxisHintTests: XCTestCase {

    private func el(_ ref: Int, id: String, x: Double, y: Double, w: Double, h: Double,
                    scrollable: Bool? = nil, actions: [String]? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: "scrollView", identifier: id, label: nil, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: x, y: y, width: w, height: h), depth: 2,
                    scrollable: scrollable, scrollActions: actions)
    }

    private func snap(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                         elements: elements, truncatedCount: 0)
    }

    private func frameStep() -> FlowStep {
        FlowStep(action: "scrollTo", locator: FlowLocator(id: "card"), direction: "up", maxSwipes: 3,
                 scrollFrame: FlowLocator(id: "shelf"))
    }

    func testDeclaredHorizontalContainerIsOtherAxisForVerticalSearch() {
        let s = snap([el(1, id: "shelf", x: 0, y: 100, w: 370, h: 120, scrollable: true, actions: ["left", "right"])])
        XCTAssertTrue(StepExecutor.scrollFrameRunsOtherAxis(step: frameStep(), in: s, vertical: true))
        XCTAssertFalse(StepExecutor.scrollFrameRunsOtherAxis(step: frameStep(), in: s, vertical: false))
    }

    /// 申告が無いときは子の並びで言う。横に並ぶ子 = 横の容器
    func testUndeclaredContainerUsesChildLayoutNotAspect() {
        let row = [el(1, id: "shelf", x: 0, y: 100, w: 370, h: 120, scrollable: true),
                   el(2, id: "c1", x: 0, y: 110, w: 100, h: 100), el(3, id: "c2", x: 110, y: 110, w: 100, h: 100),
                   el(4, id: "c3", x: 220, y: 110, w: 100, h: 100)]
        XCTAssertTrue(StepExecutor.scrollFrameRunsOtherAxis(step: frameStep(), in: snap(row), vertical: true))
        // 横長でも縦に積む一覧(横向きの低い一覧)は横と言わない
        let col = [el(1, id: "shelf", x: 0, y: 100, w: 2000, h: 400, scrollable: true),
                   el(2, id: "r1", x: 0, y: 100, w: 2000, h: 90), el(3, id: "r2", x: 0, y: 200, w: 2000, h: 90),
                   el(4, id: "r3", x: 0, y: 300, w: 2000, h: 90)]
        XCTAssertFalse(StepExecutor.scrollFrameRunsOtherAxis(step: frameStep(), in: snap(col), vertical: true))
    }

    func testFailureMessageDoesNotAdviseTheVerticalOppositeForAHorizontalContainer() {
        var r = StepExecutor.ScrollSearchResult(found: false, fallback: nil, viaXCUITest: false,
                                                hintJumps: 0, swipes: 2, stoppedUnmoving: true)
        r.scrollFrameOtherAxis = true
        let m = StepExecutor.scrollNotFoundMessage(frameStep(), r, defaultMaxSwipes: 8)
        XCTAssertTrue(m.contains("scrolls horizontally"), m)
        XCTAssertTrue(m.contains("direction: .left / .right"), m)
        XCTAssertFalse(m.contains("direction: .up"), m)
    }

    /// 申告した軸が縦横比に勝つ: 2282x411 の縦の一覧(横向き)も縦の探索の候補になる
    func testDeclaredVerticalLandscapeListIsACandidateForVerticalSearch() {
        let s = SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 2400, height: 1080),
                                 elements: [el(1, id: "list_chat", x: 142, y: 480, w: 2282, h: 411,
                                               scrollable: true, actions: ["up", "down"])], truncatedCount: 0)
        XCTAssertEqual(StepExecutor.directionMatchedScrollFrameCandidate(in: s, vertical: true), "#list_chat")
    }
}
