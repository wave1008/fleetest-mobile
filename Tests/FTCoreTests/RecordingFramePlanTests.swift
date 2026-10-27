// RecordingFramePlan(results frames の計画)の純粋な検証。

import XCTest
@testable import FTCore

final class RecordingFramePlanTests: XCTestCase {

    private let base = ISO8601Millis.date(from: "2026-10-27T00:00:10.000Z")!
    private func t(_ s: Double) -> Date { base.addingTimeInterval(s) }
    private func step(_ i: Int, _ s: Double, _ e: Double, failed: Bool = false) -> RecordingFramePlan.Step {
        .init(index: i, command: "cmd\(i)", start: t(s), end: t(e), failed: failed)
    }
    private var steps: [RecordingFramePlan.Step] {
        [step(1, 0, 4), step(2, 4, 8), step(3, 10, 12, failed: true)]
    }
    private func seg(_ s: Double, _ ms: Int) -> RecordingIndexSegment {
        .init(startedAt: ISO8601Millis.string(from: t(s)), durationMs: ms)
    }

    func testDefaultRangeStartsSecondsBeforeFailedStepAndEndsAtItsEnd() throws {
        let frames = try RecordingFramePlan.plan(
            steps: steps, segments: [seg(0, 20_000)],
            options: .init(secondsBefore: 2, every: 1))
        XCTAssertEqual(frames.map { $0.wall }, [t(8), t(9), t(10), t(11), t(12)])
        XCTAssertEqual(frames.first?.clipSeconds, 8)
        XCTAssertEqual(frames.last?.stepIndex, 3)
    }

    func testStepRangeUsesStartOfFirstAndEndOfLast() throws {
        let frames = try RecordingFramePlan.plan(
            steps: steps, segments: [seg(0, 20_000)], options: .init(steps: 2...3, every: 2))
        XCTAssertEqual(frames.first?.wall, t(4))
        XCTAssertEqual(frames.last?.wall, t(12))
        XCTAssertEqual(frames.count, 5)
    }

    func testFrameInRecordingGapHasNoClipPosition() throws {
        // 録画 0-5s と 7-20s(連結: 7s は clip の 5s)
        let frames = try RecordingFramePlan.plan(
            steps: steps, segments: [seg(0, 5_000), seg(7, 13_000)],
            options: .init(steps: 2...2, every: 1))
        // t=4 → 4s / t=5,6 → 録画なし / t=7 → 5s / t=8 → 6s
        XCTAssertEqual(frames.map { $0.clipSeconds }, [4.0, nil, nil, 5.0, 6.0])
    }

    func testLabelBetweenStepsIsThePreviousStep() throws {
        let frames = try RecordingFramePlan.plan(
            steps: steps, segments: [seg(0, 20_000)], options: .init(steps: 2...3, every: 1))
        // t=9 は step2(終了 8)と step3(開始 10)の間 → 直前に終わった step2
        let f = frames.first { $0.wall == t(9) }
        XCTAssertEqual(f?.stepIndex, 2)
    }

    func testFrameCountCapRefuses() {
        XCTAssertThrowsError(try RecordingFramePlan.plan(
            steps: steps, segments: [seg(0, 20_000)],
            options: .init(steps: 1...3, every: 0.01))) { error in
            XCTAssertTrue((error as? RecordingFramePlanError)?.message.contains("--every") == true)
        }
    }

    func testNoFailedStepWithoutStepsIsRefused() {
        let ok = [step(1, 0, 4)]
        XCTAssertThrowsError(try RecordingFramePlan.plan(steps: ok, segments: [seg(0, 5_000)], options: .init())) {
            XCTAssertTrue(($0 as? RecordingFramePlanError)?.message.contains("--steps") == true)
        }
    }

    func testParseStepRange() {
        XCTAssertEqual(RecordingFramePlan.parseStepRange("60-72"), 60...72)
        XCTAssertEqual(RecordingFramePlan.parseStepRange("67"), 67...67)
        XCTAssertNil(RecordingFramePlan.parseStepRange("72-60"))
        XCTAssertNil(RecordingFramePlan.parseStepRange("a"))
    }

    // MARK: - デバイス選択

    private func cand(_ name: String, failed: Bool) -> RecordingFramePlan.Candidate {
        .init(worker: "ios:\(name)", failed: failed)
    }

    func testSingleCandidateIsChosen() throws {
        XCTAssertEqual(try RecordingFramePlan.selectCandidate([cand("A", failed: false)], device: nil), 0)
    }

    func testDeviceOptionMatchesNamePart() throws {
        let c = [cand("A-01", failed: true), cand("A-02", failed: true)]
        XCTAssertEqual(try RecordingFramePlan.selectCandidate(c, device: "A-02"), 1)
    }

    func testOneFailedAmongManyIsChosen() throws {
        let c = [cand("A", failed: false), cand("B", failed: true), cand("C", failed: false)]
        XCTAssertEqual(try RecordingFramePlan.selectCandidate(c, device: nil), 1)
    }

    func testAmbiguousListsDeviceNames() {
        let c = [cand("A", failed: true), cand("B", failed: true)]
        XCTAssertThrowsError(try RecordingFramePlan.selectCandidate(c, device: nil)) {
            let m = ($0 as? RecordingFramePlanError)?.message ?? ""
            XCTAssertTrue(m.contains("A, B"), m)
        }
    }

    /// 既定値はリテラルで固定する(差し替え口で値を渡すテストだけだと、既定を戻す変更が緑のまま通る)
    func testDefaultsArePinned() {
        XCTAssertEqual(RecordingFramePlan.defaultSecondsBefore, 5)
        XCTAssertEqual(RecordingFramePlan.defaultEvery, 0.5)
        XCTAssertEqual(RecordingFramePlan.maxFrames, 200)
    }
}
