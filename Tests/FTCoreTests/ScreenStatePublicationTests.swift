import XCTest
@testable import FTCore

/// 描画の状態(白紙・文字消え)の公表: ストアの往復・所見の写像・公表の判定・実行機の反映・型で守れない配線
final class ScreenStatePublicationTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
    private let texts = [FTRect(x: 20, y: 100, width: 200, height: 30), FTRect(x: 20, y: 200, width: 200, height: 30),
                         FTRect(x: 20, y: 300, width: 200, height: 30)]
    private let button = FTRect(x: 20, y: 400, width: 360, height: 50)

    private func elements() -> [ElementInfo] {
        texts.enumerated().map { i, f in
            ElementInfo(ref: i + 1, type: "staticText", identifier: nil, label: "見出し\(i)", value: nil, placeholder: nil,
                        enabled: true, frame: f, depth: 1)
        } + [ElementInfo(ref: 99, type: "button", identifier: "btn", label: "送信", value: nil, placeholder: nil,
                         enabled: true, frame: button, depth: 1)]
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ft-screen-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - ストア

    func testStoreRoundTripAndClear() throws {
        let dir = try tempDir()
        XCTAssertNil(DeviceScreenStateStore.current(stateDir: dir, key: "udid-a"))
        DeviceScreenStateStore.publish(stateDir: dir, key: "udid-a", state: .textless)
        XCTAssertEqual(DeviceScreenStateStore.current(stateDir: dir, key: "udid-a"), .textless)
        XCTAssertNil(DeviceScreenStateStore.current(stateDir: dir, key: "udid-b"))
        DeviceScreenStateStore.clear(stateDir: dir, key: "udid-a")
        XCTAssertNil(DeviceScreenStateStore.current(stateDir: dir, key: "udid-a"))
    }

    /// 書き手(短命なシナリオのプロセス)が死んでいても有効。鮮度は書いた時刻だけで見る
    func testStoreExpiresByWrittenTimeOnly() throws {
        let dir = try tempDir()
        let written = Date()
        DeviceScreenStateStore.publish(stateDir: dir, key: "k", state: .blank, now: written)
        let limit = DeviceScreenStateStore.stalenessSeconds
        XCTAssertEqual(DeviceScreenStateStore.current(stateDir: dir, key: "k", now: written.addingTimeInterval(limit)), .blank)
        XCTAssertNil(DeviceScreenStateStore.current(stateDir: dir, key: "k", now: written.addingTimeInterval(limit + 1)))
    }

    func testStoreDefaultsAndNamesArePinned() {
        XCTAssertEqual(DeviceScreenStateStore.stalenessSeconds, 1800)
        XCTAssertEqual(DeviceScreenStateStore.entryURL(stateDir: URL(fileURLWithPath: "/x"), key: "K").lastPathComponent,
                       "screen-state-K.json")
        XCTAssertEqual(DeviceScreenState.blank.rawValue, "blank")
        XCTAssertEqual(DeviceScreenState.textless.rawValue, "textless")
    }

    // MARK: - 写像と公表の判定

    func testFindingMapping() {
        XCTAssertEqual(RenderCollapse.screenState(of: .blankAppArea(textElements: 3)), .blank)
        XCTAssertEqual(RenderCollapse.screenState(of: .noTextDrawn(textElements: 3)), .textless)
        XCTAssertNil(RenderCollapse.screenState(of: .wholeScreenBlank(textElements: 3)), "全画面は凍結の担当")
    }

    func testPublishesOnlyOnSimulatorAndEmulator() {
        XCTAssertTrue(StepExecutor.publishesScreenState(platform: "ios", physical: false))
        XCTAssertTrue(StepExecutor.publishesScreenState(platform: "android", physical: false))
        XCTAssertFalse(StepExecutor.publishesScreenState(platform: "ios", physical: true))
        XCTAssertFalse(StepExecutor.publishesScreenState(platform: "android", physical: true))
    }

    // MARK: - 実行機

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [DeviceScreenState?] = []
        func record(_ value: DeviceScreenState?) { lock.lock(); values.append(value); lock.unlock() }
        var all: [DeviceScreenState?] { lock.lock(); defer { lock.unlock() }; return values }
    }

    private func executor(_ png: Data, redChecks: Bool) -> (StepExecutor, Sink) {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [elements()])
        driver.screenshots = [png, png]
        let executor = StepExecutor(driver: driver, occlusionGuardEnabled: false, isAndroid: false, tunables: RunTunables())
        executor.renderCollapseCheckEnabled = redChecks
        let sink = Sink()
        executor.screenStatePublisher = { sink.record($0) }
        return (executor, sink)
    }

    private func verdict(_ executor: StepExecutor) async -> String? {
        _ = await executor.execute(FlowStep(assert: "exists", locator: FlowLocator(id: "btn")))
        return await executor.renderCollapseVerdict()
    }

    /// 赤にしない構成(Android 等)でも文字消えを公表し、判定(戻り値)は変えない
    func testTextlessIsPublishedWithoutFailingWhenChecksAreOff() async {
        let (executor, sink) = executor(RenderCollapseTests.png(shapes: [button]), redChecks: false)
        let message = await verdict(executor)
        XCTAssertNil(message)
        XCTAssertEqual(sink.all, [.textless])
        XCTAssertEqual(executor.renderCollapseNotes, [.screenTextless])
    }

    func testBlankIsPublished() async {
        let (executor, sink) = executor(RenderCollapseTests.png(), redChecks: false)
        _ = await verdict(executor)
        XCTAssertEqual(sink.all, [.blank])
        XCTAssertEqual(executor.renderCollapseNotes, [.screenBlank])
    }

    /// 赤にする構成は従来どおり失敗文を返し、同じ状態を公表する
    func testRedChecksStillFailAndPublish() async {
        let (executor, sink) = executor(RenderCollapseTests.png(shapes: [button]), redChecks: true)
        let message = await verdict(executor)
        XCTAssertNotNil(message)
        XCTAssertEqual(sink.all, [.textless])
    }

    /// 異常が無い確かめは公表を消す
    func testHealthyCheckClearsThePublication() async {
        let (executor, sink) = executor(RenderCollapseTests.png(shapes: [button], inked: texts), redChecks: false)
        _ = await verdict(executor)
        XCTAssertEqual(sink.all, [nil])
    }

    /// 全画面の一色は凍結の担当: 公表も消去もしない
    // 画素で文字を確かめた検証は区切りの義務を残さない = 区切りが走らないので、ここで消さないと印が鮮度切れまで残る
    func testPixelProofClearsThePublicationOnce() async {
        let (executor, sink) = executor(RenderCollapseTests.png(shapes: [button]), redChecks: false)
        executor.pixelsShowedTextThisStep = true
        let step = FlowStep(assert: "textEquals", locator: FlowLocator(id: "btn"))
        executor.noteAssertionForRenderCollapse("textEquals", step: step, status: .passed)
        executor.noteAssertionForRenderCollapse("textEquals", step: step, status: .passed)
        XCTAssertEqual(sink.all, [nil])
    }

    func testWholeScreenBlankIsLeftAlone() async {
        let (executor, sink) = executor(RenderCollapseTests.png(statusBar: false), redChecks: false)
        _ = await verdict(executor)
        XCTAssertEqual(sink.all, [])
    }

    private func code(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testWiring() throws {
        let assertSource = try code("Sources/FTCore/StepExecutor+Assert.swift")
        // 赤が確定した2か所だけ(poll の途中で公表しない)
        XCTAssertEqual(assertSource.components(separatedBy: "publishScreenStateAfterNotRendered()\n            return lastOcclusion").count - 1, 2)
        XCTAssertTrue(try code("Sources/FTDSL/FTRuntime.swift").contains("executor.screenStatePublisher ="))
        XCTAssertTrue(try code("Sources/FTScenarioRunner/ScenarioRunnerMain.swift").contains("screenStateDirectory:"))
        XCTAssertTrue(try code("Sources/fleetest/ApiMonitorCommand.swift").contains("Self.screenState(key: leaseKey"))
        // run ボード: 凍結の離脱(retireUnusable)と、ステップの注記(型 StepNote 経由)の両方が親の集計へ届く
        let orchestrator = try code("Sources/FTCore/RunOrchestrator.swift")
        XCTAssertTrue(orchestrator.contains("deviceStateObserved(deviceKey: progressLaneKey, state: .frozen)"))
        XCTAssertTrue(orchestrator.contains("compactMap(RunDeviceState.init(note:))"))
    }
}
