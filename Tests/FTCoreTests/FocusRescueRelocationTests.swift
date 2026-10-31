// 焦点の救済(`InputFocusRescue`)が、キーボードで押し上げられた画面でも別の欄を選ばないことと、
// IME アクション(改行)の後に叩いた欄へ戻らないこと、座標ドラッグの始点が左右の戻る帯を避けることの固定。

import XCTest
@testable import FTCore

final class FocusRescueRelocationTests: XCTestCase {

    private func element(ref: Int, type: String, id: String?, y: Double, focused: Bool? = nil) -> ElementInfo {
        var e = ElementInfo(ref: ref, type: type, identifier: id, label: nil, value: nil, placeholder: nil,
                            enabled: true, frame: FTRect(x: 0, y: y, width: 1000, height: 140), depth: 1)
        e.focused = focused
        return e
    }

    /// Flutter: 叩いたのは容器(id 付き)。キーボードで一覧が 260 押し上がり、焦点のある姓は新しい枠の中。
    /// 叩いた時点の枠のままだと姓の中心が枠の外 =「焦点はよそ」となり、古い枠に入った隣の欄(名)を選んだ
    func testShiftedContainerKeepsFocusInsideAndPicksNoNeighbour() {
        let tapped = element(ref: 2, type: "other", id: "field_first", y: 1200)
        let shiftedContainer = element(ref: 12, type: "other", id: "field_first", y: 940)
        let shiftedField = element(ref: 13, type: "textField", id: nil, y: 940, focused: true)
        let neighbourInOldFrame = element(ref: 14, type: "textField", id: nil, y: 1200)
        let tree = [shiftedContainer, shiftedField, neighbourInOldFrame]

        XCTAssertFalse(InputFocusRescue.focusIsElsewhere(from: tapped, in: tree),
                       "焦点は叩いた容器(新しい枠)の中にある")
        XCTAssertEqual(InputFocusRescue.fieldToType(after: tapped, in: tree)?.ref, 13,
                       "新しい枠の中の欄を選ぶ(古い枠に入った隣の欄 14 ではない)")
    }

    /// 同じ id が2つあれば決められないので、叩いた時点の枠のまま(推測しない)
    func testAmbiguousIdFallsBackToTheTappedFrame() {
        let tapped = element(ref: 2, type: "other", id: "dup", y: 1200)
        let a = element(ref: 3, type: "other", id: "dup", y: 100)
        let b = element(ref: 4, type: "other", id: "dup", y: 500)
        XCTAssertEqual(InputFocusRescue.currentFrame(of: tapped, in: [a, b])?.y, 1200)
    }

    /// inapp F7: 叩いた行(id 付き)が遷移後の木に居ない。焦点が無いとき、旧画面の枠に重なった無関係な欄を選ばない
    func testGoneTappedElementPicksNoFieldFromItsOldFrame() {
        let tapped = element(ref: 2, type: "button", id: "nav_inputs", y: 300)
        let unrelatedField = element(ref: 7, type: "textField", id: "field_auto", y: 300)
        XCTAssertNil(InputFocusRescue.currentFrame(of: tapped, in: [unrelatedField]))
        XCTAssertNil(InputFocusRescue.fieldToType(after: tapped, in: [unrelatedField]),
                     "叩いた要素が木に無い = 画面が変わった。旧い枠で入れ先を推測しない")
    }

    /// 叩いた要素が消え、別の欄に焦点があるなら、救済せずその焦点へ送る(検索ボタン → 検索欄の形)
    func testGoneTappedElementWithFocusElsewhereIsNotRescued() {
        let tapped = element(ref: 2, type: "button", id: "search_btn", y: 300)
        let focusedField = element(ref: 9, type: "textField", id: "search_field", y: 50, focused: true)
        XCTAssertFalse(InputFocusRescue.focusIsElsewhere(from: tapped, in: [focusedField]))
    }

    /// id の無い叩いた要素は従来どおり叩いた時点の枠で救済する(緑の普通の入力を赤にしない)
    func testTappedElementWithoutIdKeepsItsFrame() {
        let tapped = element(ref: 2, type: "other", id: nil, y: 300)
        let field = element(ref: 7, type: "textField", id: nil, y: 300)
        XCTAssertEqual(InputFocusRescue.fieldToType(after: tapped, in: [field])?.ref, 7)
    }

    func testSideBandMovesStartInsideAndLeavesOthers() {
        let screen = FTRect(x: 0, y: 0, width: 1080, height: 2400)
        let left = ScrollGeometry.clearingSideGestureBand(x: 3, viewport: screen, left: 40, right: 40)
        XCTAssertEqual(left.x, 41); XCTAssertTrue(left.moved)
        let right = ScrollGeometry.clearingSideGestureBand(x: 1078, viewport: screen, left: 40, right: 40)
        XCTAssertEqual(right.x, 1039); XCTAssertTrue(right.moved)
        let middle = ScrollGeometry.clearingSideGestureBand(x: 500, viewport: screen, left: 40, right: 40)
        XCTAssertEqual(middle.x, 500); XCTAssertFalse(middle.moved)
        let off = ScrollGeometry.clearingSideGestureBand(x: 3, viewport: screen, left: 0, right: 0)
        XCTAssertEqual(off.x, 3); XCTAssertFalse(off.moved)
    }

    private final class Recording: AppDriver, @unchecked Sendable {
        let elements: [ElementInfo]
        private(set) var typedRefs: [Int?] = []
        var verifiesTypedText = true
        init(elements: [ElementInfo]) { self.elements = elements }
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "-", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws -> String? { nil }
        func uninstall(bundleID: String) async throws {}
        func launch(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { true }
        func foregroundAppID() async throws -> String? { nil }
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 1080, height: 2400),
                             elements: elements, truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws { typedRefs.append(ref) }
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    /// IME アクション(改行)で焦点は次の欄へ移りうる: 改行入りの type の後のロケータなし type は、叩いた欄へ戻さない
    func testTypeWithNewlineForgetsTheTappedField() async throws {
        let container = element(ref: 8, type: "other", id: "first", y: 417)
        let field = element(ref: 9, type: "textField", id: "inner", y: 417)
        let driver = Recording(elements: [container, field])
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "first"), timeout: 1))
        _ = await executor.execute(FlowStep(action: "type", text: "a\n"))
        _ = await executor.execute(FlowStep(action: "type", text: "b"))
        XCTAssertEqual(driver.typedRefs, [nil, nil], "2本目が叩いた欄(ref 9)へ回った: \(driver.typedRefs)")
    }
}
