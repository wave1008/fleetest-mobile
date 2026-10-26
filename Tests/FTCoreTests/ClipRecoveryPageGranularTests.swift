// 見切れの戻し(runScrollSearch の isClippedByViewport)を、in-app の自前描画では距離どおりのドラッグで寄せる。
// witness: E2EY-CMP の反転チャット(iOS in-app)で、容器の下端の外の #msg_40 を戻す1本が a11y の scroll = 1ページになり、
// 逆側へ飛び越して往復し 8 本を使い切った(1/5)

import XCTest
@testable import FTCore

final class ClipRecoveryPageGranularTests: XCTestCase {

    private func el(_ ref: Int, _ id: String, _ frame: FTRect, scrollable: Bool? = nil) -> ElementInfo {
        ElementInfo(ref: ref, type: "other", identifier: id, label: id, value: nil, placeholder: nil,
                    enabled: true, frame: frame, depth: 1, scrollable: scrollable)
    }

    /// 1枚目: 容器(200〜600)の下端で見切れた行 / 2枚目以降: 容器の中へ入った行
    private func run(_ framework: AppUIFramework) async -> FakeAppDriver {
        let list = el(1, "list_chat", FTRect(x: 0, y: 200, width: 400, height: 400), scrollable: true)
        let clipped = el(2, "msg_40", FTRect(x: 0, y: 580, width: 400, height: 56))
        let inside = el(2, "msg_40", FTRect(x: 0, y: 500, width: 400, height: 56))
        let primary = FakeAppDriver(name: "primary", log: CallLog(),
                                    snapshotElements: [[list, clipped], [list, clipped], [list, inside]])
        let typeDriver = FakeAppDriver(name: "typedriver", log: CallLog(), snapshotElements: [[]])
        var step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "msg_40"), direction: "up", maxSwipes: 4)
        step.scrollFrame = FlowLocator(id: "list_chat")
        _ = await StepExecutor(driver: primary, typeDriver: typeDriver, isAndroid: false, tunables: RunTunables(),
                               uiFramework: framework).execute(step)
        return primary
    }

    func testSelfRenderedInAppRecoversTheClipWithADistanceDrag() async {
        let primary = await run(.compose)
        XCTAssertFalse(primary.dragCalls.isEmpty, "見切れの戻しが距離のドラッグになっていない: \(primary.log.entries)")
        XCTAssertFalse(primary.log.entries.contains("primary.swipe"), "1ページ送りの払いで戻している")
    }

    /// 縁にぴったり(浮動小数の一致で見切れ扱い・戻す量が無い)なら見つかったとする。実測は下端 766.67 = 容器の下端
    func testSelfRenderedInAppAcceptsAMatchFlushWithTheEdge() async {
        let list = el(1, "list_chat", FTRect(x: 0, y: 200, width: 400, height: 400.0000001), scrollable: true)
        let flush = el(2, "msg_40", FTRect(x: 0, y: 544, width: 400, height: 56.0000002))
        let primary = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[list, flush]])
        var step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "msg_40"), direction: "up", maxSwipes: 4)
        step.scrollFrame = FlowLocator(id: "list_chat")
        let outcome = await StepExecutor(driver: primary, typeDriver: FakeAppDriver(name: "td", log: CallLog()),
                                         isAndroid: false, tunables: RunTunables(), uiFramework: .flutter).execute(step)
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertTrue(primary.dragCalls.isEmpty && !primary.log.entries.contains("primary.swipe"),
                      "\(primary.log.entries)")
    }

    /// 戻す量が小さい(40 未満)見切れも、1ページの払いでなく広げたドラッグで寄せる
    func testSelfRenderedInAppDragsASmallClipInsteadOfPaging() async {
        let list = el(1, "list_chat", FTRect(x: 0, y: 200, width: 400, height: 400), scrollable: true)
        let small = el(2, "msg_40", FTRect(x: 0, y: 194, width: 400, height: 56))   // 上へ 6 はみ出す
        let inside = el(2, "msg_40", FTRect(x: 0, y: 260, width: 400, height: 56))
        let primary = FakeAppDriver(name: "primary", log: CallLog(),
                                    snapshotElements: [[list, small], [list, small], [list, inside]])
        var step = FlowStep(action: "scrollTo", locator: FlowLocator(id: "msg_40"), direction: "down", maxSwipes: 4)
        step.scrollFrame = FlowLocator(id: "list_chat")
        _ = await StepExecutor(driver: primary, typeDriver: FakeAppDriver(name: "td", log: CallLog()),
                               isAndroid: false, tunables: RunTunables(), uiFramework: .compose).execute(step)
        XCTAssertFalse(primary.dragCalls.isEmpty, "\(primary.log.entries)")
        XCTAssertFalse(primary.log.entries.contains("primary.swipe"), "小さい見切れを1ページの払いで戻している")
    }

    func testSwiftUIKeepsTheContainerSwipe() async {
        let primary = await run(.swiftUI)
        XCTAssertTrue(primary.log.entries.contains("primary.swipe"), "SwiftUI は容器基準の短い送りのまま(置き換えると退行する)")
    }

    /// XCUITest で撃つ構成(in-app でない)でも、縁を浮動小数で割っただけの要素は見切れと数えない。
    /// witness: E2EX-Flutter のグリッド(xcuitest モード)で、容器の上端 170 に `#cell_46` が y=169.99998(見えている部分に
    /// 切り詰めた枠)で出て、極小の戻しが全力の送りへ落ちて飛び越し、流れて消えた
    func testAMatchThatSplitsTheEdgeByRoundingIsFoundWithoutAnotherSwipe() async {
        let grid = el(1, "grid_main", FTRect(x: 0, y: 170, width: 402, height: 704), scrollable: true)
        let cell = ElementInfo(ref: 2, type: "button", identifier: "cell_46", label: "セル 46", value: nil, placeholder: nil,
                               enabled: true, frame: FTRect(x: 134, y: 169.99998982747397, width: 134, height: 132.0486755371094),
                               depth: 2)
        let primary = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[grid, cell]])
        let outcome = await StepExecutor(driver: primary, isAndroid: false, tunables: RunTunables(), uiFramework: .flutter)
            .execute(FlowStep(action: "scrollTo", locator: FlowLocator(id: "cell_46"), direction: "down", maxSwipes: 4))
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertFalse(primary.log.entries.contains { $0.hasPrefix("primary.swipe") }, "\(primary.log.entries)")
        XCTAssertTrue(primary.dragCalls.isEmpty, "\(primary.log.entries)")
    }

    /// 許容は 0.5 まで: それを超えるはみ出しは本物の見切れ
    func testClipToleranceIsHalfAPointAndRealClipsStillCount() {
        let viewport = FTRect(x: 0, y: 170, width: 402, height: 704)
        func clipped(_ y: Double) -> Bool {
            TapTargetGeometry.isClippedByViewport(el(1, "c", FTRect(x: 0, y: y, width: 134, height: 134)), screen: viewport)
        }
        XCTAssertEqual(TapTargetGeometry.clipTolerance, 0.5)
        XCTAssertFalse(clipped(169.99998))
        XCTAssertFalse(clipped(170 - 1.0 / 3))
        XCTAssertTrue(clipped(169.4))
        XCTAssertTrue(clipped(170 + 704 - 134 + 0.6))
        XCTAssertFalse(clipped(170 + 704 - 134 + 0.4))
    }
}
