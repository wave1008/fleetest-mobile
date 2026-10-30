// 横の容器の左右の縁で切れ、中心が容器の外に落ちる要素の警告(`TapTargetGeometry.straddleAdvisory` の横版)。
// 実機 SE3 の横カルーセル: タグ 09 (-28,499 81x62) の中心 x=12 は容器 (16,502 343x56) の左端より外。

import XCTest
@testable import FTCore

final class SideEdgeCentreAdvisoryTests: XCTestCase {

    private let container = FTRect(x: 16, y: 502, width: 343, height: 56)

    private func tree(tagX: Double) -> [ElementInfo] {
        [
            ElementInfo(ref: 1, type: "scrollView", identifier: "carousel", label: nil, value: nil,
                        placeholder: nil, enabled: true, frame: container, depth: 1, scrollable: true),
            ElementInfo(ref: 2, type: "button", identifier: "tag_09", label: "タグ 09", value: nil,
                        placeholder: nil, enabled: true,
                        frame: FTRect(x: tagX, y: 499, width: 81, height: 62), depth: 2),
        ]
    }

    func testCentreOutsideTheLeftEdgeWarns() throws {
        let elements = tree(tagX: -28)
        let target = try XCTUnwrap(elements.last)
        let text = try XCTUnwrap(TapTargetGeometry.straddleAdvisory(for: target, in: elements))
        XCTAssertTrue(text.contains("centre (12, 530)"), text)
    }

    func testCentreOutsideTheRightEdgeWarns() throws {
        let elements = tree(tagX: 330)
        let target = try XCTUnwrap(elements.last)
        XCTAssertNotNil(TapTargetGeometry.straddleAdvisory(for: target, in: elements))
    }

    /// 縁で切れていても中心が容器の中なら当たる = 黙る(カルーセルの端の項目ごとのノイズにしない)
    func testCentreInsideTheContainerStaysSilent() throws {
        let elements = tree(tagX: -10)
        let target = try XCTUnwrap(elements.last)
        XCTAssertNil(TapTargetGeometry.straddleAdvisory(for: target, in: elements))
    }

    func testFullyInsideAndFullyOutsideStaySilent() throws {
        for x in [100.0, -300.0] {
            let elements = tree(tagX: x)
            let target = try XCTUnwrap(elements.last)
            XCTAssertNil(TapTargetGeometry.straddleAdvisory(for: target, in: elements), "x=\(x)")
        }
    }
}
