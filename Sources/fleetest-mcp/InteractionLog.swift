// 探索中の操作を「シナリオへ落とせる形」で覚えておく(ft_draft_scenario の材料)。
//
// **なぜ要るか**: MCP の目的は「デバイスを操作しながら実セレクタを採り、Swift DSL の
// シナリオへ落とす」こと。ところが操作の系列はどこにも残らず、12 手ほど動かしても
// シナリオは会話履歴から人手で組み直すしかなかった(実測)。
//
// **記録するのは FlowStep**(自前の DTO を作らない): 生成器 `ScenarioCodeGen.render` は
// Flow/FlowStep を受けるので、ここで別の形に貯めると写像を2箇所に持つことになる。
// セレクタが決まらなかった手も**落とさずに**残し、生成時に TODO コメントへ回す
// —— 黙って消すと、出来上がったシナリオが実際の手順と食い違う。
//
// 保持はメモリだけ(プロセスが落ちたら消えてよい。永続化は範囲外)。

import Foundation
import FTCore

struct InteractionLog {

    /// 1手ぶん。`step` が nil = セレクタを解決できず DSL の行にできなかった手
    struct Entry {
        /// 生成に使える形(セレクタ解決済み)。nil なら TODO 行になる
        var step: FlowStep?
        /// TODO 行に残す説明(何を撃ったか。ref と frame を含める)
        var unresolved: String?
        /// ft_launch の位置を覚えて「直近の launch 以降」を既定範囲にする
        var isLaunch: Bool = false
        /// ft_launch の bundleID(launch のときだけ)
        var bundleID: String?
        /// @TestClass(platform:) に使う
        var platform: String?
        /// 刈り込みの一覧に出す1行。**記録時に作る** —— 生成時に組み直すと、番号付きで見せた
        /// 説明と実際に落ちる手がズレる(選んで捨てる機能では致命的)
        var summary: String = ""
        /// 手を撃った台の鍵(`MCPServer.draftDeviceKey` = `ios:<udid>` / `android:<serial>`、引けなければ sessionKey。
        /// **sessionKey と比べない**)。**下書きは1台分だけ** —— 1つのプロセスで
        /// 2台を操作すると、別デバイスの手が1本のシナリオへ混ざる。nil は宛先を持たない記録(宣言など)で、どの台の下書きにも入る
        var deviceKey: String?
    }

    private(set) var entries: [Entry] = []

    /// 記録の上限。**古いほうから捨てる** —— 長い探索でメモリを食い続けないための安全弁で、
    /// 捨てたことは draft 側が言う
    static let maximumEntries = 500

    private(set) var droppedFromFront = 0

    mutating func record(_ entry: Entry) {
        entries.append(entry)
        if entries.count > Self.maximumEntries {
            entries.removeFirst()
            droppedFromFront += 1
        }
    }

    mutating func clear() {
        entries = []
        droppedFromFront = 0
    }

    /// 下書きの材料を**1台分**に絞る(既定の範囲 = その台の直近の ft_launch 以降。launch が無ければその台の全体)。
    /// 台は最後に記録した手の宛先(いま操作している台)。**台で絞らない範囲の口を置かない**(別の台の手が混ざる)。
    /// 絞ってから「直近の launch 以降」を取る(他の台の launch が範囲の起点にならない)
    func scope(all: Bool, device: String?) -> [Entry] {
        let ofDevice = entries.filter { $0.deviceKey == nil || $0.deviceKey == device }
        guard !all, let index = ofDevice.lastIndex(where: \.isLaunch) else { return ofDevice }
        return Array(ofDevice[index...])
    }

    /// 最後に宛先付きで記録した手の台
    var latestDevice: String? { entries.last { $0.deviceKey != nil }?.deviceKey }

    /// 絞られて下書きに入らなかった別の台の手の数と、その台の一覧
    /// **範囲に入りえた手だけを数える** = `scope` と同じ起点(その台の直近の launch。`all` なら全体)より後の手
    func otherDevices(than device: String?, all: Bool) -> (count: Int, keys: [String]) {
        let start = all ? 0
            : (entries.lastIndex { $0.isLaunch && ($0.deviceKey == nil || $0.deviceKey == device) } ?? 0)
        let others = entries[start...].compactMap(\.deviceKey).filter { $0 != device }
        return (others.count, Array(Set(others)).sorted())
    }

    /// 刈り込み(F-8)。`lastN` で末尾だけに絞り、`drop` で 1 オリジンの番号を落とす。
    /// **番号は絞り込んだ後の並びに対して振る** —— 一覧を見て選ぶ道具なので、
    /// 見えている番号と落ちる手が一致していなければ意味がない。
    /// 範囲外・重複した番号は黙って無視せず、呼び出し側が報告できるよう返す
    static func prune(_ scope: [Entry], lastN: Int?,
                      drop: [Int]) -> (kept: [Entry], dropped: Int, ignored: [Int]) {
        var narrowed = scope
        if let lastN, lastN > 0, lastN < narrowed.count {
            narrowed = Array(narrowed.suffix(lastN))
        }
        let valid = Set(drop.filter { $0 >= 1 && $0 <= narrowed.count })
        let ignored = Array(Set(drop).subtracting(valid)).sorted()
        let kept = narrowed.enumerated()
            .filter { !valid.contains($0.offset + 1) }
            .map(\.element)
        return (kept, valid.count, ignored)
    }

    /// 生成対象のアプリ/プラットフォーム。範囲内の**最初の** launch から採り、無ければ全体の最後から
    /// (condition の launchApp() が起こすのはこのアプリ = 範囲の先頭の手が動いていたアプリでなければならない。
    /// all: true で複数アプリにまたがるとき、後の launch を採ると先頭の手が別アプリの上に並ぶ)。
    /// **全体の最後も `device` の台に絞る**(絞らないと、その台で launch していない下書きが別の台のアプリ・OS で作られる)
    /// **本当の launch(`isLaunch`)を resume(activate・bundleID だけ持つ)より先に採る** —— resume が先にあると、condition の
    /// launchApp() が resume しただけのアプリを起こし、本当の launch に「起動し直した」の TODO が付く(unrenderedStepNote の範囲の最初の launch と揃える)
    func target(in scope: [Entry], device: String?) -> (app: String, platform: String?) {
        // SpringBoard への ft_launch は attach(アラートを読みに行く)= 対象アプリにも起動の起点にもしない
        let candidates = scope.filter { $0.bundleID != nil && $0.bundleID != MCPServer.springboardBundleID }
        let fromScope = candidates.first { $0.isLaunch } ?? candidates.first
        let ofDevice = entries.filter { $0.bundleID != nil && $0.bundleID != MCPServer.springboardBundleID
            && ($0.deviceKey == nil || $0.deviceKey == device) }
        let fallback = ofDevice.last { $0.isLaunch } ?? ofDevice.last
        let chosen = fromScope ?? fallback
        return (chosen?.bundleID ?? "", chosen?.platform ?? scope.first { $0.platform != nil }?.platform)
    }
}
