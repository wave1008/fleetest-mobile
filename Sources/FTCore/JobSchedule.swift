// JobSchedule.swift
// マシンをまたぐ複数対象の run で、空いたマシンに次の仕事(対象1つ = 子 run 1本)を今始めるか・加わるか・待つかの判定(RR-8.2)。
// 純粋関数: 時計も I/O も持たない。時刻[ms]は呼び手が決めた単調な1本の軸。DynamicSplit(シナリオ単位)と同じ規則を仕事の単位へ上げたもの。
//
// 規則(ユーザー指示):
// - 候補 = まだ誰も始めていない仕事のうちこのマシンで回せるもの。マシンでの見込みの長い順(同着は ID 昇順 = LPT・決定的)
// - 未着手の仕事を全部(このマシンで回せないものも = 他マシンを塞ぐ)LPT の順に「終わり = 空く時刻 + 固定費 + 見込み」が
//   一番早いマシンへ仮に積み(BacklogPlacement。同着はこのマシン)、このマシンに最初に積まれた仕事を始める。
//   控えが1本なら here = 今 + 固定費 + 見込み <= alt = 他マシンの一番早い終わり、と同じ
// - 1本も積まれなければ待たせる(遅いマシンが終わり際に長い仕事を取って全体を引き延ばさない = 待たせる理由)。
//   他マシンに控えている仕事を数えずに比べると、控えの山を前に遅いマシンが待ち続ける
// - 安全弁: 他マシンが見込みの時刻を過ぎても空かないときは、超過した分だけ空く時刻を後ろへ倒す(固まったマシンを待ち続けない)。
//   見込みの無い busy マシンは空く時刻を無限遠とみなす(待たない)。待たせた判断が変わりうる時刻は reconsiderAt で返す
// - 加わる(終わり際): 始められる候補がそもそも無い(このマシンで回せる未着手の仕事が無い)ときだけ。
//   走っている仕事 J(未配のシナリオあり・このマシンはまだ加わっていない・回せる)ごとに joinGainMs(J, このマシン)
//   (呼び手が joinGain で出す)が正で最大のものに加わる。nil・0 以下は加わらない
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
        joinGainMs: (String, Int) -> Double?,
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

        // 仮に積む順の鍵 = このマシンでの見込み(回せない仕事は回せるマシンの最短)。どこでも回せない仕事は積まない
        let keyed: [(job: String, key: Double)] = unstarted.compactMap { job in
            if let here = aloneMs(job, machine) { return (job, here) }
            return others.compactMap { aloneMs(job, $0.machine) }.min().map { (job, $0) }
        }
        let order = lpt
            ? keyed.sorted { $0.key != $1.key ? $0.key > $1.key : $0.job < $1.job }.map(\.job) : keyed.map(\.job)
        let placed = BacklogPlacement.place(
            jobs: order, requester: machine, requesterAvailable: now,
            workers: others.map { (worker: $0.machine, available: freeAt($0)) },
            cost: { job, m in aloneMs(job, m).map { overheadMs(m) + $0 } })
        if let first = placed.first { return .start(first) }

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
                    // 超過中は alt も here も時刻に 1:1 で伸びるので、t + (t - expected) + B + oM + aM >= t + oH + aH を解く。
                    // B = 仮に積んだときその仕事より先にそのマシンへ積まれた分(0 = 控えを数えない場合の時刻。早めに見直すのは害が無い)
                    let placedOn = Dictionary(placed.placements.map { ($0.job, $0) }, uniquingKeysWith: { first, _ in first })
                    for candidate in candidates {
                        guard let aOther = aloneMs(candidate.job, state.machine) else { continue }
                        let base = expected + (overhead + candidate.alone) - (overheadMs(state.machine) + aOther)
                        consider(base)
                        if let p = placedOn[candidate.job], p.worker == state.machine {
                            consider(base - (p.availableBefore - freeAt(state)))
                        }
                    }
                }
            }
            return .hold(reconsiderAt: reconsiderAt)
        }

        var best: (job: String, gain: Double)?
        var couldRun = false
        for job in running.keys.sorted() where hasPending(job) {
            guard aloneMs(job, machine) != nil else { continue }
            couldRun = true
            guard let members = running[job], !members.contains(machine) else { continue }
            if let gain = joinGainMs(job, machine), gain > 0, gain > (best?.gain ?? 0) { best = (job, gain) }
        }
        if let best { return .join(best.job) }
        return couldRun ? .hold(reconsiderAt: nil) : .done
    }

    /// 加わる判定のための1つのレーン(マシンのその仕事のデバイス群)。availableAt = そのデバイスたちが次を取れる時刻[ms]
    public struct JoinLane: Sendable {
        public let entry: Int
        public let devices: Int
        public let platforms: Set<String>
        public let availableAt: Double
        public init(entry: Int, devices: Int, platforms: Set<String>, availableAt: Double) {
            self.entry = entry
            self.devices = devices
            self.platforms = platforms
            self.availableAt = availableAt
        }
    }

    /// 加わると全体の終わりがどれだけ早まるか[ms]。配っていないシナリオを今の担当のデバイスだけ / 加わるデバイスも含めて
    /// 1本ずつ仮に積み(BacklogPlacement。配る側の DynamicSplit と同じ見方)、終わりの差を返す。
    /// 加わるデバイスに1本も積まれなければ nil —— 量を割れるものとして速さの和で見ると、固定費を払って加わったのに
    /// 速い担当が先に全部取り、1本ももらえないまま子 run の後始末のぶん全体の終わりを延ばした(PT-8.1)。
    /// 担当のデバイスは今すぐ空くとみなす(回しているシナリオの残りを数えない = 加わらない側へ倒れる)。
    /// 担当にも加わる側にも回せないシナリオは積まない(他のマシンの担当分。残すと「加わった場合」も無限遠になり加われない)
    public static func joinGain(
        pending: [DynamicSplit.Scenario], members: [JoinLane], joiner: JoinLane,
        estimateMs: (DynamicSplit.Scenario, Int) -> Double
    ) -> Double? {
        struct Slot: Equatable { let lane: Int; let device: Int }
        func slots(_ lanes: [JoinLane], offset: Int) -> [(worker: Slot, available: Double)] {
            lanes.enumerated().flatMap { i, lane in
                (0..<max(lane.devices, 1)).map { (worker: Slot(lane: offset + i, device: $0), available: lane.availableAt) }
            }
        }
        let all = members + [joiner]
        func cost(_ scenario: DynamicSplit.Scenario, _ slot: Slot) -> Double? {
            let lane = all[slot.lane]
            return lane.platforms.contains(scenario.platform) ? estimateMs(scenario, lane.entry) : nil
        }
        let order = pending.filter { s in all.contains { $0.platforms.contains(s.platform) } }.sorted { a, b in
            let ka = all.filter { $0.platforms.contains(a.platform) }.map { estimateMs(a, $0.entry) }.min() ?? 0
            let kb = all.filter { $0.platforms.contains(b.platform) }.map { estimateMs(b, $0.entry) }.min() ?? 0
            return ka != kb ? ka > kb : a.id < b.id
        }
        /// 終わりの時刻。積めないシナリオが残れば無限遠。同着は担当の側(配る側でも同着は先に要求したレーン = 加わる側に寄せない)
        func finish(_ workers: [(worker: Slot, available: Double)]) -> (end: Double, joinerTook: Bool) {
            guard let head = workers.first else { return (.infinity, false) }
            let placed = BacklogPlacement.place(
                jobs: order, requester: head.worker, requesterAvailable: head.available,
                workers: Array(workers.dropFirst()), cost: cost)
            if placed.placements.count < order.count { return (.infinity, false) }
            let end = placed.placements.map { $0.availableBefore + (cost($0.job, $0.worker) ?? 0) }.max() ?? 0
            return (end, placed.placements.contains { $0.worker.lane == members.count })
        }
        let memberSlots = slots(members, offset: 0)
        let without = finish(memberSlots)
        let with = finish(memberSlots + slots([joiner], offset: members.count))
        guard with.joinerTook, with.end.isFinite else { return nil }
        return without.end - with.end
    }
}
