import XCTest
@testable import FTCore

final class StdioPullSourceTests: XCTestCase {

    private func makePipe() -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let (r, w) = (fds[0], fds[1])
        addTeardownBlock { close(r); close(w) }
        return (r, w)
    }

    private func send(_ text: String, to fd: Int32) {
        let bytes = Array((text + "\n").utf8)
        XCTAssertEqual(Foundation.write(fd, bytes, bytes.count), bytes.count)
    }

    /// 要求の行が出てから返事を返す。返事の req で待っている要求へ届く
    func testWantLineIsWrittenAndReplyResolvesTheMatchingRequest() async {
        let input = makePipe()
        let written = LockedValue<[String]>([])
        let source = StdioPullSource(inputFD: input.read, write: { line in written.withLock { $0.append(line) } })
        async let id = source.next(platform: "ios", lane: "iPhone 17")
        for _ in 0..<200 where written.withLock({ $0.isEmpty }) { try? await Task.sleep(for: .milliseconds(10)) }
        let lines = written.withLock { $0 }
        XCTAssertEqual(lines.count, 1)
        let want = lines.first.flatMap(WorkQueueProtocol.decodeWant)
        XCTAssertEqual(want?.lane, "iPhone 17")
        XCTAssertEqual(want?.platform, "ios")
        send(WorkQueueProtocol.encode(WorkQueueProtocol.Reply(req: want?.req ?? -1, id: "A.S0010")), to: input.write)
        let resolved = await id
        XCTAssertEqual(resolved, "A.S0010")
    }

    /// 返事の順序が要求と逆でも req で振り分ける
    func testRepliesAreRoutedByRequestNumber() async {
        let input = makePipe()
        let written = LockedValue<[String]>([])
        let source = StdioPullSource(inputFD: input.read, write: { line in written.withLock { $0.append(line) } })
        async let first = source.next(platform: "android", lane: "a")
        for _ in 0..<200 where written.withLock({ $0.count < 1 }) { try? await Task.sleep(for: .milliseconds(10)) }
        async let second = source.next(platform: "android", lane: "b")
        for _ in 0..<200 where written.withLock({ $0.count < 2 }) { try? await Task.sleep(for: .milliseconds(10)) }
        let wants = written.withLock { $0 }.compactMap(WorkQueueProtocol.decodeWant)
        XCTAssertEqual(wants.map(\.lane), ["a", "b"])
        send(WorkQueueProtocol.encode(WorkQueueProtocol.Reply(req: wants[1].req, id: "B")), to: input.write)
        send(WorkQueueProtocol.encode(WorkQueueProtocol.Reply(req: wants[0].req, none: true)), to: input.write)
        let (a, b) = await (first, second)
        XCTAssertNil(a)
        XCTAssertEqual(b, "B")
    }

    /// stdin の EOF で待っている要求も以後の要求も nil(もう無い)
    func testEOFResolvesWaitingAndFutureRequestsWithNil() async {
        let input = makePipe()
        let written = LockedValue<[String]>([])
        let source = StdioPullSource(inputFD: input.read, write: { line in written.withLock { $0.append(line) } })
        async let waiting = source.next(platform: "ios", lane: "a")
        for _ in 0..<200 where written.withLock({ $0.isEmpty }) { try? await Task.sleep(for: .milliseconds(10)) }
        close(input.write)
        let first = await waiting
        XCTAssertNil(first)
        let later = await source.next(platform: "ios", lane: "a")
        XCTAssertNil(later)
        XCTAssertEqual(written.withLock { $0.count }, 1, "EOF 後の要求は書かずに nil にする")
    }

    /// 中断(stopWaiting)で、返事の来ない要求も以後の要求も nil になる(親の返事を当てにしない)
    func testStopWaitingResolvesWaitingAndFutureRequestsWithoutAReply() async {
        let input = makePipe()
        let written = LockedValue<[String]>([])
        let source = StdioPullSource(inputFD: input.read, write: { line in written.withLock { $0.append(line) } })
        // 解けないと永遠に待つので、2 秒で打ち切って "timeout" を返す(タスクグループは子が終わるまで抜けないので使わない)
        func nextOrTimeout() async -> String? {
            let box = LockedValue<CheckedContinuation<String?, Never>?>(nil)
            return await withCheckedContinuation { continuation in
                box.withLock { $0 = continuation }
                Task {
                    let value = await source.next(platform: "android", lane: "a")
                    box.withLock { $0?.resume(returning: value); $0 = nil }
                }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    box.withLock { $0?.resume(returning: "timeout"); $0 = nil }
                }
            }
        }
        async let waiting = nextOrTimeout()
        for _ in 0..<200 where written.withLock({ $0.isEmpty }) { try? await Task.sleep(for: .milliseconds(10)) }
        source.stopWaiting()
        let first = await waiting
        XCTAssertNil(first, "待っている要求が中断で解けない")
        let later = await nextOrTimeout()
        XCTAssertNil(later, "中断後の要求が nil にならない")
        XCTAssertEqual(written.withLock { $0.count }, 1, "中断後の要求は書かずに nil にする")
    }

    /// stdin の移し替え: 移した先で親の返事を読め、元の fd は /dev/null(子プロセスが受け継いでも何も読めない)、移した先は子へ渡らない
    func testMoveKeepsTheStreamOnAPrivateCloseOnExecDescriptorAndBlanksTheOriginal() {
        let pipeFDs = makePipe()
        let original = dup(pipeFDs.read)   // 「stdin」役(テストのプロセスの fd 0 は触らない)
        XCTAssertGreaterThanOrEqual(original, 0)
        defer { close(original) }
        let moved = WorkQueueStdin.move(original)
        defer { if moved != original { close(moved) } }
        XCTAssertNotEqual(moved, original, "複製していない")
        XCTAssertEqual(fcntl(moved, F_GETFD) & FD_CLOEXEC, FD_CLOEXEC, "移した fd が子へ受け継がれる")
        send("reply", to: pipeFDs.write)
        var buffer = [UInt8](repeating: 0, count: 16)
        let n = read(moved, &buffer, buffer.count)
        XCTAssertEqual(n > 0 ? String(decoding: buffer[0..<n], as: UTF8.self) : "", "reply\n", "移した先で読めない")
        XCTAssertEqual(read(original, &buffer, buffer.count), 0, "元の fd が /dev/null になっていない(子プロセスが返事を読める)")
    }

    /// 要求と無関係な行(他の JSON・壊れた行)は無視する
    func testUnrelatedInputLinesAreIgnored() async {
        let input = makePipe()
        let written = LockedValue<[String]>([])
        let source = StdioPullSource(inputFD: input.read, write: { line in written.withLock { $0.append(line) } })
        async let id = source.next(platform: "ios", lane: "a")
        for _ in 0..<200 where written.withLock({ $0.isEmpty }) { try? await Task.sleep(for: .milliseconds(10)) }
        let req = written.withLock { $0 }.first.flatMap(WorkQueueProtocol.decodeWant)?.req ?? -1
        send(#"{"kind":"step"}"#, to: input.write)
        send("garbage", to: input.write)
        send(WorkQueueProtocol.encode(WorkQueueProtocol.Reply(req: req + 100, id: "STRAY")), to: input.write)
        send(WorkQueueProtocol.encode(WorkQueueProtocol.Reply(req: req, id: "A")), to: input.write)
        let resolved = await id
        XCTAssertEqual(resolved, "A")
    }
}
