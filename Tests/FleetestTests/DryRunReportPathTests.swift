import XCTest
@testable import FTCore
@testable import fleetest

/// dry-run のレポート: 明示が無ければ一時フォルダへ捨て、`scenarioFinished` に消えるパスを載せない(拡張のモニターが消えたファイルを
/// 開こうとしていた)。**レポート先を明示したら(`--report-dir` / `--set reportDir=`)そこへ書く**(黙って効かない形にしない)
final class DryRunReportPathTests: XCTestCase {
    private func finished() -> ScenarioEvent {
        var e = ScenarioEvent(kind: "scenarioFinished")
        e.reportPath = "/tmp/fleetest-dryrun-X/report.html"
        return e
    }

    func testDiscardedReportsDropThePath() {
        XCTAssertNil(ApiRun.withoutDiscardedReportPath(finished(), discarded: true).reportPath)
        XCTAssertEqual(ApiRun.withoutDiscardedReportPath(finished(), discarded: false).reportPath,
                       "/tmp/fleetest-dryrun-X/report.html")
    }

    func testExplicitReportDirIsHonouredInDryRun() {
        XCTAssertNotNil(ApiRun.dryRunDiscardDir(dryRun: true, reportDirFlag: nil, setOverrides: [], profileReportDir: nil))
        XCTAssertNil(ApiRun.dryRunDiscardDir(dryRun: true, reportDirFlag: "/tmp/x", setOverrides: [], profileReportDir: nil))
        XCTAssertNil(ApiRun.dryRunDiscardDir(dryRun: true, reportDirFlag: nil, setOverrides: ["reportDir=/tmp/y"],
                                             profileReportDir: nil))
        XCTAssertNil(ApiRun.dryRunDiscardDir(dryRun: false, reportDirFlag: nil, setOverrides: [], profileReportDir: nil))
    }

    /// 実行プロファイルの JSON に書いた reportDir も明示と同じ(一時フォルダへ捨てない = 黙って効かない形にしない)
    func testProfileDeclaredReportDirIsHonouredInDryRun() {
        XCTAssertNil(ApiRun.dryRunDiscardDir(dryRun: true, reportDirFlag: nil, setOverrides: [],
                                             profileReportDir: URL(fileURLWithPath: "/tmp/custom")))
    }

    /// 既定と同じ `reports` を明記したプロファイルも「書いた」側(パスの一致で「書いていない」と読まない)
    func testProfileThatSpellsOutTheDefaultReportDirCountsAsDeclared() {
        let project = TestProject(name: "dummy", rootURL: URL(fileURLWithPath: "/tmp/dummy"))
        func profile(declared: Bool) -> ResolvedProfile {
            var resolved = ResolvedProfile(
                project: project, runName: "P", appName: "app", apps: [:], devices: [], fm: FMConfig(), heal: false,
                reportDir: project.reportsDir, defaultTimeout: nil, scenarioTimeout: nil, wipeDataOnBloat: true,
                updateWebView: false, wipeDataThresholdGB: 8, recoverCpuFallbackToGpu: false, locale: "ja_JP",
                iosPreActionPing: true, containerInference: true, ocrTextVisibilityCheck: true,
                preferCheckStateClassifier: true, enableAnimations: false, responseMeasurement: false, responseRepeat: 5,
                homeOnStart: true, playProtectBypass: true, record: false, recordFailuresOnly: false,
                recordBitrateKbps: 1500, recordFullResolution: false, warnings: [])
            resolved.reportDirDeclared = declared
            return resolved
        }
        XCTAssertEqual(ApiRun.declaredProfileReportDir(profile(declared: true), project: project), project.reportsDir)
        XCTAssertNil(ApiRun.declaredProfileReportDir(profile(declared: false), project: project))
    }

    /// 相対の `--set reportDir=` は本物の run と同じ規則で解く: プロファイルありならプロジェクトの root 基準・なしなら素の値(cwd 基準)
    func testExplicitSetReportDirResolvesLikeARealRun() {
        let project = TestProject(name: "P", rootURL: URL(fileURLWithPath: "/tmp/ws/TestProjects/P"))
        XCTAssertEqual(ApiRun.explicitReportDir(flag: nil, setOverrides: ["heal=true", "reportDir=out"], project: project,
                                                withProfile: true),
                       "/tmp/ws/TestProjects/P/out")
        XCTAssertEqual(ApiRun.explicitReportDir(flag: nil, setOverrides: ["reportDir=out"], project: project, withProfile: false),
                       URL(fileURLWithPath: "out").path)
        XCTAssertNil(ApiRun.explicitReportDir(flag: nil, setOverrides: ["heal=true"], project: project, withProfile: true))
    }

    /// 2経路の転送がどちらもこの関数を通る(素の event をそのまま書く行を戻さない)
    func testBothSequentialForwardersStripThePath() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/fleetest/ApiRunCommand.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(code.components(separatedBy: "ApiRun.withoutDiscardedReportPath(event, discarded: dryRunReportDir != nil)")
            .count - 1, 2)
        XCTAssertFalse(code.contains("writeLine(event.encodedLine())"))
    }
}
