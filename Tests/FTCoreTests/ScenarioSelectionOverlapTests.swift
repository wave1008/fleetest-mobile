// `--scenario` の重なり(同じ ID の二重・クラス名とそのメソッド)の重複排除と、全部 draft のクラスの文言。

import XCTest
@testable import FTCore

final class ScenarioSelectionOverlapTests: XCTestCase {
    private func info(_ id: String, deleted: Bool = false, draft: Bool = false) -> ScenarioInfo {
        ScenarioInfo(id: id, title: id, platform: nil, deleted: deleted, draft: draft)
    }

    private lazy var all: [ScenarioInfo] = [info("A.S0010"), info("A.S0020"), info("B.S0010")]

    func testClassAndItsMethodSelectEachScenarioOnce() throws {
        let ids = try ScenarioSelection.resolve(["A", "A.S0010"], from: all).map(\.id)
        XCTAssertEqual(ids, ["A.S0010", "A.S0020"])
    }

    func testMethodThenItsClassKeepsFirstPosition() throws {
        let ids = try ScenarioSelection.resolve(["A.S0020", "A"], from: all).map(\.id)
        XCTAssertEqual(ids, ["A.S0020", "A.S0010"])
    }

    func testSameIDTwiceSelectsOnce() throws {
        let ids = try ScenarioSelection.resolve(["B.S0010", "B.S0010"], from: all).map(\.id)
        XCTAssertEqual(ids, ["B.S0010"])
    }

    /// 畳んだことは言う(黙ると、繰り返しのつもりで2回並べた人が知らないまま標本が半分になる)
    func testCollapsedDuplicatesAreNamed() throws {
        XCTAssertEqual(try ScenarioSelection.resolveReportingCollapsed(["B.S0010", "B.S0010"], from: all).collapsed,
                       ["B.S0010"])
        XCTAssertEqual(try ScenarioSelection.resolveReportingCollapsed(["A", "A.S0010"], from: all).collapsed,
                       ["A.S0010"])
        XCTAssertEqual(try ScenarioSelection.resolveReportingCollapsed(["A", "B"], from: all).collapsed, [])
        XCTAssertNil(ScenarioSelection.collapsedNotice([]))
        let notice = ScenarioSelection.collapsedNotice(["B.S0010"])
        XCTAssertTrue(notice?.contains("named more than once and run only once: B.S0010") == true, notice ?? "nil")
    }

    func testAllDraftClassDoesNotMentionDeleted() {
        let drafts = [info("D.S0010", draft: true), info("D.S0020", draft: true)]
        XCTAssertThrowsError(try ScenarioSelection.resolve(["D"], from: drafts)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("draft"), message)
            XCTAssertFalse(message.contains("deleted"), message)
        }
    }

    func testMixedDeletedAndDraftClassMentionsBoth() {
        let mixed = [info("M.S0010", deleted: true), info("M.S0020", draft: true)]
        XCTAssertThrowsError(try ScenarioSelection.resolve(["M"], from: mixed)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("deleted") && message.contains("draft"), message)
        }
    }
}
