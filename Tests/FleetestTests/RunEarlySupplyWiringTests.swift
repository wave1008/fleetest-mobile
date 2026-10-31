// `fleetest run --profile` はビルドが要る回だけ、ビルドの前に準備の段(供給)を起こしてビルドと並行に進める。
// **型では守れない継ぎ目**: 準備の段をビルドの後へ動かしても、`early:` を渡し忘れても、緑のまま直列に戻る。

import XCTest

final class RunEarlySupplyWiringTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func code(_ path: String) throws -> [String] {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.hasPrefix("//") }
    }

    func testRunPreparesTheSupplyBeforeTheBuildOnlyWhenTheBuildIsNeeded() throws {
        let lines = try code("Sources/fleetest/Fleetest.swift")
        func index(_ needle: String) -> Int? { lines.firstIndex { $0.contains(needle) } }
        let prepare = try XCTUnwrap(index("ProfileRunner.prepareSupply("), "run が準備の段を呼んでいない")
        let build = try XCTUnwrap(index("try ScenarioHost.build(project: testProject"), "走査がビルドの呼び出しに届いていない")
        XCTAssertLessThan(prepare, build, "準備の段がビルドの後にある(並行にならない)")
        // ビルドが要らない回は一覧の後に正確な本数で絞るので、門は buildNeeded。--failed は開始スクリプトを空撃ちしない
        let gate = try XCTUnwrap(lines[..<prepare].lastIndex { $0.hasPrefix("if let profile = common.profile, !dryRun, !common.skipBuild") },
                                 "準備の段の門が無い")
        XCTAssertTrue(lines[gate].contains("ScenarioHost.buildNeeded(project: testProject)"), lines[gate])
        XCTAssertTrue(lines[gate].contains("!failed"), lines[gate])
        XCTAssertEqual(lines.filter { $0.contains("early: earlySupply") }.count, 1, "ProfileRunner.run へ準備の段を渡していない")
    }

    /// 準備の段の片付けは、どの経路で抜けても供給のタスクを待ってから(defer の中では待てない)。`api run` も同じ
    func testBothEntryPointsFinishTheExitGuardOnEveryExit() throws {
        for path in ["Sources/fleetest/Fleetest.swift", "Sources/fleetest/ApiRunCommand.swift"] {
            let lines = try code(path)
            XCTAssertEqual(lines.filter { $0.hasPrefix("try await RunExitGuard.run(log:") && $0.contains("runBody(runExit:") }.count, 1,
                           "\(path): 本体を RunExitGuard の中で走らせていない")
            XCTAssertTrue(lines.contains { $0.hasPrefix("runExit.removeProgress = ") }, "\(path): 進捗の控えを出口へ渡していない(ロックより先に消える)")
            XCTAssertFalse(lines.contains { $0.contains("defer") && $0.contains("runExit.") }, "\(path): defer で片付けている(待てない)")
            XCTAssertTrue(lines.contains { $0.hasPrefix("runExit.stopInterruptRelay = ") }, "\(path): 中断の登録を出口へ渡していない")
        }
    }

    /// `api run` の片付けは `SupplyCleanup` の1箇所(defer に戻すと供給を待たず、順序も `run` と割れる)
    func testApiRunCleansUpThroughTheSupplyCleanup() throws {
        let lines = try code("Sources/fleetest/ApiRunCommand.swift")
        XCTAssertEqual(lines.filter { $0.hasPrefix("runExit.settle = ") }.count, 1, "供給のタスクを出口へ渡していない")
        XCTAssertFalse(lines.contains { $0.contains("WorkersTask?.cancel()") }, "レーンは cancel を見ず、sleep の待ちだけが消える")
        XCTAssertEqual(lines.filter { $0.contains("isStopped: shouldStop") }.count, 2, "供給のレーンへ放棄の印を渡していない")
        XCTAssertEqual(lines.filter { $0.hasPrefix("runExit.close = ") }.count, 1, "片付けを出口へ渡していない")
        let body = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("private func runBody(runExit:") })
        let end = try XCTUnwrap(lines[body...].firstIndex { $0.hasPrefix("private func dispatchToRemoteHost") })
        for needle in ["RunHookRunner.end(", "servicesSession?.down", "ProfileWorkerFactory.restoreAnimations(",
                       "ResponseMeasurementMonitorHold.release(", "supplyLease?.release()"] {
            XCTAssertFalse(lines[body..<end].contains { $0.contains(needle) }, "本体に片付けが残っている: \(needle)")
        }
    }

    /// 供給の準備で落ちた回も JUnit を書く(ビルド・一覧の失敗と同じ。書かないと CI が「レポートが無い」で止まる)
    func testSupplyFailureBeforeTheBuildWritesJUnit() throws {
        let lines = try code("Sources/fleetest/Fleetest.swift")
        let write = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("writeJUnitForEarlyFailure(") && $0.contains("\"device supply\"") })
        let resolve = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("let full = try ProfileRunner.resolveFullProfile(") })
        let opener = try XCTUnwrap(lines[..<resolve].lastIndex { !$0.isEmpty })
        XCTAssertEqual(lines[opener], "do {", "プロファイルの解決(appPath の原本のステージング)の失敗を JUnit へ載せていない")
        XCTAssertLessThan(resolve, write)
        XCTAssertEqual(lines[write - 1], "if !(error is RunInterruptedBeforeStartError) {", "中断は CI の失敗ではない")
    }

    /// 早期の供給を使わない回(ビルド不要)も同じ出口へ載せる(本体の defer で片付けると供給を待たず、ロックも先に外れる)
    func testProfileRunnerHandsItsOwnSupplyToTheExitGuard() throws {
        let lines = try code("Sources/fleetest/ProfileRunner.swift")
        XCTAssertTrue(lines.contains("runExit.settle = { await prepared.settle() }"))
        XCTAssertTrue(lines.contains("runExit.close = { prepared.close() }"))
        XCTAssertFalse(lines.contains { $0.hasPrefix("defer") && $0.contains("prepared.close()") })
        let mark = try XCTUnwrap(lines.firstIndex(of: "runExit.supplyAbandon.mark()"), "Android の失敗で iOS の供給を止めていない")
        XCTAssertEqual(lines[mark + 1], "await prepared.settle()")
    }

    /// iOS のレーンはインストールの前で止まる(ここを過ぎると数分かかる供給を出口が待つ)
    func testTheIOSLaneStopsBeforeInstalling() throws {
        let lines = try code("Sources/fleetest/ProfileSupplyLanes.swift")
        let install = try XCTUnwrap(lines.firstIndex { $0.contains("try await ProfileWorkerFactory.installIfNeeded(") && $0.hasPrefix("ws = ") })
        XCTAssertTrue(lines[(install - 6)..<install].contains("if isStopped() {"))
    }

    /// 既に中断済みの run の終了スクリプトは止めない(起動の直後に SIGTERM で止まり、控えも消える)
    func testTheTeardownScriptIsNotStoppedByTheInterruptedRun() throws {
        let lines = try code("Sources/fleetest/RunHookRunner.swift")
        XCTAssertTrue(lines.contains("lease: session.lease, interrupt: teardownInterrupt(session.interrupt), log: log)"))
        XCTAssertTrue(lines.contains("interrupt: teardownInterrupt(interrupt), log: log)"), "setup の失敗の片付けも同じ")
    }
}
