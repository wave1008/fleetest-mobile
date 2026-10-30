// 2026-10-30 午後の CLI 所見(F1/F4/F5/F10)を production の関数経由で固定する。

import XCTest
@testable import FTCore

final class CLIAfternoonFixesTests: XCTestCase {
    // MARK: F4 — validate-profile が同じ原因を2行で出さない

    func testStaticallyCoveredResolveErrorsAreMarkedCovered() {
        let covered: [ProfileError] = [
            .emptyReportDir(run: "r"), .missingAppReference(run: "r"), .missingDevices(run: "r"),
            .duplicateDeviceName(name: "d", deviceMachine: nil, run: "r"), .invalidLocale(run: "r"),
            .invalidWipeDataThreshold(run: "r"),
            .physicalDeviceMissingIdentifier(name: "d", platform: "ios", run: "r"),
            .decodeFailed(URL(fileURLWithPath: "/p/profiles/runs/r.json"), detail: "x"),
        ]
        for error in covered {
            XCTAssertTrue(error.isCoveredByStaticRunValidation(runFileName: "r"), "\(error)")
        }
    }

    func testResolveOnlyErrorsAreNeverHidden() {
        let shown: [ProfileError] = [
            .noEnabledDevices(run: "r"), .invalidIOSMode(run: "r", device: nil, value: "x"),
            .appProfileNotFound(name: "a", available: []),
            // 別ファイル(アプリプロファイル)の読み込み失敗・別名の実行プロファイルは静的検査が見ていない
            .decodeFailed(URL(fileURLWithPath: "/p/profiles/apps/a.json"), detail: "x"),
            .decodeFailed(URL(fileURLWithPath: "/p/profiles/runs/other.json"), detail: "x"),
        ]
        for error in shown {
            XCTAssertFalse(error.isCoveredByStaticRunValidation(runFileName: "r"), "\(error)")
        }
    }

    func testTheStaticCheckReallyReportsWhatTheCoveredCasesClaim() {
        let json = #"{"app":"a","devices":[{"platform":"ios","name":"d"}],"reportDir":"  "}"#
        let errors = ProfileResolver.validate(kind: .run, data: Data(json.utf8), context: "x").errors
        XCTAssertTrue(errors.contains { $0.contains("reportDir") }, "\(errors)")
    }

    // MARK: F5 — recordBitrateKbps の上限

    func testBitrateAboveTheCeilingFallsBackToTheDefault() {
        let ceiling = RunProfileDocument.maxRecordBitrateKbps
        XCTAssertEqual(RunProfileDocument.effectiveRecordBitrateKbps(ceiling), ceiling)
        XCTAssertEqual(RunProfileDocument.effectiveRecordBitrateKbps(ceiling + 1), VideoRecordingConfig.defaultBitrateKbps)
        XCTAssertEqual(RunProfileDocument.effectiveRecordBitrateKbps(Int.max), VideoRecordingConfig.defaultBitrateKbps)
        XCTAssertEqual(RunProfileDocument.effectiveRecordBitrateKbps(0), VideoRecordingConfig.defaultBitrateKbps)
        XCTAssertEqual(RunProfileDocument.effectiveRecordBitrateKbps(2500), 2500)
    }

    func testSetRejectsOutOfRangeBitrate() {
        for value in ["9223372036854775807", "0", "-5"] {
            XCTAssertThrowsError(try RunProfileSetOverride.parse(["recordBitrateKbps=\(value)"]), value)
        }
        XCTAssertNoThrow(try RunProfileSetOverride.parse(["recordBitrateKbps=1500"]))
    }

    func testValidateWarnsAboveTheCeiling() {
        let json = #"{"app":"a","devices":[{"platform":"ios","name":"d"}],"recordBitrateKbps":9223372036854775807}"#
        let warnings = ProfileResolver.validate(kind: .run, data: Data(json.utf8), context: "x").warnings
        XCTAssertTrue(warnings.contains { $0.contains("recordBitrateKbps") }, "\(warnings)")
    }

    // MARK: F10 — ensure-settings

    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-afternoon-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func write(_ permissions: [String: Any], to root: URL) throws {
        try JSONSerialization.data(withJSONObject: ["permissions": permissions])
            .write(to: root.appendingPathComponent(".claude/settings.json"))
    }

    private func permissions(_ root: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(".claude/settings.json"))
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(settings["permissions"] as? [String: Any])
    }

    func testAnExplicitAllowOfStartRunIsNotCancelledByAnAsk() throws {
        try withRoot { root in
            try write(["allow": [ProjectScaffold.mcpStartRunPermission]], to: root)
            try ProjectScaffold.writeClaudeSettings(packageRoot: root, toolRoot: "/tools/ft")
            let ask = try permissions(root)["ask"] as? [String] ?? []
            XCTAssertFalse(ask.contains(ProjectScaffold.mcpStartRunPermission), "\(ask)")
            XCTAssertTrue(ask.contains(ProjectScaffold.mcpServicesPermission), "\(ask)")
        }
    }

    func testDeniedMcpPermissionIsNotCountedAsAdded() throws {
        try withRoot { root in
            try write(["deny": [ProjectScaffold.mcpToolsPermission]], to: root)
            let added = try ProjectScaffold.writeClaudeSettings(packageRoot: root, toolRoot: "/tools/ft")
            XCTAssertFalse(added.contains(ProjectScaffold.mcpToolsPermission), "\(added)")
            let allow = try permissions(root)["allow"] as? [String] ?? []
            XCTAssertFalse(allow.contains(ProjectScaffold.mcpToolsPermission), "\(allow)")
            // 書いたものと数えたものが一致する(allow・ask・deny のどれかに実際に入っている)
            let written = Set(allow + (try permissions(root)["ask"] as? [String] ?? [])
                              + (try permissions(root)["deny"] as? [String] ?? []))
            XCTAssertTrue(added.allSatisfy { written.contains($0) }, "\(added) vs \(written)")
        }
    }

    // MARK: F1 — detach

    func testDetachReleasesAPausedScenarioAndDropsBreakpoints() {
        let control = ScenarioDebugControl(breakpoints: ["a.swift:3"], pauseOnStart: true)
        let finished = expectation(description: "checkpoint returned")
        let result = LockedValue<String>("")
        let thread = Thread {
            result.withLock { $0 = "\(control.checkpoint(file: "a.swift", line: 1, onPause: {}))" }
            finished.fulfill()
        }
        thread.start()
        // 停止に入るのを待たずに送ってよい: paused の前に届いても pauseAtNextStep が落ちて素通りになる
        Thread.sleep(forTimeInterval: 0.2)
        control.apply(line: #"{"cmd":"detach"}"#)
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(result.value, "proceed")
        XCTAssertEqual("\(control.checkpoint(file: "a.swift", line: 3, onPause: {}))", "proceed")
    }

    /// 止まっている間に step が先に届き、起き上がる前に detach が来ても、次のステップで止まり直さない(再開させる者が居ない)
    func testStepPendingBeforeDetachDoesNotPauseAgain() {
        let control = ScenarioDebugControl(breakpoints: [], pauseOnStart: true)
        let paused = expectation(description: "paused")
        let finished = expectation(description: "checkpoint returned")
        let thread = Thread {
            _ = control.checkpoint(file: "a.swift", line: 1, onPause: {
                // 起き上がる前に step と detach を続けて入れる(待ち手はまだ pendingAction を読んでいない)
                control.apply(line: #"{"cmd":"step"}"#)
                control.apply(line: #"{"cmd":"detach"}"#)
                paused.fulfill()
            })
            finished.fulfill()
        }
        thread.start()
        wait(for: [paused, finished], timeout: 5)
        // 止まり直したら失敗を記録し、テストが返らなくならないよう自分で再開させる
        let pausedAgain = LockedValue(false)
        _ = control.checkpoint(file: "a.swift", line: 2, onPause: {
            pausedAgain.withLock { $0 = true }
            control.forceResumeForTest()
        })
        XCTAssertFalse(pausedAgain.value, "detach の後に止まり直した")
    }
}
