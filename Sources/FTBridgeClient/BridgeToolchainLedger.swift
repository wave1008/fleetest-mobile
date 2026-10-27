// 稼働中ブリッジが「どの Xcode/SDK で起動されたか」をポート台帳の隣
// (.fleetest/bridge-<port>.toolchain)に控える。
//
// **成果物側の指紋(<DerivedData>/.toolchain・InAppBridge/build/.toolchain)と比べてはいけない** ——
// 成果物は BridgeLauncher.runnerRebuildReason が後から独立に作り直しうるので、「ディスクは新しい
// Xcode でビルドし直し済みだが、動いているプロセスは旧 Xcode のまま」という食い違いを検出できない。
// ここは起動した**時点**の値を控え、BridgeProvisioner の .reuse/.adopt 経路がそれと比べる。
//
// 2行目に**起動した時点のブリッジの入力の digest**(`sources=<hex>`。`BridgeSourceSet`)も控える。版を上げずに
// ソースだけ変えた(試しの変更・A/B)とき、版の照合は一致するので、控えが無いと生きた旧ランナーをそのまま使い回し、
// 変えたつもりの実験が旧ビルドで走る(実際にそうなった)。ランナーを作り直す判定
// (runnerRebuildReason)は起動するときにしか走らないので、生きたブリッジはここでしか捕まらない。

import Foundation
import FTCore

public enum BridgeToolchainLedger {

    public static func url(stateDir: URL, port: UInt16) -> URL {
        stateDir.appendingPathComponent("bridge-\(port).toolchain")
    }

    /// ブリッジが ready になった直後に呼ぶ。失敗は握りつぶす(控えが無ければ次回
    /// matchesCurrent が false = 作り直すだけで、壊れはしない。ToolchainFingerprint.store と同じ規律)
    public static func record(stateDir: URL, port: UInt16,
                              toolchain: String? = ToolchainFingerprint.current(), sources: String? = nil) {
        guard let toolchain else { return }
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let body = toolchain + (sources.map { "\n" + sourcesPrefix + $0 } ?? "")
        try? body.write(to: url(stateDir: stateDir, port: port), atomically: true, encoding: .utf8)
    }

    /// **判定できない場合(未保存・読めない・現在値が取れない)は false = 再利用せず作り直す側へ倒す**
    /// (ToolchainFingerprint.matches と同じ規律)。比べるのは1行目(ツールチェーン)だけ
    public static func matchesCurrent(stateDir: URL, port: UInt16,
                                      current: String? = ToolchainFingerprint.current()) -> Bool {
        guard let current, let lines = storedLines(stateDir: stateDir, port: port), let first = lines.first
        else { return false }
        return first == current
    }

    /// 起動した時点のブリッジの入力の digest が今のソースと同じか。**控えが無い・読めない・今の digest が取れないなら false**
    /// (= 作り直す側。matchesCurrent と同じ規律)
    public static func sourcesMatch(stateDir: URL, port: UInt16, current: String?) -> Bool {
        guard let current, let stored = recordedSources(stateDir: stateDir, port: port) else { return false }
        return stored == current
    }

    /// 控えにあるソースの digest(無い = この控えを書いた版はソースを控えていなかった)
    public static func recordedSources(stateDir: URL, port: UInt16) -> String? {
        storedLines(stateDir: stateDir, port: port)?
            .first { $0.hasPrefix(sourcesPrefix) }
            .map { String($0.dropFirst(sourcesPrefix.count)) }
    }

    /// そのブリッジ(`bridge`: "inapp" / "xcuitest")の入力の今の digest。読めなければ nil(= 一致しない側)
    public static func sourcesDigest(bridge: String, repoRoot: URL) -> String? {
        try? (bridge == "inapp" ? BridgeSourceSet.inApp : BridgeSourceSet.xcuitest).digest(repoRoot: repoRoot)
    }

    private static let sourcesPrefix = "sources="

    private static func storedLines(stateDir: URL, port: UInt16) -> [String]? {
        guard let stored = try? String(contentsOf: url(stateDir: stateDir, port: port), encoding: .utf8) else { return nil }
        return stored.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 生きているブリッジを再利用してよいか。**リースのあるデバイスには触らない**
    /// (supplySlownessAction と同じ規律 —— 他プロセスの run・MCP が使用中のブリッジを
    /// 版差だけで殺すとその run を壊す)。**止められないときも黙って使わない** ——
    /// 版の違うブリッジを駆動している事実は変わらないので、呼び手は1行言う
    public enum ReuseDecision: Equatable, Sendable {
        case reuse
        case warnAndReuse
        case restart
    }

    public static func decide(toolchainMatches: Bool, hasForeignLease: Bool) -> ReuseDecision {
        if toolchainMatches { return .reuse }
        return hasForeignLease ? .warnAndReuse : .restart
    }

    public static func remove(stateDir: URL, port: UInt16) {
        try? FileManager.default.removeItem(at: url(stateDir: stateDir, port: port))
    }
}
