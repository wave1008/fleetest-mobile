// `api run --debug` の stdin 中継(F1/F2)と ensure-settings の引数検査(F9)。

import XCTest
@testable import FTCore
@testable import fleetest

final class DebugStdinRelayTests: XCTestCase {
    private func readLines(_ pipe: Pipe) -> [String] {
        try? pipe.fileHandleForWriting.close()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    func testLinesBeforeAttachAreFlushedInOrder() {
        let pipe = Pipe()
        let relay = DebugStdinRelay()
        relay.receive(#"{"cmd":"breakpoints","locations":[]}"#)
        relay.receive(#"{"cmd":"continue"}"#)
        relay.attach(ScenarioRunControl(handle: pipe.fileHandleForWriting))
        relay.receive(#"{"cmd":"stop"}"#)
        XCTAssertEqual(readLines(pipe), [#"{"cmd":"breakpoints","locations":[]}"#, #"{"cmd":"continue"}"#, #"{"cmd":"stop"}"#])
    }

    func testEOFBeforeAttachSendsDetachAfterTheBufferedLines() {
        let pipe = Pipe()
        let relay = DebugStdinRelay()
        relay.receive(#"{"cmd":"continue"}"#)
        relay.inputClosed()
        relay.attach(ScenarioRunControl(handle: pipe.fileHandleForWriting))
        XCTAssertEqual(readLines(pipe), [#"{"cmd":"continue"}"#, #"{"cmd":"detach"}"#])
    }

    func testEOFAfterAttachSendsDetach() {
        let pipe = Pipe()
        let relay = DebugStdinRelay()
        relay.attach(ScenarioRunControl(handle: pipe.fileHandleForWriting))
        relay.inputClosed()
        XCTAssertEqual(readLines(pipe), [#"{"cmd":"detach"}"#])
    }

    func testEnsureSettingsRefusesMissingWorkDirAndRelativeToolRoot() {
        XCTAssertThrowsError(try ApiEnsureSettingsCommand.validate(workDir: "/nonexistent-\(UUID().uuidString)", toolRoot: nil))
        XCTAssertThrowsError(try ApiEnsureSettingsCommand.validate(workDir: nil, toolRoot: ""))
        XCTAssertThrowsError(try ApiEnsureSettingsCommand.validate(workDir: nil, toolRoot: "relative/clone"))
        XCTAssertNoThrow(try ApiEnsureSettingsCommand.validate(workDir: NSTemporaryDirectory(), toolRoot: "/tools/ft"))
        XCTAssertNoThrow(try ApiEnsureSettingsCommand.validate(workDir: nil, toolRoot: nil))
    }
}
