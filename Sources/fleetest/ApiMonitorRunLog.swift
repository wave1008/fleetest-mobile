// 実行ログビューへ流す「他人・CLI・リモートの run」のログ(`monitorRunLog`)の読み手。
//
// 書き手は `ScenarioHost.run` のイベントログ(`<runDir>/events/.inflight-<UUID>.ndjson`。契約は
// docs/results-json.md §events)で、どのデバイスのログかは親が run 台帳(`RunProgressLane.eventLog`)へ載せる
// (イベントログ自身にデバイスの情報は無い)。ここは台帳が指すファイルを**先頭から** fd で開き、毎周期、前回の
// 位置から増えたぶんだけ読んで整形した行にする。
//
// 規律:
//   ① **fd を持ち続ける**(シナリオの終わりに inflight は `<fileBase>.ndjson` へ rename されるが、同じ inode を読み続けられる)
//   ② **周期の中で待たない**(ローカルファイルの pread だけ。1周期で読むのは開始時点のファイルサイズまで = 書き手が速くても終わる)
//   ③ **行を省略・間引き・件数で打ち切らない**(テストのエビデンス)。行の途中で切れていたら次の周期へ持ち越す
//   ④ **閉じる条件**: どの lane からも参照されなくなり、かつその周期の読み取りが 0 バイト(読み切った)。
//      run の台帳ごと消えた場合も同じ(読み切ってから閉じる)。閉じるときの持ち越しの残りは1行として出す
//   ⑤ 整形は `ScenarioLogFormatter`(CLI の通常出力と同じ)。整形を2か所に持たない
//   ⑥ 台帳の文字列を強制開封しない・任意のファイルを流さない: 開くのは `events/.inflight-*.ndjson` の通常ファイルだけ
//      (O_NOFOLLOW + O_NONBLOCK + S_ISREG。台帳は機械グローバルで他人も書ける)
// 同期相手: RemoteMonitorFanout.ingest(device をマシン付きへ直す)・vscode-fleetest の monitorRunLog 受け口

import Foundation
import FTCore

/// monitorRunLog イベント。lane ごと・周期ごとに、行があるときだけ1件出す。
/// `machine` は **var**(欠落 = 手元。monitorRuns と同じ綴り。リモートぶんは RemoteMonitorFanout が埋める)。
/// `device` は monitorDevices の id と同じ規則(`<platform>:<lane.name>`。リモートは中継側が `<platform>:<machine>/<name>` へ直す)
struct ApiMonitorRunLogEvent: Codable, Equatable {
    private(set) var kind = "monitorRunLog"
    var machine: String?
    var device: String
    let runID: String?
    let pid: Int32
    /// run を回しているプロセスの `FT_STREAM_OWNER`(拡張から起こした run の印。CLI の run は nil)
    let owner: String?
    let lines: [String]

    init(machine: String? = nil, device: String, runID: String?, pid: Int32, owner: String?, lines: [String]) {
        self.machine = machine
        self.device = device
        self.runID = runID
        self.pid = pid
        self.owner = owner
        self.lines = lines
    }
}

final class RunLogTailer {
    struct Meta: Equatable {
        let device: String
        let runID: String?
        let pid: Int32
        let owner: String?
    }

    private struct Tail {
        /// 初めて見た順(出力の順序を決定的にする)
        let order: Int
        let fd: Int32
        var offset: Int64
        var carry: Data
        var meta: Meta
    }

    /// pread のバッファの大きさ(バイト)。読む量の上限ではない(1周期で開始時点のファイルサイズまで全部読む)
    private static let bufferSize = 64 * 1024

    private var tails: [String: Tail] = [:]
    private var nextOrder = 0

    deinit {
        for tail in tails.values { Darwin.close(tail.fd) }
    }

    /// 追跡中のパス(テスト用)
    var trackedPaths: Set<String> { Set(tails.keys) }

    /// 1周期ぶん。台帳の全 record を渡す(読んだ直後に呼ぶ)
    func poll(records: [RunProgressRecord]) -> [ApiMonitorRunLogEvent] {
        let refs = Self.references(records: records)
        for (path, meta) in refs.sorted(by: { $0.key < $1.key }) {
            if var tail = tails[path] {
                tail.meta = meta
                tails[path] = tail
                continue
            }
            // 開けなかった(もう rename 済み・消えた)パスは覚えない。参照されている間は次の周期でも試す
            guard let fd = Self.open(path: path) else { continue }
            tails[path] = Tail(order: nextOrder, fd: fd, offset: 0, carry: Data(), meta: meta)
            nextOrder += 1
        }

        var grouped: [(meta: Meta, lines: [String])] = []
        for (path, current) in tails.sorted(by: { $0.value.order < $1.value.order }) {
            var tail = current
            let (data, newOffset) = Self.readIncrement(fd: tail.fd, offset: tail.offset)
            tail.offset = newOffset
            var rawLines: [Data] = []
            if !data.isEmpty {
                let split = Self.split(carry: tail.carry, chunk: data)
                rawLines = split.complete
                tail.carry = split.carry
            }
            if refs[path] == nil && data.isEmpty {
                if !tail.carry.isEmpty { rawLines.append(tail.carry) }
                Darwin.close(tail.fd)
                tails[path] = nil
            } else {
                tails[path] = tail
            }
            let lines = rawLines.flatMap { Self.displayLines(rawLine: String(decoding: $0, as: UTF8.self)) }
            guard !lines.isEmpty else { continue }
            if let index = grouped.firstIndex(where: { $0.meta.pid == tail.meta.pid && $0.meta.device == tail.meta.device }) {
                grouped[index].lines.append(contentsOf: lines)
            } else {
                grouped.append((tail.meta, lines))
            }
        }
        return grouped.map {
            ApiMonitorRunLogEvent(device: $0.meta.device, runID: $0.meta.runID, pid: $0.meta.pid,
                                  owner: $0.meta.owner, lines: $0.lines)
        }
    }

    // MARK: - pure

    /// 台帳が指しているイベントログ(パス → 持ち主)。device は `<platform>:<lane.name>`。
    /// lane.platform が nil のときは同じ record の他の lane の platform が1種類だけならそれを使い、
    /// 推せなければそのログは出さない(誤ったタイルへ流さない)
    static func references(records: [RunProgressRecord]) -> [String: Meta] {
        var refs: [String: Meta] = [:]
        for record in records {
            let platforms = Set(record.lanes.compactMap(\.platform))
            for lane in record.lanes {
                guard let path = lane.eventLog, isEventLogPath(path) else { continue }
                guard let platform = lane.platform ?? (platforms.count == 1 ? platforms.first : nil) else { continue }
                refs[path] = Meta(device: "\(platform):\(lane.name)", runID: record.runID,
                                  pid: record.pid, owner: record.owner)
            }
        }
        return refs
    }

    /// 開いてよいのは `<…>/events/.inflight-<…>.ndjson` だけ(規律⑥)
    static func isEventLogPath(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        return path.hasPrefix("/") && name.hasPrefix(".inflight-") && name.hasSuffix(".ndjson")
            && url.deletingLastPathComponent().lastPathComponent == "events"
    }

    /// 持ち越しの断片 + 新しく読んだぶん → 完結した行(改行なし)と、次へ持ち越す断片
    static func split(carry: Data, chunk: Data) -> (complete: [Data], carry: Data) {
        var buffer = carry
        buffer.append(chunk)
        var lines: [Data] = []
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            lines.append(Data(buffer[start..<newline]))
            start = buffer.index(after: newline)
        }
        return (lines, Data(buffer[start...]))
    }

    /// イベントログの1行 → 実行ログビューの行。stdout / host の `event` が `ScenarioEvent` として読めれば
    /// `ScenarioLogFormatter`(CLI の通常出力と同じ)・stderr と `text` はその文字列をそのまま1行・
    /// 読めない行は原文を1行(黙って捨てない)
    static func displayLines(rawLine: String) -> [String] {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let data = trimmed.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [trimmed]
        }
        if let text = envelope["text"] as? String { return [text] }
        guard let stream = envelope["stream"] as? String, stream == "stdout" || stream == "host",
              let eventObject = envelope["event"] as? [String: Any],
              let eventData = try? JSONSerialization.data(withJSONObject: eventObject),
              let event = try? JSONDecoder().decode(ScenarioEvent.self, from: eventData)
        else { return [trimmed] }
        return ScenarioLogFormatter.lines(for: event)
    }

    // MARK: - I/O

    private static func open(path: String) -> Int32? {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    /// `offset` から**呼んだ時点のファイルサイズまで**を pread で読む(待たない・追記が続いても終わる)
    private static func readIncrement(fd: Int32, offset: Int64) -> (data: Data, newOffset: Int64) {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return (Data(), offset) }
        let end = Int64(info.st_size)
        var position = offset
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while position < end {
            let want = Int(min(Int64(buffer.count), end - position))
            let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, want, off_t(position)) }
            if count > 0 {
                out.append(contentsOf: buffer[0..<count])
                position += Int64(count)
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        return (out, position)
    }
}
