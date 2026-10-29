import XCTest
import FTCore
@testable import fleetest

/// `run --folder` が選択を空にした理由を言い違えない: フォルダの中が @Deleted / @Draft だけなら従来どおり exit 0 の
/// 「Nothing to run」(nil)、合致が0本・--scenario との積が空なら断る
final class EmptyFolderSelectionTests: XCTestCase {
    func testFolderOfOnlyDraftsIsNotAFolderMatchError() {
        let inFolder = [ScenarioInfo(id: "A", title: "A", draft: true), ScenarioInfo(id: "B", title: "B", deleted: true)]
        XCTAssertNil(RunScenarios.emptyFolderSelectionError(folders: ["Smoke"], scenarios: [], inFolders: inFolder))
    }

    func testNoMatchIsRefused() {
        let m = RunScenarios.emptyFolderSelectionError(folders: ["Smoke"], scenarios: [], inFolders: [])
        XCTAssertEqual(m, "no scenario to run in --folder Smoke")
    }

    func testEmptyIntersectionWithScenarioIsRefusedEvenIfTheFolderHasDrafts() {
        let inFolder = [ScenarioInfo(id: "A", title: "A", draft: true)]
        let m = RunScenarios.emptyFolderSelectionError(folders: ["Smoke"], scenarios: ["X"], inFolders: inFolder)
        XCTAssertEqual(m, "no scenario to run in --folder Smoke together with --scenario X")
    }

    /// --folder で0本のときは --failed の「前回の失敗は無い」(exit 0)へ入らず、folder の空を断る
    func testFailedBranchDoesNotSwallowAnEmptyFolderSelection() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/fleetest/Fleetest.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(code.contains("if failed, !(selected.isEmpty && !folders.isEmpty) {"),
                      "--failed の分岐が --folder の空の選択を先に受けている")
    }
}
