// 利用者のシナリオ指定を解く入口は、重なった指定を1本にまとめたことを必ず言う(`resolveReportingCollapsed` + `collapsedNotice`)。
// 素の `resolve` で利用者の指定を解くと、黙って標本が減る(フリート・機械分担の経路で実際にそうなっていた)

import XCTest

final class CollapsedSelectionNoticeWiringTests: XCTestCase {
    func testEveryUserSelectionEntryReportsCollapsedSelectors() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/fleetest")
        var reporting: [String] = []
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        where file.pathExtension == "swift" {
            let code = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(code.contains("ScenarioSelection.resolve(scenarios"),
                           "\(file.lastPathComponent) は利用者の指定を素の resolve で解いている(まとめたことを言わない)")
            let resolves = code.components(separatedBy: "ScenarioSelection.resolveReportingCollapsed(").count - 1
            let notices = code.components(separatedBy: "ScenarioSelection.collapsedNotice(").count - 1
            XCTAssertEqual(resolves, notices, "\(file.lastPathComponent): まとめた結果を言っていない入口がある")
            if resolves > 0 { reporting.append(file.lastPathComponent) }
        }
        XCTAssertEqual(Set(reporting), ["Fleetest.swift", "ApiRunCommand.swift", "FleetRunner.swift",
                                        "DeviceMachineRunner.swift", "ApiRunMachineFanout.swift"])
    }
}
