// run の実行中に人がライブ操作(`api live serve`)で触ったデバイス操作の台帳。シナリオの結果へ
// 「人が触った事実」を時刻つきで残すための受け渡し(介入が原因の赤をアプリの不具合に見せない)。分類はしない・事実だけ。
//
// 契約:
//  ① 置き場 `<stateDir>/human-ops/<key>.ndjson`(stateDir = ツール本体の `.fleetest`・key = UDID / adb serial =
//    run-lease の鍵と同じ)。1行 = `HumanOperationRecord` の JSON
//  ② 書き手は **run がそのデバイスを使用中のときの serve だけ**(`fleetest` の `LiveHumanOperation.shouldRecord`)。
//    普段のライブ操作では台帳を育てない
//  ③ 読み手は親の `ScenarioHost.run` の確定点3つ。時刻窓 [開始, 確定] に入る行だけを結果へ載せる
//  ④ 子(シナリオ実行バイナリ)に台帳を偽造させない: `ScenarioSandbox.writeDeniedPaths` に `.fleetest/human-ops` がある
//  ⑤ 入力した文字列は残さない(label を作る側の規律。OTP・パスワードを人が打つ運用が典型)

import Foundation

/// 人の操作1件。結果 JSON の `humanOperations` の要素でもある(docs/results-json.md)
public struct HumanOperationRecord: Codable, Sendable, Equatable {
    /// ISO 8601(UTC・ミリ秒つき。末尾 `Z`)
    public var at: String
    /// 英語の短い事実(`tap (120, 340)` 等)。入力した文字列は含まない
    public var label: String
    /// 操作がドライバに通ったか(失敗した操作も、人が触ろうとした事実として残す)
    public var ok: Bool

    public init(at: String, label: String, ok: Bool) {
        self.at = at
        self.label = label
        self.ok = ok
    }

    public init(at: Date, label: String, ok: Bool) {
        self.init(at: HumanOperationLedger.format(at), label: label, ok: ok)
    }

    public var date: Date? { HumanOperationLedger.parse(at) }
}

public enum HumanOperationLedger {
    /// 台帳に残す期間[秒]= 24 時間。読み手が要るのは確定中のシナリオの窓だけ(所要は分〜十数分・
    /// `@Test(scenarioTimeout:)` の上限でも時間単位)なので、それより十分長ければ足りる。
    /// 超えた行は次の追記のついでに捨てる(尽きる = 古い行が消えるだけで、窓に入る行は残る)
    public static let retentionSeconds: TimeInterval = 24 * 3600

    public static let directoryName = "human-ops"

    /// 鍵(UDID / serial)をファイル名に使える形へ。`/` だけ置き換える(adb serial は `host:port` もあり得る)
    static func fileName(forKey key: String) -> String {
        key.replacingOccurrences(of: "/", with: "_")
    }

    public static func fileURL(stateDir: URL, key: String) -> URL {
        stateDir.appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName(forKey: key) + ".ndjson")
    }

    // MARK: - 時刻

    public static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    // MARK: - 純粋な部分

    /// 行(改行区切りの NDJSON)を読む。壊れた行・時刻が読めない行は飛ばす
    static func decode(_ data: Data) -> [(date: Date, record: HumanOperationRecord)] {
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { line in
            guard let record = try? decoder.decode(HumanOperationRecord.self, from: Data(line)),
                  let date = record.date else { return nil }
            return (date, record)
        }
    }

    /// 窓 [from, to](両端を含む)に入る行を時刻順で(同時刻は台帳の順 = 安定ソート)
    static func select(_ rows: [(date: Date, record: HumanOperationRecord)],
                       from: Date, to: Date) -> [HumanOperationRecord] {
        let inWindow = rows.enumerated().filter { $0.element.date >= from && $0.element.date <= to }
        return inWindow.sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .map(\.element.record)
    }

    /// 保持期間より古い行を除く(`now` の `retentionSeconds` 前より前)。除くものが無ければ nil
    /// (呼び手は書き直さず追記だけで済ませる)
    static func pruned(_ rows: [(date: Date, record: HumanOperationRecord)],
                       now: Date) -> [(date: Date, record: HumanOperationRecord)]? {
        let cutoff = now.addingTimeInterval(-retentionSeconds)
        let kept = rows.filter { $0.date >= cutoff }
        return kept.count == rows.count ? nil : kept
    }

    static func encodeLine(_ record: HumanOperationRecord) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(record) else { return nil }
        data.append(0x0A)
        return data
    }

    // MARK: - 書く

    /// 1件追記する。ベストエフォート(失敗は無視 = 台帳が書けなくてもライブ操作は止めない)。
    /// 鍵ごとの flock の内側で 半端な末尾を切り戻す → 保持期間より古い行があれば一時ファイルから rename で書き直す
    /// (途中で死んでも元の台帳は残る)→ なければ追記。リンクは辿らない(`FMHistory.openRegularFile` = `O_NOFOLLOW`)
    public static func append(stateDir: URL, key: String, entry: HumanOperationRecord, now: Date = Date()) {
        guard let line = encodeLine(entry) else { return }
        let url = fileURL(stateDir: stateDir, key: key)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let lockFD = FMHistory.openLocked(dir.appendingPathComponent(fileName(forKey: key) + ".lock")) else { return }
        defer { close(lockFD) }
        guard let handle = FMHistory.openRegularFile(url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: 0)) != nil else { return }
        var existing = (try? handle.readToEnd()) ?? Data()
        // 半端な末尾(書き込みの途中で死んだ行)は最後の改行まで切り戻す。残すと次の行が連結して一緒に読めなくなる
        if let last = existing.last, last != 0x0A {
            existing = existing.lastIndex(of: 0x0A).map { Data(existing[...$0]) } ?? Data()
        }
        let rows = decode(existing)
        if let kept = pruned(rows, now: now) {
            var out = Data()
            for row in kept { if let encoded = encodeLine(row.record) { out.append(encoded) } }
            out.append(line)
            let tmp = dir.appendingPathComponent(
                ".\(fileName(forKey: key)).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString).tmp")
            guard (try? out.write(to: tmp)) != nil else { return }
            if rename(tmp.path, url.path) != 0 { try? FileManager.default.removeItem(at: tmp) }
            return
        }
        do {
            try handle.truncate(atOffset: UInt64(existing.count))
            try handle.seek(toOffset: UInt64(existing.count))
            try handle.write(contentsOf: line)
        } catch { return }
    }

    // MARK: - 読む

    /// 窓 [from, to] に入る行。台帳が無い・読めないときは空
    public static func entries(stateDir: URL, key: String, from: Date, to: Date) -> [HumanOperationRecord] {
        guard let data = try? Data(contentsOf: fileURL(stateDir: stateDir, key: key)) else { return [] }
        return select(decode(data), from: from, to: to)
    }
}
