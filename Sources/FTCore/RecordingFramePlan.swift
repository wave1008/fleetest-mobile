// RecordingFramePlan.swift
// `fleetest results frames` の計画(どの壁時計の時刻を録画のどの位置で切り出すか)。
// ファイル IO・AVFoundation 非依存の純粋関数。描画と IO は Sources/fleetest/ResultsFramesCommand.swift。
// 規則:
//  - ステップの `at` は **終了時刻**。開始 = at − durationMs
//  - 時刻 t のラベルになるステップ: 区間 [開始, 終了] に t を含む最初のもの。どれにも含まれない
//    (ステップ間・前後)なら **直前に終わったステップ**(画面はその結果を映している)。最初のステップより前なら最初のステップ
//  - 録画の区間(segments)に含まれない t は clipSeconds = nil(絵なし)

import Foundation

public struct RecordingFramePlanError: Error, LocalizedError, Equatable {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum RecordingFramePlan {

    /// 1 枚のタイルに載せる枚数の上限。1 枚の PNG を読める大きさ・メモリに収めるため(1 枚 = 縮小した 1 フレーム)。
    /// 尽きたら黙って間引かず、--every か範囲を変えるよう案内して断る
    public static let maxFrames = 200
    /// 既定の範囲 = 最初の失敗ステップと、その開始のこの秒数前から(失敗の直前に画面で起きたことを見るため)
    public static let defaultSecondsBefore: Double = 5
    /// 既定のコマの間隔(秒)。整定・キーボードの出入り(約 0.3〜1.3 秒)を1〜2コマで捉えられる細かさ
    public static let defaultEvery: Double = 0.5

    public struct Step: Equatable, Sendable {
        public var index: Int
        public var command: String?
        public var start: Date
        public var end: Date
        public var failed: Bool
        public init(index: Int, command: String?, start: Date, end: Date, failed: Bool) {
            self.index = index; self.command = command; self.start = start; self.end = end; self.failed = failed
        }
    }

    public struct Options: Equatable, Sendable {
        /// 両端を含むステップ番号の範囲。nil = 最初の失敗ステップ
        public var steps: ClosedRange<Int>?
        public var secondsBefore: Double
        public var every: Double
        public init(steps: ClosedRange<Int>? = nil, secondsBefore: Double = RecordingFramePlan.defaultSecondsBefore,
                    every: Double = RecordingFramePlan.defaultEvery) {
            self.steps = steps; self.secondsBefore = secondsBefore; self.every = every
        }
    }

    public struct Frame: Equatable, Sendable {
        public var wall: Date
        /// 録画ファイル内の位置(秒)。録画の区間外なら nil
        public var clipSeconds: Double?
        public var stepIndex: Int?
        public var command: String?
    }

    /// `--steps` の値("60-72" または "67")。不正は nil
    public static func parseStepRange(_ raw: String) -> ClosedRange<Int>? {
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        switch parts.count {
        case 1:
            guard let n = Int(parts[0]) else { return nil }
            return n...n
        case 2:
            guard let a = Int(parts[0]), let b = Int(parts[1]), a <= b else { return nil }
            return a...b
        default:
            return nil
        }
    }

    public static func plan(steps: [Step], segments: [RecordingIndexSegment],
                            options: Options) throws -> [Frame] {
        guard options.every > 0 else {
            throw RecordingFramePlanError(message: "--every must be greater than 0")
        }
        guard options.secondsBefore >= 0 else {
            throw RecordingFramePlanError(message: "--seconds-before must not be negative")
        }
        let ordered = steps.sorted { $0.end < $1.end }
        guard !ordered.isEmpty else {
            throw RecordingFramePlanError(message: "the scenario has no timeline steps with timestamps")
        }

        let from: Date
        let to: Date
        if let range = options.steps {
            let inRange = ordered.filter { range.contains($0.index) }
            guard let first = inRange.min(by: { $0.start < $1.start }),
                  let last = inRange.max(by: { $0.end < $1.end }) else {
                throw RecordingFramePlanError(message: "no steps in the range \(range.lowerBound)-\(range.upperBound)")
            }
            from = first.start
            to = last.end
        } else {
            guard let failed = ordered.first(where: { $0.failed }) else {
                throw RecordingFramePlanError(
                    message: "the scenario has no failed step; pass --steps <from>-<to> to choose a range")
            }
            from = failed.start.addingTimeInterval(-options.secondsBefore)
            to = failed.end
        }

        let count = Int(((to.timeIntervalSince(from)) / options.every + 1e-9).rounded(.down)) + 1
        guard count <= maxFrames else {
            throw RecordingFramePlanError(
                message: "\(count) frames would exceed the limit of \(maxFrames); use a larger --every or a narrower range")
        }

        return (0..<count).map { k in
            let wall = from.addingTimeInterval(Double(k) * options.every)
            let step = stepRunning(at: wall, in: ordered)
            return Frame(wall: wall, clipSeconds: clipSeconds(at: wall, segments: segments),
                         stepIndex: step?.index, command: step?.command)
        }
    }

    static func stepRunning(at t: Date, in ordered: [Step]) -> Step? {
        if let hit = ordered.first(where: { $0.start <= t && t <= $0.end }) { return hit }
        if let previous = ordered.last(where: { $0.end < t }) { return previous }
        return ordered.first
    }

    /// 欠落(録画を止めていた区間)は nil。区間内の位置は RecordingWallClock.offsetMs と同一規則
    static func clipSeconds(at t: Date, segments: [RecordingIndexSegment]) -> Double? {
        for segment in segments {
            guard let start = ISO8601Millis.date(from: segment.startedAt) else { continue }
            let end = start.addingTimeInterval(Double(segment.durationMs) / 1000)
            if t >= start && t < end {
                return Double(RecordingWallClock.offsetMs(segments, at: t)) / 1000
            }
        }
        return nil
    }

    // MARK: - デバイスの選択

    public struct Candidate: Equatable, Sendable {
        /// "<platform>:<デバイス論理名>"
        public var worker: String
        public var failed: Bool
        public init(worker: String, failed: Bool) { self.worker = worker; self.failed = failed }
        var deviceName: String {
            guard let colon = worker.firstIndex(of: ":") else { return worker }
            return String(worker[worker.index(after: colon)...])
        }
    }

    /// 選んだ候補の添字。1 台ならそれ・--device があれば worker 全体かデバイス名と一致するもの・
    /// 無ければ失敗が 1 台だけのときそれ・それ以外は候補を挙げて断る
    public static func selectCandidate(_ candidates: [Candidate], device: String?) throws -> Int {
        guard !candidates.isEmpty else {
            throw RecordingFramePlanError(message: "no recording found for this scenario")
        }
        if let device {
            let hits = candidates.indices.filter {
                candidates[$0].worker == device || candidates[$0].deviceName == device
            }
            guard hits.count == 1 else {
                throw RecordingFramePlanError(
                    message: "no unique recording for device \(device.debugDescription); candidates: "
                        + candidateList(candidates))
            }
            return hits[0]
        }
        if candidates.count == 1 { return 0 }
        let failed = candidates.indices.filter { candidates[$0].failed }
        if failed.count == 1 { return failed[0] }
        throw RecordingFramePlanError(
            message: "the scenario was recorded on \(candidates.count) devices (\(failed.count) failed);"
                + " pick one with --device: " + candidateList(candidates))
    }

    private static func candidateList(_ candidates: [Candidate]) -> String {
        candidates.map { $0.deviceName }.joined(separator: ", ")
    }
}
