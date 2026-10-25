// 座標 doubleTap と fold / unfold / hinge の下書き変換(ScenarioCodeGen.command)と、
// fold 系 FlowStep を StepExecutor が黙って成功させないこと。

import XCTest
@testable import FTCore

final class ScenarioCodeGenCoordinateDoubleTapTests: XCTestCase {
    func testCoordinateDoubleTap() {
        XCTAssertEqual(ScenarioCodeGen.command(for: FlowStep(action: "doubleTap", x: 1, y: 2)),
                       "doubleTap(x: 1, y: 2)")
        XCTAssertEqual(ScenarioCodeGen.command(for: FlowStep(action: "doubleTap", settle: false, x: 1.5, y: 2)),
                       "doubleTap(x: 1.5, y: 2, settle: false)")
    }

    /// セレクタがあれば座標より優先、どちらも無ければ画面中心の形
    func testDoubleTapKeepsSelectorAndCenterForms() {
        XCTAssertEqual(ScenarioCodeGen.command(for: FlowStep(action: "doubleTap")), "doubleTap()")
        XCTAssertEqual(ScenarioCodeGen.command(for: FlowStep(action: "doubleTap", locator: FlowLocator(id: "a"))),
                       "doubleTap(\"#a\")")
    }

    func testFoldUnfoldHinge() {
        XCTAssertEqual(ScenarioCodeGen.command(for: FlowStep(action: "fold")), "fold()")
        XCTAssertEqual(ScenarioCodeGen.command(for: FlowStep(action: "unfold")), "unfold()")
        XCTAssertEqual(ScenarioCodeGen.command(for: FlowStep(action: "hinge", degrees: 130)), "hinge(130)")
        XCTAssertNil(ScenarioCodeGen.command(for: FlowStep(action: "hinge")))
    }

    func testExecutorFailsFoldStepsInsteadOfSkipping() async {
        let executor = StepExecutor(driver: FoldStepStub(), isAndroid: false, tunables: RunTunables())
        for action in ["fold", "unfold", "hinge"] {
            let outcome = await executor.execute(FlowStep(action: action, degrees: 90))
            guard case .failed(let message) = outcome.status else {
                return XCTFail("\(action) は失敗になるべき: \(outcome.status)")
            }
            XCTAssertTrue(message.contains("not executable"), message)
        }
    }
}

private final class FoldStepStub: AppDriver {
    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func launch(bundleID: String) async throws {}
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                         elements: [], truncatedCount: 0)
    }
    func tap(ref: Int) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func type(ref: Int?, text: String) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func press(ref: Int, duration: Double) async throws {}
    func screenshot() async throws -> Data { Data() }
    func terminate() async throws {}
}
