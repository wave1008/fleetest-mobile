// `--work-queue` の子の側: シナリオの要求を stdout へ1行、返事を stdin から1行(WorkQueueProtocol)。
// 待たせる = 親が返事を遅らせる。書き込みは ConsoleOut.out を通す(text run / api run とも
// stdout の書き手はそこへ集約されていて、1回の write(2) で行が裂けない)。

import Foundation

public final class StdioPullSource: ScenarioPullSource {
    private struct State {
        var nextReq = 1
        var waiters: [Int: CheckedContinuation<String?, Never>] = [:]
        /// stdin が閉じた(以後の要求は即 nil)
        var eof = false
        var started = false
        var restoreEcho: termios?
    }

    private let state = LockedValue(State())
    private let inputFD: Int32
    private let write: @Sendable (String) -> Void

    /// - inputFD / write: テスト用の差し替え口。本番は stdin と ConsoleOut.out
    public init(inputFD: Int32 = STDIN_FILENO,
                write: @escaping @Sendable (String) -> Void = { ConsoleOut.out($0) }) {
        self.inputFD = inputFD
        self.write = write
    }

    deinit { restoreTerminal() }

    public func next(platform: String, lane: String) async -> String? {
        startIfNeeded()
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            // 登録してから書く(返事が登録より先に届いても取りこぼさない)・EOF 済みなら即 nil
            let request: Int? = state.withLock { s in
                if s.eof { return nil }
                let req = s.nextReq
                s.nextReq += 1
                s.waiters[req] = continuation
                return req
            }
            guard let request else { continuation.resume(returning: nil); return }
            write(WorkQueueProtocol.encode(
                WorkQueueProtocol.Want(req: request, lane: lane, platform: platform)))
        }
    }

    public func stopWaiting() {
        let remaining = state.withLock { s -> [CheckedContinuation<String?, Never>] in
            s.eof = true
            defer { s.waiters = [:] }
            return Array(s.waiters.values)
        }
        for continuation in remaining { continuation.resume(returning: nil) }
    }

    /// 端末のエコーを戻す(ssh -tt の先でだけ変えている)。何度呼んでもよい
    public func restoreTerminal() {
        let saved = state.withLock { s -> termios? in
            defer { s.restoreEcho = nil }
            return s.restoreEcho
        }
        guard var saved else { return }
        tcsetattr(inputFD, TCSANOW, &saved)
    }

    private func startIfNeeded() {
        let first = state.withLock { s -> Bool in
            if s.started { return false }
            s.started = true
            return true
        }
        guard first else { return }
        // stdin が端末(リモートの ssh -tt の先)なら送った行が出力へ折り返さないようエコーを切る。
        // 行単位(canonical)のままにして、親の1行を1回の read で受ける
        if isatty(inputFD) != 0 {
            var attributes = termios()
            if tcgetattr(inputFD, &attributes) == 0 {
                let original = attributes
                attributes.c_lflag &= ~tcflag_t(ECHO)
                if tcsetattr(inputFD, TCSANOW, &attributes) == 0 {
                    state.withLock { $0.restoreEcho = original }
                }
            }
        }
        let fd = inputFD
        let thread = Thread { [weak self] in self?.readLoop(fd: fd) }
        thread.name = "fleetest.work-queue.stdin"
        thread.start()
    }

    /// 生の read(2) で読む(availableData のループを持たない = 自動解放の溜まりが無い)。
    /// EOF・読めなくなったら待っている要求と以後の要求を全部 nil にする
    private func readLoop(fd: Int32) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buffer.withUnsafeMutableBytes { Foundation.read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { break }
            pending.append(buffer, count: n)
            while let newline = pending.firstIndex(of: 0x0A) {
                let lineData = pending.subdata(in: pending.startIndex..<newline)
                pending.removeSubrange(pending.startIndex...newline)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                if let reply = WorkQueueProtocol.decodeReply(line) { deliver(reply) }
            }
        }
        let remaining = state.withLock { s -> [CheckedContinuation<String?, Never>] in
            s.eof = true
            defer { s.waiters = [:] }
            return Array(s.waiters.values)
        }
        for continuation in remaining { continuation.resume(returning: nil) }
    }

    private func deliver(_ reply: WorkQueueProtocol.Reply) {
        let continuation = state.withLock { $0.waiters.removeValue(forKey: reply.req) }
        continuation?.resume(returning: reply.scenarioID)
    }
}
