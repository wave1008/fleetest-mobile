// 描画の状態(白紙・文字消え。`DeviceScreenState`)を見つけたあとの手当ての判定と台帳(OI-88)。
// 判定は全部純粋関数・台帳は `.fleetest/` の小さなファイル(DeviceScreenStateStore の姉妹型・同じキー体系)。
// 撃つ操作(修復)の実体は FTAndroid.ScreenRenderingRecoverer。配線は ProfileRunOrchestrator → RunOrchestrator.recoverRendering。

import Foundation

/// レーンの切り離しの判定帳。**判定と記録を1つの mutating 呼び出しで行う**(呼び手は LockedValue で包む)—— 2つのレーンが
/// 同時に同じ状態を報告したとき、片方の離脱が先に帳へ反映されないと両方が「他のレーンが居る」と読んで全滅を作る
public struct RenderingLaneBook: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        /// 切り離す(結果を捨てて振り直す)
        case detach
        /// 同じプラットフォームで他に走っているレーンが無い(全レーンが同時にその状態 = 全滅を作らない)
        case keepNoOtherLane
        /// 同じシナリオが別のレーンでも同じ状態を報告している = アプリ側の事実として結果を残す
        case keepReportedByOtherLane(lane: String)
    }

    private var lanes: [String: String] = [:]
    private var reports: [String: [String: DeviceScreenState]] = [:]

    public init() {}

    public mutating func join(laneKey: String, platform: String) { lanes[laneKey] = platform }
    public mutating func leave(laneKey: String) { lanes[laneKey] = nil }

    /// 順序: ①他のレーンの同じ報告(同じシナリオ・同じ状態)→ ②他に生きているレーン。
    /// ①を先にする理由: ②が先だと、報告済みなのに「他のレーンが無い」と答えて根拠が隠れる
    public mutating func decide(laneKey: String, platform: String, scenarioID: String,
                                state: DeviceScreenState) -> Verdict {
        let reportKey = "\(platform)|\(scenarioID)"  // 同じ ID でも OS が違えば別のアプリ
        let other = reports[reportKey]?.filter { $0.key != laneKey && $0.value == state }.keys.sorted().first
        reports[reportKey, default: [:]][laneKey] = state
        if let other { return .keepReportedByOtherLane(lane: other) }
        guard lanes.contains(where: { $0.key != laneKey && $0.value == platform }) else { return .keepNoOtherLane }
        lanes[laneKey] = nil
        return .detach
    }
}

/// 回復を撃った結果(`RunOrchestrator.RenderingRecovery` の戻り値)
public enum RenderingRecoveryOutcome: Sendable, Equatable {
    /// 撃って、直後の確かめで絵が戻った
    case recovered(WorkerRecoveryKind)
    /// 撃ったが、直後の確かめで戻らなかった(案内を公表した)
    case notRecovered(WorkerRecoveryKind?)
    /// このデバイスは今回のマシンの起動以降すでに撃っている = 繰り返さない(案内を公表した)
    case advised
    /// 実機・鍵なし = 撃たない
    case notAttempted
}

public enum MachineBoot {
    /// マシンの起動時刻(`kern.boottime`)。読めなければ nil
    public static func time() -> Date? {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0, value.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value.tv_sec))
    }
}

/// 「描画の回復を撃った」台帳。1台につき1回 = **マシンの1回の起動につき1回**。
/// 鮮度は時間の定数でなくマシンの起動時刻で切る: マシンの再起動が唯一の「数え直す」契機で(案内がそれを勧めているため)、
/// 再起動すれば台帳が自然に無効になる。起動時刻が読めないときは「撃った」を有効のまま残す(繰り返さない側に倒す)
public enum ScreenRecoveryLedger {
    public static func entryURL(stateDir: URL, key: String) -> URL {
        stateDir.appendingPathComponent("screen-recovery-\(key).json")
    }

    private struct Entry: Codable { let at: TimeInterval }

    public static func markFired(stateDir: URL, key: String, now: Date = Date()) {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Entry(at: now.timeIntervalSince1970)) else { return }
        try? data.write(to: entryURL(stateDir: stateDir, key: key), options: .atomic)
    }

    public static func firedAt(stateDir: URL, key: String) -> TimeInterval? {
        guard let data = try? Data(contentsOf: entryURL(stateDir: stateDir, key: key)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        return entry.at
    }

    public enum Action: Sendable, Equatable { case fire, advise }

    /// 撃つか・案内だけか。`firedAt` = 台帳の時刻、`bootTime` = マシンの起動時刻
    public static func action(firedAt: TimeInterval?, bootTime: Date?) -> Action {
        guard let firedAt else { return .fire }
        guard let bootTime else { return .advise }
        return firedAt >= bootTime.timeIntervalSince1970 ? .advise : .fire
    }

    public static func action(stateDir: URL, key: String, bootTime: Date? = MachineBoot.time()) -> Action {
        action(firedAt: firedAt(stateDir: stateDir, key: key), bootTime: bootTime)
    }
}

/// 「デバイスの再起動では戻らなかった」台の公表(マシンごと)。モニターの上部の1行と run の記録の元。
/// 消えるのは ①マシンの再起動(起動時刻より古い書き込みは無効)②そのデバイスの緑の確かめ(`clear`)
public enum UnrecoveredDeviceStore {
    public struct Entry: Codable, Sendable, Equatable {
        public let key: String
        public let name: String
        public let at: TimeInterval
    }

    static let prefix = "screen-unrecovered-"

    public static func entryURL(stateDir: URL, key: String) -> URL {
        stateDir.appendingPathComponent("\(prefix)\(key).json")
    }

    public static func publish(stateDir: URL, key: String, name: String, now: Date = Date()) {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Entry(key: key, name: name, at: now.timeIntervalSince1970)) else { return }
        try? data.write(to: entryURL(stateDir: stateDir, key: key), options: .atomic)
    }

    public static func clear(stateDir: URL, key: String) {
        try? FileManager.default.removeItem(at: entryURL(stateDir: stateDir, key: key))
    }

    /// そのデバイスの有効な公表があるか(モニターの周期ごとに1台ずつ引く)
    public static func isPublished(stateDir: URL, key: String, bootTime: Date? = MachineBoot.time()) -> Bool {
        guard let data = try? Data(contentsOf: entryURL(stateDir: stateDir, key: key)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return false }
        if let bootTime, entry.at < bootTime.timeIntervalSince1970 { return false }
        return true
    }

    /// 有効な公表(名前順)。起動時刻が読めないときは古さで落とさない
    public static func list(stateDir: URL, bootTime: Date? = MachineBoot.time()) -> [Entry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: stateDir.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }.compactMap { file in
            guard let data = try? Data(contentsOf: stateDir.appendingPathComponent(file)),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
            if let bootTime, entry.at < bootTime.timeIntervalSince1970 { return nil }
            return entry
        }.sorted { ($0.name, $0.key) < ($1.name, $1.key) }
    }

    /// run の最後のログに出す1行。台が無ければ nil。測った事実だけ(原因は書かない)
    public static func closingNotice(names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        return "⚠️ Restarting the device did not bring the screen back on \(names.joined(separator: ", ")) —"
            + " restarting this machine is recommended (fleetest does not restart it)"
    }
}

/// 回復1回の手順(撃つ前の台帳 → 撃つ → 直後の確かめ → 台帳と案内)。撃つ操作と確かめは呼び手が渡す
/// (FTAndroid.ScreenRenderingRecoverer が本番の実体)。run 中(離脱後)と run の前(供給)が同じ手順を通る
public enum ScreenRenderingRecovery {
    public enum Start: Sendable, Equatable {
        /// 撃ってよい(台帳に記録した)
        case fire
        /// 今回のマシンの起動以降すでに撃っている = 撃たない(案内を公表した)
        case advised
    }

    /// 撃つ前: 台帳を見て、撃てるなら**撃つ前に**記録する(撃っている最中にプロセスが死んでも繰り返さない)
    public static func begin(key: String, name: String, stateDir: URL, bootTime: Date? = MachineBoot.time(),
                             now: Date = Date()) -> Start {
        if ScreenRecoveryLedger.action(stateDir: stateDir, key: key, bootTime: bootTime) == .advise {
            UnrecoveredDeviceStore.publish(stateDir: stateDir, key: key, name: name, now: now)
            return .advised
        }
        ScreenRecoveryLedger.markFired(stateDir: stateDir, key: key, now: now)
        return .fire
    }

    /// 撃った後: 直後の確かめ(`drawn` = OS 側の絵が全面一様でない)で、戻ったら公表を消し、戻らなければ案内を公表する。
    /// `kind == nil` = 何も撃てなかった(台帳の記録を戻す)
    public static func conclude(key: String, name: String, stateDir: URL, kind: WorkerRecoveryKind?, drawn: Bool,
                                now: Date = Date()) -> RenderingRecoveryOutcome {
        guard let kind else {
            try? FileManager.default.removeItem(at: ScreenRecoveryLedger.entryURL(stateDir: stateDir, key: key))
            return .notAttempted
        }
        if drawn {
            DeviceScreenStateStore.clear(stateDir: stateDir, key: key)
            UnrecoveredDeviceStore.clear(stateDir: stateDir, key: key)
            return .recovered(kind)
        }
        UnrecoveredDeviceStore.publish(stateDir: stateDir, key: key, name: name, now: now)
        return .notRecovered(kind)
    }

    public static func run(key: String?, name: String, stateDir: URL, bootTime: Date? = MachineBoot.time(),
                           repair: () async -> WorkerRecoveryKind?, drawn: () async -> Bool,
                           log: @Sendable (String) -> Void) async -> RenderingRecoveryOutcome {
        guard let key else { return .notAttempted }
        guard begin(key: key, name: name, stateDir: stateDir, bootTime: bootTime) == .fire else {
            log("⚠️ \(name): the screen state was found again, but this device was already restarted since the machine"
                + " started — not restarting it again; restarting the machine is recommended")
            return .advised
        }
        return await fire(key: key, name: name, stateDir: stateDir, repair: repair, drawn: drawn, log: log)
    }

    /// `begin` が `.fire` を返した後に撃つ。**`begin` を2回通さない**(1回目の記録を2回目が「撃った後」と読み、撃たずに案内へ落ちる)
    public static func fire(key: String, name: String, stateDir: URL,
                            repair: () async -> WorkerRecoveryKind?, drawn: () async -> Bool,
                            log: @Sendable (String) -> Void) async -> RenderingRecoveryOutcome {
        let kind = await repair()
        let isDrawn = kind == nil ? false : await drawn()
        let outcome = conclude(key: key, name: name, stateDir: stateDir, kind: kind, drawn: isDrawn)
        switch outcome {
        case .recovered: log("✅ \(name): the screen is drawing again after the restart")
        case .notRecovered: log("⚠️ \(name): restarting the device did not bring the screen back — restarting the machine is recommended")
        default: break
        }
        return outcome
    }
}
