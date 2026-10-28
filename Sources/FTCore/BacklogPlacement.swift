// BacklogPlacement.swift
// 待っている仕事を全部「一番早く終わる担い手」へ順に仮に積み、要求した担い手が最初に受け持つものを返す(JobSchedule / DynamicSplit が共有)。
// 純粋関数。候補を1本ずつ「他の担い手の次の空き」とだけ比べると、他の担い手に控えている仕事を数えず、
// 遅い担い手が控えの山を前に待ち続ける(実測は PT-8.1)。
public enum BacklogPlacement {

    /// 仮に積んだ1本。availableBefore = 積む直前のその担い手の空く時刻[ms](reconsiderAt の計算に使う)
    public struct Placement<Job, Worker> {
        public let job: Job
        public let worker: Worker
        public let availableBefore: Double
    }

    /// jobs は試す順(LPT なら見込みの長い順)。cost(job, worker) = その担い手で始めてから終わるまで[ms](nil = 回せない)。
    /// 同着は requester を先に・次に workers の並び順(here <= alt の規則と同じ向き = 同着なら要求した側が取る)。
    /// requester に1本も積まれなければ first は nil(= 待つほうが早い)
    public static func place<Job, Worker: Equatable>(
        jobs: [Job], requester: Worker, requesterAvailable: Double,
        workers: [(worker: Worker, available: Double)], cost: (Job, Worker) -> Double?
    ) -> (first: Job?, placements: [Placement<Job, Worker>]) {
        var slots = [(worker: requester, available: requesterAvailable)] + workers.filter { $0.worker != requester }
        var placements: [Placement<Job, Worker>] = []
        var first: Job?
        for job in jobs {
            var best: (index: Int, finish: Double)?
            for (index, slot) in slots.enumerated() {
                guard let c = cost(job, slot.worker) else { continue }
                let finish = slot.available + c
                if finish < (best?.finish ?? .infinity) { best = (index, finish) }
            }
            guard let best else { continue }
            placements.append(Placement(job: job, worker: slots[best.index].worker, availableBefore: slots[best.index].available))
            slots[best.index].available = best.finish
            if best.index == 0, first == nil { first = job }
        }
        return (first, placements)
    }
}
