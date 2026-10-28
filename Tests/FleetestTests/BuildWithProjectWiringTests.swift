// `--build-with-project`(複数対象の run のリモートの子の先行ビルド)の配線。型の効かない継ぎ目なので走査で固定する:
// 手元の中継役(`fleetest run --runner M` / `api run --runner M`)が RemoteRunDispatcher へ渡すこと、
// 子のビルドの箇所(run / api run)が `ScenarioHost.prebuildTogether` を通すこと。落とすと黙って子 run ごとにビルドする

import XCTest

final class BuildWithProjectWiringTests: XCTestCase {

    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/fleetest/\(name)"), encoding: .utf8)
    }

    func testBothEntriesRelayAndPrebuild() throws {
        for name in ["Fleetest.swift", "ApiRunCommand.swift"] {
            let text = try source(name)
            XCTAssertTrue(text.contains("buildWithProjects: common.buildWithProjects"), "\(name) が中継していない")
            XCTAssertTrue(text.contains("ScenarioHost.prebuildTogether("), "\(name) のビルドが先行ビルドを通していない")
            XCTAssertTrue(text.contains("ScenarioHost.projects(named: common.buildWithProjects)"), "\(name)")
        }
    }

    func testMultiTargetParentPassesTheProjects() throws {
        let text = try source("MultiTargetRunner.swift")
        XCTAssertTrue(text.contains("buildWithProjects: MultiTargetRunner.projectsAlsoOn("))
        XCTAssertTrue(text.contains("ScenarioHost.prebuildTogether(projects: projects"))
    }
}
