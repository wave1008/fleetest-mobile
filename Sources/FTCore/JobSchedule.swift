// JobSchedule.swift
// マシンをまたぐ複数対象の run で、空いたマシンに次の仕事(対象1つ = 子 run 1本)を今始めるか・加わるか・待つかの判定(RR-8.2)。
// 純粋関数: 時計も I/O も持たない。時刻[ms]は呼び手が決めた単調な1本の軸。DynamicSplit(シナリオ単位)と同じ規則を仕事の単位へ上げたもの。
//
// 規則(ユーザー指示):
// - 候補 = まだ誰も始めていない仕事のうちこのマシンで回せるもの。マシンでの見込みの長い順(同着は ID 昇順 = LPT・決定的)
// - 候補ごとに here = 今 + 固定費 + このマシンだけで回す見込み / alt = 他マシンが空いてから回したときの一番早い終わり
//   (空く時刻 + そのマシンの固定費 + そのマシンでの見込み)。here <= alt の最初の候補を始める
// - 始められる候補が無ければ待たせる(遅いマシンが終わり際に長い仕事を取って全体を引き延ばさない = 待たせる理由)
// - 安全弁: 他マシンが見込みの時刻を過ぎても空かないときは、超過した分だけ空く時刻を後ろへ倒す(固まったマシンを待ち続けない)。
//   見込みの無い busy マシンは空く時刻を無限遠とみなす(待たない)。待たせた判断が変わりうる時刻は reconsiderAt で返す
// - 加わる(終わり際): 始められる候補がそもそも無い(このマシンで回せる未着手の仕事が無い)ときだけ。
//   走っている仕事 J(未配のシナリオあり・このマシンはまだ加わっていない・回せる)ごとに、今の担当 S の合計速度 rS = Σ1/見込み から
//   加わらない終わり = 今 + 1/rS、加わる終わり = 今 + 固定費 + (1 - rS*固定費) / (rS + rM)。差(gain)が正で最大のものに加わる。
//   固定費のあいだに S だけで終わる(rS*固定費 >= 1)なら加わらない
public enum JobSchedule {

    public enum Decision: Equatable, Sendable {
        /// まだ誰も始めていない仕事をこのマシンで始める
        case start(String)
        /// 走っている仕事に2台目以降として加わる(終わり際だけ)
        case join(String)
        /// 何もしないで待つ。この時刻[ms]になれば判断が変わりうる(nil = 他のマシンの知らせを待つだけ)
        case hold(reconsiderAt: Double?)
        /// このマシンにできることはもう無い
        case done
    }

    /// マシンの今。currentJob nil = 空いて次を待っている。expectedFreeAt = 走っている仕事が終わる見込み[ms](busy のとき。nil = 見込み無し)
    public struct MachineState: Sendable {
        public let machine: Int
        public let currentJob: String?
        public let expectedFreeAt: Double?
        public init(machine: Int, currentJob: String?, expectedFreeAt: Double?) {
            self.machine = machine
            self.currentJob = currentJob
            self.expectedFreeAt = expectedFreeAt
        }
    }

    public static func decide(
        for machine: Int, now: Double,
        unstarted: [String],
        running: [String: Set<Int>],
        hasPending: (String) -> Bool,
        machines: [MachineState],
        aloneMs: (String, Int) -> Double?,
        overheadMs: (Int) -> Double,
        lpt: Bool = true
    ) -> Decision {
        let overhead = overheadMs(machine)
        // lpt false(`--no-lpt`)= unstarted の並び(宣言の順)のまま試す
        let fitting: [(job: String, alone: Double)] = unstarted
            .compactMap { job in aloneMs(job, machine).map { (job: job, alone: $0) } }
        let candidates = lpt
            ? fitting.sorted { $0.alone != $1.alone ? $0.alone > $1.alone : $0.job < $1.job } : fitting
        let others = machines.filter { $0.machine != machine }

        /// 他マシンが空く見込みの時刻。超過中は超過した分だけ後ろへ倒す(安全弁)・見込み無しの busy は無限遠
        func freeAt(_ state: MachineState) -> Double {
            if state.currentJob == nil { return now }
            guard let expected = state.expectedFreeAt else { return .infinity }
            return expected >= now ? expected : now + (now - expected)
        }

        for candidate in candidates {
            let here = now + overhead + candidate.alone
            let alt = others.compactMap { state -> Double? in
                aloneMs(candidate.job, state.machine).map { freeAt(state) + overheadMs(state.machine) + $0 }
            }.min() ?? .infinity
            if here <= alt { return .start(candidate.job) }
        }

        if !candidates.isEmpty {
            // 規則が反転しうる最も早い時刻。空いている他マシンは時刻を作らない(そのマシンの要求で判断される)
            var reconsiderAt: Double?
            func consider(_ t: Double) {
                if t > now, t < (reconsiderAt ?? .infinity) { reconsiderAt = t }
            }
            for state in others {
                guard state.currentJob != nil, let expected = state.expectedFreeAt else { continue }
                // ちょうど今は超過の側で解く(DynamicSplit と同じ理由: > now の時刻しか採らないので見込みの側だと時刻が作られない)
                if expected > now {
                    consider(expected)
                } else {
                    // 超過中は alt も here も時刻に 1:1 で伸びるので、t + (t - expected) + oM + aM >= t + oH + aH を解く
                    for candidate in candidates {
                        guard let aOther = aloneMs(candidate.job, state.machine) else { continue }
                        consider(expected + (overhead + candidate.alone) - (overheadMs(state.machine) + aOther))
                    }
                }
            }
            return .hold(reconsiderAt: reconsiderAt)
        }

        var best: (job: String, gain: Double)?
        var couldRun = false
        for job in running.keys.sorted() where hasPending(job) {
            guard let rm = aloneMs(job, machine).map({ 1 / $0 }) else { continue }
            couldRun = true
            guard let members = running[job], !members.contains(machine) else { continue }
            let rS = members.compactMap { aloneMs(job, $0) }.reduce(0.0) { $0 + 1 / $1 }
            if rS <= 0 { continue }
            let doneDuringOverhead = rS * overhead
            if doneDuringOverhead >= 1 { continue }
            let finishWithout = now + 1 / rS
            let finishWith = now + overhead + (1 - doneDuringOverhead) / (rS + rm)
            let gain = finishWithout - finishWith
            if gain > 0, gain > (best?.gain ?? 0) { best = (job, gain) }
        }
        if let best { return .join(best.job) }
        return couldRun ? .hold(reconsiderAt: nil) : .done
    }
}
