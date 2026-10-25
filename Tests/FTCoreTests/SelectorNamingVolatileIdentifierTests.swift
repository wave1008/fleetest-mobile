// メモリアドレス入りの id(`IOSChromeViewController<0x808a60000>`)は起動のたびに変わるので、書けるセレクタに使わない。
// witness: Apple マップ(iOS)の地図の上に重なる浮いた操作部品の入れ物。ライブ操作の操作記録がこの id を勧めた

import XCTest
@testable import FTCore

final class SelectorNamingVolatileIdentifierTests: XCTestCase {

    private func element(_ ref: Int, _ type: String, id: String? = nil, label: String? = nil,
                         _ frame: FTRect, depth: Int = 1) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil, placeholder: nil,
                    enabled: true, frame: frame, depth: depth)
    }

    private func tree(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app", screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                         elements: elements, truncatedCount: 0)
    }

    func testAddressesAreNotWritableButShortHexValuesAre() {
        XCTAssertFalse(SelectorNaming.isWritableIdentifier(
            "IOSChromeViewController<0x808a60000>.IOSFloatingControlsViewController<0x809d30600>"))
        XCTAssertFalse(SelectorNaming.isWritableIdentifier("cell_0x1234abcdef"))
        XCTAssertTrue(SelectorNaming.isWritableIdentifier("swatch_0xFF336699"), "8桁(色の値)は外さない")
        XCTAssertTrue(SelectorNaming.isWritableIdentifier("MapsSearchTextField"))
        XCTAssertFalse(SelectorNaming.isWritableIdentifier(""))
    }

    /// アドレス入りの id は候補にせず、ラベルへ回す
    func testVolatileIDFallsBackToTheLabel() {
        let button = element(1, "button", id: "Controls<0x808a60000>", label: "Locate", FTRect(x: 10, y: 10, width: 40, height: 40))
        let snapshot = tree([button])
        XCTAssertEqual(SelectorNaming(snapshot).graded(for: button, in: snapshot)?.selector, "Locate")
    }

    /// アドレス入りの id を持つ祖先をスコープ(`#容器 >> …`)にしない
    func testVolatileAncestorIsNotUsedAsAScope() {
        let container = element(1, "other", id: "Panel<0x808a60000>", FTRect(x: 0, y: 0, width: 400, height: 200), depth: 1)
        let a = element(2, "button", label: "OK", FTRect(x: 10, y: 10, width: 50, height: 40), depth: 2)
        let b = element(3, "button", label: "OK", FTRect(x: 100, y: 10, width: 50, height: 40), depth: 2)
        let snapshot = tree([container, a, b])
        let selector = SelectorNaming(snapshot).graded(for: a, in: snapshot)?.selector ?? ""
        XCTAssertFalse(selector.contains("0x808a60000"), selector)
    }

    /// scrollFrame: の候補もアドレス入りの id を勧めない(ラベルへ回す)
    func testScrollFrameCandidateSkipsVolatileID() {
        let list = element(1, "table", id: "List<0x808a60000>", label: "Results", FTRect(x: 0, y: 0, width: 400, height: 600))
        XCTAssertEqual(ScrollFrameCandidates.selector(for: list), "Results")
    }
}
