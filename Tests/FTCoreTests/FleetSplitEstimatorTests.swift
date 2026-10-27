// FleetSplit.Estimator(plan から切り出した見積り。RR-8.1)。期待値は手計算で固定し、plan が使う値と一致することも見る。

import XCTest
@testable import FTCore

final class FleetSplitEstimatorTests: XCTestCase {

    private func fixture() -> (FleetSplit.Estimator, FleetSplit.MachineContext, [LPTScheduler.Duration]) {
        let durations = [
            LPTScheduler.Duration(scenarioID: "A", platform: "ios", medianMs: 10_000),
            LPTScheduler.Duration(scenarioID: "B", platform: "ios", medianMs: 10_000),
            LPTScheduler.Duration(scenarioID: "D", platform: "ios", medianMs: 20_000),
        ]
        // fast: A/B とも混合の 1/2 → 係数 0.5 / own: A だけ 0.7 倍 → 係数 0.7 / new: 実績なし(事前係数 1.5)
        let machineDurations = [
            LPTScheduler.MachineDuration(scenarioID: "A", platform: "ios", machine: "fast", medianMs: 5_000),
            LPTScheduler.MachineDuration(scenarioID: "B", platform: "ios", machine: "fast", medianMs: 5_000),
            LPTScheduler.MachineDuration(scenarioID: "A", platform: "ios", machine: "own", medianMs: 7_000),
        ]
        let context = FleetSplit.MachineContext(
            entryMachines: ["own", "fast", "new"], entryFixedOffsetsMs: [0, 0, 0],
            machineDurations: machineDurations, entryFallbackFactors: [1, 1, 1.5])
        let estimator = FleetSplit.Estimator(
            durations: durations, entryPlatforms: [["ios"], ["ios"], ["ios"]],
            unknownDurationMs: 1_000, machineContext: context)
        return (estimator, context, durations)
    }

    func testOwnHistoryWins() {
        let (e, _, _) = fixture()
        XCTAssertEqual(e.estimateMs(id: "A", platform: nil, entry: 0), 7_000)
        XCTAssertEqual(e.estimateMs(id: "A", platform: "ios", entry: 1), 5_000)
    }

    func testMeasuredSpeedFactorScalesMixed() {
        let (e, _, _) = fixture()
        XCTAssertEqual(e.estimateMs(id: "D", platform: nil, entry: 1), 10_000, accuracy: 1e-9)
        XCTAssertEqual(e.estimateMs(id: "B", platform: nil, entry: 0), 7_000, accuracy: 1e-9)
    }

    func testFallbackFactorAndUnknownDuration() {
        let (e, _, _) = fixture()
        XCTAssertEqual(e.estimateMs(id: "D", platform: nil, entry: 2), 30_000, accuracy: 1e-9)
        XCTAssertEqual(e.estimateMs(id: "X", platform: nil, entry: 2), 1_500, accuracy: 1e-9)
        XCTAssertEqual(e.estimateMs(id: "X", platform: nil, entry: 1), 500, accuracy: 1e-9)
    }

    func testMixedMsIsMachineIndependent() {
        let (e, _, _) = fixture()
        XCTAssertEqual(e.mixedMs(id: "D", platform: nil), 20_000)
        XCTAssertEqual(e.mixedMs(id: "X", platform: "ios"), 1_000)
    }

    func testPlanUsesSameEstimates() throws {
        let (e, context, durations) = fixture()
        let result = try FleetSplit.plan(
            scenarios: [("D", nil)], durations: durations,
            entryPlatforms: [["ios"], ["ios"], ["ios"]], unknownDurationMs: 1_000, machineContext: context)
        // 見込み終了が最小(10,000)の entry1 へ入り、バケツの見積りは Estimator と同じ値
        XCTAssertEqual(result.buckets[1].scenarioIDs, ["D"])
        XCTAssertEqual(result.buckets[1].estimatedMs, e.estimateMs(id: "D", platform: nil, entry: 1))
        XCTAssertEqual(result.basis[1].scaled, 1)
    }
}
