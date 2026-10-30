import XCTest
import FTCore
@testable import fleetest_mcp

/// 自分の操作の後で兄弟がそろって動いた形を、スクロールと断定しない(遷移中の木)。
final class MovedTogetherTransitionTests: XCTestCase {
    private func node(_ ref: Int, _ id: String, _ x: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: "button", identifier: id, label: id, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: x, y: 100, width: 100, height: 40), depth: 3)
    }

    func testSiblingsShiftedAfterOwnActionIsNotCalledAScroll() {
        let before = [node(1, "a", 0), node(2, "b", 0), node(3, "c", 0)]
        let after = [node(11, "a", 121), node(12, "b", 121), node(13, "c", 121)]
        let plain = RefGuard.movedTogether(before[0], after[0], before: before, after: after)
        XCTAssertTrue(plain.contains("container scrolled"))
        let acted = RefGuard.movedTogether(before[0], after[0], before: before, after: after, ownActionSince: true)
        XCTAssertFalse(acted.contains("container scrolled"))
        XCTAssertTrue(acted.contains("screen transition"))
    }
}
