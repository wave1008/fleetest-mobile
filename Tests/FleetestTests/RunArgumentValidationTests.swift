// run / api run の引数検査(空の reportDir・前提のフラグ・負の --wait-lock・別 OS の宛先・重複 --port・
// api run の --debug/--breakpoint)。検査は validate() = parse の中で落ちる。

import XCTest
import ArgumentParser
@testable import fleetest

final class RunArgumentValidationTests: XCTestCase {

    private func runMessage(_ arguments: [String]) -> String? {
        do { _ = try RunScenarios.parse(arguments); return nil }
        catch { return RunScenarios.message(for: error) }
    }

    private func apiMessage(_ arguments: [String]) -> String? {
        do { _ = try ApiRunCommand.parse(["--scenario", "Klass.method"] + arguments); return nil }
        catch { return ApiRunCommand.message(for: error) }
    }

    private func assertBoth(_ arguments: [String], contains expected: String?,
                            file: StaticString = #filePath, line: UInt = #line) {
        for (name, message) in [("run", runMessage(arguments)), ("api run", apiMessage(arguments))] {
            if let expected {
                XCTAssertTrue(message?.contains(expected) == true,
                              "\(name) \(arguments): expected '\(expected)' got \(message ?? "accepted")", file: file, line: line)
            } else {
                XCTAssertNil(message, "\(name) \(arguments) should be accepted", file: file, line: line)
            }
        }
    }

    func testBlankReportDirIsRejectedEverywhere() {
        assertBoth(["--report-dir", ""], contains: "--report-dir must not be empty")
        assertBoth(["--report-dir", "  "], contains: "--report-dir must not be empty")
        assertBoth(["--set", "reportDir="], contains: "must not be empty")
        assertBoth(["--report-dir", "/tmp/x"], contains: nil)
        assertBoth(["--set", "reportDir=/tmp/x"], contains: nil)
    }

    func testRemoteDirNeedsProfile() {
        assertBoth(["--remote-dir", "/tmp/x"], contains: "--remote-dir requires --profile")
        assertBoth(["--profile", "p", "--remote-dir", "/tmp/x"], contains: nil)
    }

    func testAllMachinesNeedsDevice() {
        assertBoth(["--profile", "p", "--all-machines"], contains: "--all-machines requires --device")
        assertBoth(["--profile", "p", "--device", "d1", "--all-machines"], contains: nil)
    }

    func testNegativeWaitLockIsRejected() {
        assertBoth(["--wait-lock=-5"], contains: "--wait-lock must be zero or a positive")
        assertBoth(["--wait-lock", "0"], contains: nil)
    }

    func testExplicitPlatformRejectsTheOtherOSTarget() {
        assertBoth(["--platform", "android", "--port", "8100"], contains: "--platform android was given along with an iOS target")
        assertBoth(["--platform", "ios", "--serial", "emulator-5554"], contains: "--platform ios was given along with --serial")
        assertBoth(["--platform", "ios", "--port", "8100"], contains: nil)
        assertBoth(["--platform", "android", "--serial", "emulator-5554"], contains: nil)
        // platform 省略で両方の宛先を渡す形は断らない(シナリオごとの platform で両 OS を回す経路がある)
        assertBoth(["--port", "8100", "--serial", "emulator-5554"], contains: nil)
    }

    func testRunRejectsDuplicatePort() {
        XCTAssertTrue(runMessage(["--port", "8100", "--port", "8100"])?.contains("--port 8100 was given more than once") == true)
        XCTAssertNil(runMessage(["--port", "8100", "--port", "8101"]))
    }

    func testApiRunBreakpointAndPauseNeedDebug() {
        XCTAssertEqual(apiMessage(["--breakpoint", "a.swift:3"]), "--breakpoint requires --debug")
        XCTAssertEqual(apiMessage(["--pause-on-start"]), "--pause-on-start requires --debug")
        XCTAssertTrue(apiMessage(["--debug", "--breakpoint", "junk"])?.contains("is not <file>:<line>") == true)
        XCTAssertTrue(apiMessage(["--debug", "--breakpoint", "a.swift:0"])?.contains("is not <file>:<line>") == true)
        XCTAssertNil(apiMessage(["--debug", "--breakpoint", "a.swift:3", "--pause-on-start"]))
    }
}
