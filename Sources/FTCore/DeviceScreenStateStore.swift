// アプリの描画の状態(白紙・文字消え)を**プロセスを跨いで**モニターへ配る共有ストア。DeviceFrozenStore の姉妹型
// (同じ棚 `.fleetest/`・同じキー体系 = iOS は Simulator UDID / Android は adb serial)。
// 書き手: シナリオ実行バイナリ(StepExecutor の描画崩壊の確かめ)。読み手: デバイスモニター(devices[].screenState)。
// 凍結(❄️)とは別の状態: 凍結は画面そのものが動かない・写っていない、こちらはアプリの領域が一色・図形はあるが文字が無い。

import Foundation

public enum DeviceScreenState: String, Codable, Sendable, Equatable {
    /// アプリの領域が一色(`RenderCollapse.Finding.blankAppArea`)
    case blank
    /// 図形は描かれているが文字の要素が1つも描かれていない(`.noTextDrawn`)
    case textless
}

public enum DeviceScreenStateStore {
    /// 書いた時刻の backstop(秒)。**pid 生存では見ない** —— シナリオのプロセスは短命で、次のシナリオ・次の確かめまでの間
    /// 書き手は居ないのが通常。印を消すのは緑の確かめによる `clear` で、これは「clear する者が現れなかった」ときの上限。
    /// 根拠: `DeviceFrozenStore.stalenessSeconds` と同じ 30 分(1 シナリオの上限より十分長く、放置された印を一晩残さない)。
    /// 尽きたとき: 実際にはまだ白紙でも、次の確かめが公表し直すまで ○ / 🫥 が消える(誤って出し続けるより消える側に倒す)
    public static let stalenessSeconds: TimeInterval = DeviceFrozenStore.stalenessSeconds

    public static func entryURL(stateDir: URL, key: String) -> URL {
        stateDir.appendingPathComponent("screen-state-\(key).json")
    }

    private struct Entry: Codable {
        let at: TimeInterval
        let state: DeviceScreenState
    }

    public static func publish(stateDir: URL, key: String, state: DeviceScreenState, now: Date = Date()) {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Entry(at: now.timeIntervalSince1970, state: state)) else { return }
        try? data.write(to: entryURL(stateDir: stateDir, key: key), options: .atomic)
    }

    public static func clear(stateDir: URL, key: String) {
        try? FileManager.default.removeItem(at: entryURL(stateDir: stateDir, key: key))
    }

    /// 公表されている状態。書いた時刻が `stalenessSeconds` より古い、またはマシンの起動より前なら無いものとして扱う
    /// (印は描画のプロセスの状態なので、マシンの再起動で意味を失う。30 分以内に再起動すると残っていた)。読めなければ nil
    public static func current(stateDir: URL, key: String, now: Date = Date(),
                               bootTime: Date? = MachineBoot.time()) -> DeviceScreenState? {
        guard let data = try? Data(contentsOf: entryURL(stateDir: stateDir, key: key)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              now.timeIntervalSince1970 - entry.at <= stalenessSeconds,
              bootTime.map({ entry.at >= $0.timeIntervalSince1970 }) ?? true else { return nil }
        return entry.state
    }
}
