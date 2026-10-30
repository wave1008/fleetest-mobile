// `PointTarget.writableSelector(notDrawn:)`: 枠だけ残っている行(スクロールの残像)の上の座標は、その行のセレクタに写さない
// (再生すると送り戻して別の行を押す)。

import XCTest
@testable import FTCore

final class PointTargetNotDrawnTests: XCTestCase {

    private func element(_ ref: Int, _ type: String, id: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: x, y: y, width: w, height: h), depth: 1)
    }

    private func tree(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app", screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                         elements: elements, truncatedCount: 0)
    }

    func testAPointOnANotDrawnRowIsNotWrittenAsItsSelector() {
        let row = element(1, "button", id: "msg_54", 0, 100, 400, 56)
        XCTAssertEqual(PointTarget.writableSelector(atX: 300, y: 130, in: tree([row]))?.selector, "#msg_54")
        XCTAssertNil(PointTarget.writableSelector(atX: 300, y: 130, in: tree([row]), notDrawn: [1]))
    }

    func testAnotherElementIsStillWrittenWhenOnlyTheLeftoverIsFlagged() {
        let row = element(1, "button", id: "msg_54", 0, 100, 400, 56)
        let other = element(2, "button", id: "send", 0, 300, 100, 40)
        XCTAssertEqual(PointTarget.writableSelector(atX: 50, y: 320, in: tree([row, other]), notDrawn: [1])?.selector, "#send")
    }
}
