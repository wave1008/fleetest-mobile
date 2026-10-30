// 中心が画面の上端より上の行へ ref で撃つと、iOS はその点がステータスバーへ寄って一覧が先頭へ戻る(実測 9/9 で効いた)。
// 警告が「何も起きない」と言い切ると効いた事実と食い違うので、上端の外だけ文言を分ける。下端の外は従来どおり。

import XCTest
import FTCore
@testable import fleetest_mcp

final class OffscreenTopStatusBarWarningTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    private func element(y: Double) -> ElementInfo {
        ElementInfo(ref: 1, type: "button", identifier: "row_02", label: nil, value: nil,
                    placeholder: nil, enabled: true,
                    frame: FTRect(x: 16, y: y, width: 370, height: 56), depth: 2, scrollable: nil)
    }

    func testAboveTheTopEdgeDoesNotClaimNothingHappened() {
        let w = RefGuard.offscreenWarning(element(y: -40), screen: screen)
        XCTAssertTrue(w.contains("outside the visible screen"), w)
        XCTAssertTrue(w.contains("status bar"), w)
        XCTAssertFalse(w.contains("did nothing"), "上端の外は効く場合がある: \(w)")
    }

    func testBelowTheBottomEdgeKeepsTheOriginalWording() {
        let w = RefGuard.offscreenWarning(element(y: 900), screen: screen)
        XCTAssertTrue(w.contains("almost certainly did nothing"), w)
        XCTAssertFalse(w.contains("status bar"), w)
    }
}
