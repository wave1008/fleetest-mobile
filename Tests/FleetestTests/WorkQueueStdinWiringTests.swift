// `--work-queue` の子は run の入口で最初に stdin を自分だけの fd へ移す(WorkQueueStdin.claim)。
// 子プロセスが fd 0 を受け継いで読むと親の返事を横取りし、レーンが渡されたシナリオを受け取れずに止まる。
// claim はテストのプロセスの fd 0 を書き換えるので、ここでは配線をソース走査で固定する(効き目はデバイス実行で確かめた)

import XCTest

final class WorkQueueStdinWiringTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// `func run() async throws {` の直後の、コメントでない最初の行
    private func firstStatementOfRun(in text: String, file: String) -> String? {
        guard let range = text.range(of: "    func run() async throws {\n") else {
            XCTFail("\(file) に run() が見つからない")
            return nil
        }
        return text[range.upperBound...].split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("//") }
    }

    func testBothRunEntriesClaimStdinBeforeAnythingElse() throws {
        for file in ["Sources/fleetest/Fleetest.swift", "Sources/fleetest/ApiRunCommand.swift"] {
            let first = firstStatementOfRun(in: try source(file), file: file)
            XCTAssertEqual(first, "if common.workQueue { _ = WorkQueueStdin.claim() }",
                           "\(file): run() の最初で stdin を移していない")
        }
    }

    /// リモートへ中継する子は、移した fd を ssh へ渡す(fd 0 は /dev/null に差し替え済み)
    func testRemoteRelayHandsTheClaimedDescriptorToSSH() throws {
        let text = try source("Sources/fleetest/RemoteRunDispatcher.swift")
        XCTAssertTrue(text.contains("? FileHandle(fileDescriptor: WorkQueueStdin.claim(), closeOnDealloc: false) : FileHandle.nullDevice"),
                      "ssh へ渡す stdin が移した fd ではない")
        XCTAssertFalse(text.contains("workQueue ? FileHandle.standardInput"), "fd 0(/dev/null)を ssh へ渡している")
    }

    func testPullSourceReadsTheClaimedDescriptorByDefault() throws {
        let text = try source("Sources/FTCore/StdioPullSource.swift")
        XCTAssertTrue(text.contains("public init(inputFD: Int32 = WorkQueueStdin.claim(),"),
                      "StdioPullSource の既定の入力が移した stdin ではない")
    }
}
