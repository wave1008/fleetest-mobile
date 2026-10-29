import XCTest
@testable import fleetest

/// CLI の `results slow` は `--since` の窓をそのまま集計する(summary / flaky と同じ)・
/// host-metrics-summary は逆転した窓を断る。
final class ResultsCommandWindowTests: XCTestCase {

    func testSlowCommandPassesTheWholeSinceWindow() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/fleetest/ResultsCommand.swift")
        let code = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//")[0] }.joined(separator: "\n")
        XCTAssertTrue(code.contains("slowTests(records, limit: limit, recentRuns: .max)"),
                      "slowTests に recentRuns を渡し忘れると既定の直近10回に落ちて --since が効かない")
    }

    func testHostMetricsSummaryRejectsAnInvertedWindow() throws {
        let command = try ApiHostMetricsSummaryCommand.parse(["--since", "1m", "--until", "2h", "--log", "/nonexistent"])
        XCTAssertThrowsError(try command.run()) { error in
            XCTAssertTrue("\(error)".contains("--since must not be later than --until"), "\(error)")
        }
    }
}
