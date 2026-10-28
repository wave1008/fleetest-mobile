// DynamicSplit.swift
// マシンをまたぐ run で、空いたデバイスレーンに次のシナリオを今渡すか待たせるかの判定(RR-8.1)。
// 純粋関数: 時計も I/O も持たない。時刻[ms]は呼び手が決めた単調な1本の軸。
//
// 規則(ユーザー指示):
// - 候補 = そのレーンの platform で回せる待ちシナリオ。見込みの長い順(同着は ID 昇順 = LPT・決定的)
// - 候補を全部その順に、他レーン(他マシン + 同じマシンの他レーン)も含めて「空く時刻 + そのレーンでの見込み」が一番早いレーンへ
//   仮に積み(BacklogPlacement。同着はこのレーン)、このレーンに最初に積まれた候補を渡す。
//   候補が1本なら here = 今 + このレーンでの見込み <= alt = 他レーンの一番早い終わり、と同じ
// - 1本も積まれなければ待たせる(遅いマシンが終わり際に長いシナリオを取って全体を引き延ばさない)。
//   他レーンに控えている候補を数えずに比べると、控えの山を前に遅いレーンが待ち続ける
// - 安全弁: 他レーンが見込みの時刻を過ぎても空かないときは、超過した分だけ空く時刻を後ろへ倒す
//   (固まった速いレーンを遅いレーンが待ち続けない)。待たせた判断が変わりうる時刻は reconsiderAt で返す
public enum DynamicSplit {

    /// 配る単位。platform は呼び手が解決済み(未宣言は run の既定 platform。子の run と同じ規則)
    public struct Scenario: Hashable, Sendable {
        public let id: String
        public let platform: String
        public init(id: String, platform: String) {
            self.id = id
            self.platform = platform
        }
    }

    /// マシン(エントリ)の中の1レーン(デバイス)。entry = FleetSplit.Estimator の entry 番号
    public struct Lane: Hashable, Sendable {
        public let entry: Int
        public let lane: String
        public let platform: String
        public init(entry: Int, lane: String, platform: String) {
            self.entry = entry
            self.lane = lane
            self.platform = platform
        }
    }

    /// レーンの今。busy = 回しているシナリオと渡した時刻[ms]。nil = 空いて次を待っている
    public struct LaneState: Sendable {
        public let lane: Lane
        public let busy: (scenario: Scenario, since: Double)?
        public init(lane: Lane, busy: (scenario: Scenario, since: Double)?) {
            self.lane = lane
            self.busy = busy
        }
    }

    public enum Decision: Equatable, Sendable {
        /// このシナリオ ID を渡す
        case assign(String)
        /// 渡さず待たせる。この時刻[ms]になったら判断が変わりうる(nil = 他のレーンの知らせを待つだけ)
        case hold(reconsiderAt: Double?)
        /// このレーンが回せるシナリオはもう無い(レーンは終わる)
        case none
    }

    public static func decide(
        for requester: Lane, now: Double, pending: [Scenario], lanes: [LaneState],
        estimateMs: (Scenario, Int) -> Double, lpt: Bool = true
    ) -> Decision {
        // lpt false(`--no-lpt`)= 候補を ID 順に試す。待つかどうかの比べ方は変えない
        let candidates = pending.filter { $0.platform == requester.platform }
            .map { (scenario: $0, here: estimateMs($0, requester.entry)) }
            .sorted { lpt && $0.here != $1.here ? $0.here > $1.here : $0.scenario.id < $1.scenario.id }
        if candidates.isEmpty { return .none }

        let others = lanes.filter { $0.lane.platform == requester.platform && $0.lane != requester }

        /// 他レーンが空く見込みの時刻。超過中は超過した分だけ後ろへ倒す(安全弁)
        func freeAt(_ state: LaneState) -> Double {
            guard let busy = state.busy else { return now }
            let expected = busy.since + estimateMs(busy.scenario, state.lane.entry)
            return expected >= now ? expected : now + (now - expected)
        }

        let placed = BacklogPlacement.place(
            jobs: candidates.map(\.scenario), requester: requester, requesterAvailable: now,
            workers: others.map { (worker: $0.lane, available: freeAt($0)) },
            cost: { scenario, lane in estimateMs(scenario, lane.entry) })
        if let first = placed.first { return .assign(first.id) }
        let placedOn = Dictionary(placed.placements.map { ($0.job, $0) }, uniquingKeysWith: { first, _ in first })

        // 規則が反転しうる最も早い時刻。空いている他レーンは時刻を作らない(そのレーンの要求で判断される)
        var reconsiderAt: Double?
        func consider(_ t: Double) {
            if t > now, t < (reconsiderAt ?? .infinity) { reconsiderAt = t }
        }
        for state in others {
            guard let busy = state.busy else { continue }
            let expected = busy.since + estimateMs(busy.scenario, state.lane.entry)
            // ちょうど今は超過の側で解く(> now の時刻しか採らないので、見込みの側だと時刻が作られずタイマーが消える。JobSchedule と同じ)
            if expected > now {
                consider(expected)
            } else {
                // 超過中は alt も here も時刻に 1:1 で伸びるので、t + (t - expected) + B + estL >= t + estHere を解く。
                // B = 仮に積んだときその候補より先にそのレーンへ積まれた分(0 = 控えを数えない場合の時刻。早めに見直すのは害が無い)
                for candidate in candidates {
                    let p = placedOn[candidate.scenario]
                    let base = expected + candidate.here - estimateMs(candidate.scenario, state.lane.entry)
                    consider(base)
                    if let p, p.worker == state.lane {
                        consider(base - (p.availableBefore - freeAt(state)))
                    }
                }
            }
        }
        return .hold(reconsiderAt: reconsiderAt)
    }
}
