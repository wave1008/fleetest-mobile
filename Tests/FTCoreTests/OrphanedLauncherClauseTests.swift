// MCP のセッションを起動したプロセスが親を失っている(launchd へ付け替えられた)ことを、端末の使用中の文言に添える。
// VSCode を再読み込みすると古い窓の claude が親を失ったまま生き残り、その子の MCP が端末の印を持ち続けた

import Foundation
import XCTest
@testable import FTCore

final class OrphanedLauncherClauseTests: XCTestCase {

    func testOnlyALauncherReparentedToLaunchdIsNamed() {
        XCTAssertTrue(ProcessLiveness.orphanedLauncherClause(launcher: 4536, launcherParent: 1)
            .contains("pid 4536) has lost its own parent"))
        XCTAssertEqual(ProcessLiveness.orphanedLauncherClause(launcher: 4536, launcherParent: 830), "")
        XCTAssertEqual(ProcessLiveness.orphanedLauncherClause(launcher: 1, launcherParent: 0), "",
                       "launchd が直接起動したセッションを「親を失った」と言った")
        XCTAssertEqual(ProcessLiveness.orphanedLauncherClause(launcher: nil, launcherParent: nil), "")
    }

    /// 実物: 外側のシェルが抜けて親を失った内側のシェル(起動した側)と、その子(セッション役)
    func testRealOrphanedLauncherIsDetected() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "( sh -c 'sleep 20 & echo $!; wait' & ) ; exit 0"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        var text = ""
        let deadline = Date().addingTimeInterval(5)
        while !text.contains("\n"), Date() < deadline {
            text += String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
        }
        let session = try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), text)
        defer { kill(session, SIGTERM) }
        // 外側が抜けて内側が launchd へ付け替えられるまで待つ(付け替えは exit の直後だが、念のため短く待つ)
        let settle = Date().addingTimeInterval(3)
        while ProcessLiveness.orphanedLauncherClause(sessionPID: session).isEmpty, Date() < settle {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(ProcessLiveness.orphanedLauncherClause(sessionPID: session).isEmpty)
        XCTAssertEqual(ProcessLiveness.orphanedLauncherClause(sessionPID: getpid()), "",
                       "親の居るテストのプロセスを「親を失った」と言った")
    }
}
