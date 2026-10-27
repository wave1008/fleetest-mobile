// 操作の対象を解決したとき、セレクタが2件以上に一致した数を StepOutcome に載せる(ft_batch が行に添える)。
// 序数の指定は利用者が1つを選んでいるので数えない

import XCTest
@testable import FTCore

final class AmbiguousMatchCountTests: XCTestCase {

    private func okButton(ref: Int, y: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: "button", identifier: nil, label: "OK", value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 10, y: y, width: 100, height: 40), depth: 1)
    }

    func testDuplicateLabelIsCounted() async {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log,
                                   snapshotElements: [[okButton(ref: 1, y: 100), okButton(ref: 2, y: 300)]])
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .execute(FlowStep(action: "tap", locator: FlowLocator(label: "OK")))
        XCTAssertEqual(outcome.ambiguousMatchCount, 2)
    }

    func testOrdinalSelectorIsNotCounted() async {
        let log = CallLog()
        let driver = FakeAppDriver(name: "primary", log: log,
                                   snapshotElements: [[okButton(ref: 1, y: 100), okButton(ref: 2, y: 300)]])
        let outcome = await StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
            .execute(FlowStep(action: "tap", locator: FlowLocator(label: "OK", index: 1)))
        XCTAssertNil(outcome.ambiguousMatchCount)
    }

    private func element(_ ref: Int, _ type: String, depth: Int, y: Double, height: Double = 40) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: nil, label: "メディア 12", value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 10, y: y, width: 300, height: height), depth: depth)
    }

    /// **行とその中のラベル(同じ鎖・操作できるのは行だけ)は1件に数える**(実機: tap 'メディア 12' に毎回「2件に一致」)
    func testRowAndItsOwnLabelAreNotCountedTwice() async {
        let driver = FakeAppDriver(name: "primary", log: CallLog(),
                                   snapshotElements: [[element(1, "clickable", depth: 1, y: 100),
                                                       element(2, "staticText", depth: 2, y: 110, height: 20)]])
        let outcome = await StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())
            .execute(FlowStep(action: "tap", locator: FlowLocator(label: "メディア 12")))
        XCTAssertNil(outcome.ambiguousMatchCount)
    }

    /// 鎖に操作できる要素が2つ(面と中のボタン)なら別の動作になりうるので数える。鎖の外の同名も数える
    func testNestedOperablesAndOtherRowsAreStillCounted() async {
        let nested = FakeAppDriver(name: "primary", log: CallLog(),
                                   snapshotElements: [[element(1, "clickable", depth: 1, y: 100, height: 400),
                                                       element(2, "button", depth: 2, y: 300)]])
        let nestedOutcome = await StepExecutor(driver: nested, isAndroid: true, tunables: RunTunables())
            .execute(FlowStep(action: "tap", locator: FlowLocator(label: "メディア 12")))
        XCTAssertEqual(nestedOutcome.ambiguousMatchCount, 2)
        let twoRows = FakeAppDriver(name: "primary", log: CallLog(),
                                    snapshotElements: [[element(1, "clickable", depth: 1, y: 100),
                                                        element(2, "staticText", depth: 2, y: 110, height: 20),
                                                        element(3, "clickable", depth: 1, y: 300),
                                                        element(4, "staticText", depth: 2, y: 310, height: 20)]])
        let twoRowsOutcome = await StepExecutor(driver: twoRows, isAndroid: true, tunables: RunTunables())
            .execute(FlowStep(action: "tap", locator: FlowLocator(label: "メディア 12")))
        XCTAssertEqual(twoRowsOutcome.ambiguousMatchCount, 3, "鎖の外の行2件(と中のラベル)= 1 + 2")
    }
}
