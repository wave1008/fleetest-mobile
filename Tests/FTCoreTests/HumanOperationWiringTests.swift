import XCTest

/// 人のライブ操作の台帳を結果へ載せる配線(型の効かない継ぎ目)をソース走査で縛る。台帳・整形の中身は
/// `HumanOperationLedgerTests`。渡し忘れは緑のまま通る(欄が黙って欠ける)ので、ここで落とす
final class HumanOperationWiringTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// 記録の確定点(起動前の失敗・タイムアウト・通常終了)は全部、台帳から引いた操作を builder へ渡す
    func testEveryRecordingPointOfScenarioHostPassesHumanOperations() throws {
        let code = try source("Sources/FTCore/ScenarioHost.swift")
        XCTAssertEqual(count("recording.recorder.record(", in: code), 3, "確定点の数が変わった — このテストと配線を見直すこと")
        XCTAssertEqual(count("builder.build(", in: code), 3)
        XCTAssertEqual(count("humanOperations: humanOperations()", in: code), 2)
        XCTAssertEqual(count("humanOperations: operations", in: code), 1)
        // 通常終了は引いた値を patch にも使うので一度変数に受ける。**引くこと自体**も3回(空の配列で置き換えると落ちる)
        XCTAssertEqual(count("humanOperations()", in: code), 3, "確定点3つが毎回台帳を引く")
        XCTAssertTrue(code.contains("HumanOperationLedger.entries("))
        XCTAssertTrue(code.contains("connection.serial ?? connection.udid"), "鍵は run-lease と同じ")
        XCTAssertTrue(code.contains("HumanOperationReport.patch("))
    }

    /// ScenarioRecording を作る箇所は全部、台帳の置き場を渡す(runOne の素通しを含む)
    func testEveryScenarioRecordingCarriesTheLedgerLocation() throws {
        for path in ["Sources/fleetest/ApiRunCommand.swift", "Sources/FTCore/RunOrchestrator.swift"] {
            let code = try source(path)
            let constructions = count("ScenarioRecording(", in: code)
            XCTAssertGreaterThan(constructions, 0, path)
            XCTAssertGreaterThanOrEqual(count("humanOperationsStateDir:", in: code), constructions, path)
        }
        let apiRun = try source("Sources/fleetest/ApiRunCommand.swift")
        XCTAssertEqual(count("humanOperationsStateDir: HumanOperationStateDir.current", in: apiRun),
                       count("ScenarioRecording(", in: apiRun))
    }

    /// runOne / RunOrchestrator を呼ぶ run の経路(プロファイル・プロファイル無し)も置き場を渡す
    func testRunPathsInjectTheLedgerLocation() throws {
        let fleetest = try source("Sources/fleetest/Fleetest.swift")
        XCTAssertEqual(count("humanOperationsStateDir: HumanOperationStateDir.current", in: fleetest), 2,
                       "`run`(プロファイル無し)の runOne と RunOrchestrator")
        let profile = try source("Sources/fleetest/ProfileRunOrchestrator.swift")
        XCTAssertTrue(profile.contains("humanOperationsStateDir: repoRoot.appendingPathComponent(\".fleetest\")"))
        let orchestrator = try source("Sources/FTCore/RunOrchestrator.swift")
        XCTAssertTrue(orchestrator.contains("humanOperationsStateDir: humanOperationsStateDir,"),
                      "runOne へ素通しすること")
    }

    /// 子が台帳を書けない
    func testSandboxDeniesTheLedgerDirectory() throws {
        XCTAssertTrue(try source("Sources/FTCore/ScenarioSandbox.swift").contains("\"human-ops\""))
    }
}
