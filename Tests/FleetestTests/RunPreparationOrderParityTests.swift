// `fleetest run` と `fleetest api run` の準備と後始末の順序。2つの手書きの実装で、緑の run ではどの順でも通る
// (フラグの一致は RunCommandFlagParityTests・受理と拒否は RunRejectionParityTests)。順序の本体は共有の関数なので、
// 走査するのは「その関数の中の順序」と「両方の入口が同じ関数を通ること」。

import XCTest

final class RunPreparationOrderParityTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func code(_ path: String) throws -> [String] {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.hasPrefix("//") && !$0.hasPrefix("///") }
    }

    private func assertOrder(_ needles: [String], in lines: ArraySlice<String>, _ label: String) throws {
        var last = lines.startIndex - 1
        for needle in needles {
            let index = try XCTUnwrap(lines.firstIndex { $0.contains(needle) }, "\(label): \(needle) が無い")
            XCTAssertGreaterThan(index, last, "\(label): \(needle) の位置")
            last = index
        }
    }

    /// 断られる run はモニターにも他人の設定にも触らない・サービスは開始スクリプトの前
    func testTheSharedPreparationKeepsItsOrder() throws {
        let lines = try code("Sources/fleetest/ProfileRunner+Supply.swift")
        let start = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("static func prepareEnvironment(") })
        let end = try XCTUnwrap(lines[start...].firstIndex { $0.hasPrefix("static func prepareSupply(") })
        try assertOrder(["rejectIfDevicesLeasedBeforePreparation(", "ResponseMeasurementMonitorHold.acquire(",
                         "captureAnimationRestore(", "ServicesSession.up(", "RunHookRunner.begin("],
                        in: lines[start..<end], "prepareEnvironment")
        XCTAssertFalse(lines[start..<end].contains { $0.contains("ConsoleOut.") }, "api run の stdout は NDJSON 専用")
    }

    /// 片付けは作った順の逆(終了スクリプトはサービスより先 = スクリプトがサービスを使って後片付けする)
    func testTheSharedCleanupKeepsItsOrder() throws {
        let lines = try code("Sources/fleetest/ProfileRunner+Supply.swift")
        let start = try XCTUnwrap(lines.firstIndex { $0 == "func run() {" })
        try assertOrder(["supplyLease?.release()", "RunHookRunner.end(", "servicesSession?.down(",
                         "ProfileWorkerFactory.restoreAnimations(", "ResponseMeasurementMonitorHold.release("],
                        in: lines[start...], "SupplyCleanup.run")
        XCTAssertFalse(lines[start..<(start + 8)].contains { $0.contains("ConsoleOut.") })
    }

    /// 両方の入口が共有の関数を通り、自分で撃たない(片方に足した段は、もう片方で黙って抜ける)
    func testBothEntryPointsGoThroughTheSharedPreparation() throws {
        let supply = try code("Sources/fleetest/ProfileRunner+Supply.swift")
        let api = try code("Sources/fleetest/ApiRunCommand.swift")
        XCTAssertEqual(supply.filter { $0.contains("Self.prepareEnvironment(") }.count, 1)
        XCTAssertEqual(api.filter { $0.contains("ProfileRunner.prepareEnvironment(") }.count, 1)
        for needle in ["RunHookRunner.begin(", "ServicesSession.up(", "rejectIfDevicesLeasedBeforePreparation(",
                       "ResponseMeasurementMonitorHold.acquire(", "WorkspaceAppStaging."] {
            XCTAssertFalse(api.contains { $0.contains(needle) }, "api run が自分で撃っている: \(needle)")
        }
    }

    /// api run の dry-run はデバイスにも走行中の run にも触らない(`fleetest run` の dry-run と同じ)
    func testApiDryRunSkipsTheWorkspaceAndTheHealthCheck() throws {
        let api = try code("Sources/fleetest/ApiRunCommand.swift")
        XCTAssertTrue(api.contains("if !dryRun { try ProfileRunner.prepareWorkspace(resolvedAll) { logStderr($0) } }"))
        let health = try XCTUnwrap(api.firstIndex { $0.contains("BackendHealthCheck.warnIfUnreachable(") })
        XCTAssertEqual(api[health - 1], "if let resolved = resolvedProfile, !dryRun {")
    }

    /// 結果を書いた後に片付ける(終了スクリプトに上限が無いので、先に片付けると刺さった回の run.json が残らない)
    func testNoEntryPointCleansUpBeforeWritingTheResult() throws {
        for path in ["Sources/fleetest/Fleetest.swift", "Sources/fleetest/ApiRunCommand.swift", "Sources/fleetest/ProfileRunner.swift"] {
            // 出口への登録(`runExit.settle = …`)は片付けではない
            let lines = try code(path).filter { !$0.hasPrefix("runExit.settle = ") && !$0.hasPrefix("runExit.close = ") }
            XCTAssertFalse(lines.contains { $0.contains("runExit.finish") || $0.contains(".settle()") || $0.contains("prepared.close()") },
                           "\(path): 本体の中で片付けている(`RunExitGuard` の出口は結果の後)")
        }
    }

    /// 中断は全件失敗の CI レポートにしない・run.json には中断と残す
    func testAnInterruptionBeforeTheRunIsRecordedAsAnInterruption() throws {
        let lines = try code("Sources/fleetest/Fleetest.swift")
        XCTAssertTrue(lines.contains("interrupted: error is RunInterruptedBeforeStartError,"))
        let junit = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("try? writeJUnitIfRequested(project: testProject, recorder: recorder,") })
        XCTAssertEqual(lines[junit - 1], "if !(error is RunInterruptedBeforeStartError) {")
    }
}
