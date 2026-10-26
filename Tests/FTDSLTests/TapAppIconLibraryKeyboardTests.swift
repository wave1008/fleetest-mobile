// tapAppIcon の App ライブラリの検索: キーボードの下に隠れた行を押さない。xcuitest モードの SpringBoard の木
// (ランナーの /systemui/snapshot)はキーボードの申告を載せないので、木に載るキーボードの窓(inputView)で帯を決める。
// 検索欄を押した直後の木にはまだ窓が無いので、上がるまで読み直してから決める

import XCTest
@testable import FTDSL
@testable import FTCore

final class TapAppIconLibraryKeyboardTests: XCTestCase {

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ScenarioEvent] = []
        func add(_ event: ScenarioEvent) { lock.lock(); items.append(event); lock.unlock() }
        var steps: [ScenarioEvent] { lock.lock(); defer { lock.unlock() }; return items.filter { $0.kind == "step" } }
    }

    /// ホームのページにはアプリが無く、App ライブラリの検索欄だけがある。検索欄を押すと一覧が出て、最初の `offscreenReads` 枚は
    /// キーボードの窓が無く・その後は窓(inputView)が上端 545 に載る。キーボードの申告(keyboardFrame)は載せない
    /// (/systemui/snapshot と同じ)。一覧を送ると行が上がる
    private final class LibraryDriver: AppDriver, @unchecked Sendable {
        // @unchecked の根拠: 状態は lock の下でしか触らない
        private let lock = NSLock()
        private var searching = false
        private var listReads = 0
        private var dragged = false
        private var rowFrames: [Int: FTRect] = [:]
        private(set) var tappedRowFrames: [FTRect] = []
        let offscreenReads: Int
        /// true = 前の操作が検索を開いたまま残した(始めから一覧が出ている)
        init(offscreenReads: Int, searchLeftOpen: Bool = false) {
            self.offscreenReads = offscreenReads
            searching = searchLeftOpen
        }

        private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        private let fieldRef = 7

        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "stub", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws -> String? { nil }
        func uninstall(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { true }
        func foregroundAppID() async throws -> String? { nil }
        func launch(bundleID: String) async throws {}
        func home() async throws {}
        func snapshot() async throws -> SnapshotResponse {
            lock.withLock {
                guard searching else {
                    let field = ElementInfo(ref: fieldRef, type: "searchField", identifier: "dewey-search-field", label: nil,
                                            value: nil, placeholder: "アプリライブラリ", enabled: true,
                                            frame: FTRect(x: 26, y: 90, width: 254, height: 48), depth: 1)
                    return SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [field], truncatedCount: 0)
                }
                listReads += 1
                let ref = 500 + listReads
                let frame = FTRect(x: 0, y: dragged ? 300 : 522, width: 402, height: 72)
                rowFrames[ref] = frame
                let bar = ElementInfo(ref: 1, type: "other", identifier: "dewey-search-bar", label: nil, value: nil,
                                      placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 80, width: 402, height: 70), depth: 1)
                let cancel = ElementInfo(ref: 2, type: "button", identifier: nil, label: "キャンセル", value: nil,
                                         placeholder: nil, enabled: true, frame: FTRect(x: 296, y: 97, width: 80, height: 33), depth: 2)
                let row = ElementInfo(ref: ref, type: "clickable", identifier: nil, label: "FT E2E RN", value: nil,
                                      placeholder: nil, enabled: true, frame: frame, depth: 2)
                var elements = [bar, cancel, row]
                if listReads > offscreenReads {
                    elements.append(ElementInfo(ref: 3, type: "other", identifier: "inputView", label: nil, value: nil,
                                                placeholder: nil, enabled: true,
                                                frame: FTRect(x: 0, y: 545, width: 402, height: 329), depth: 1))
                }
                return SnapshotResponse(sessionBundleID: nil, screen: screen, elements: elements, truncatedCount: 0)
            }
        }
        func tap(ref: Int) async throws {
            lock.withLock {
                if ref == fieldRef { searching = true; return }
                if let frame = rowFrames[ref] { tappedRowFrames.append(frame) }
            }
        }
        func tap(x: Double, y: Double) async throws {}
        func drag(fromX: Double, fromY: Double, toX: Double, toY: Double,
                  pressSeconds: Double, durationSeconds: Double) async throws {
            lock.withLock { if searching { dragged = true } }
        }
        func type(ref: Int?, text: String) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func screenshot() async throws -> Data { Data() }
        func terminate() async throws {}
    }

    private let sink = Sink()
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ft-tapicon-lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func run(_ driver: LibraryDriver) -> FTDriveCore {
        let core = FTDriveCore(driver: driver, platform: "ios", app: "com.example.rn",
                               scenarioID: "T.S0010", scenarioTitle: "t",
                               delegate: nil, healingEnabled: false,
                               tunables: RunTunables(screenWaitTimeout: 0.3),
                               visionClassifierProjectRoot: dir, dryRun: false,
                               fingerprintCacheURL: dir.appendingPathComponent("fp.json"),
                               emit: { [sink] in sink.add($0) })
        core.appDisplayName = "FT E2E RN"
        FTRuntime.bootstrap(core: core, dslThread: Thread.current)
        defer { FTRuntime.tearDown() }
        scenario { scene(1, "s") { action { tapAppIcon() } } }
        return core
    }

    /// キーボードの窓が出る前の2枚で「押せる」と読まず、出た後の木でキーボードの下と分かって一覧を送ってから押す
    func testWaitsForTheKeyboardBeforeChoosingTheRow() {
        let driver = LibraryDriver(offscreenReads: 2)
        let core = run(driver)
        XCTAssertTrue(core.finalRecord.passed, "\(sink.steps.map { "\($0.description ?? ""): \($0.detail ?? "")" })")
        XCTAssertEqual(driver.tappedRowFrames.map(\.y), [300], "キーボードの下(y=522・中心 558)の行を押した")
    }

    /// 前の操作が検索を開いたまま残した(キーボードも出ている)とき、ホームのページの経路で一覧の行を撃たない。
    /// 一覧の経路でキーボードの下と分かって送ってから押す(-06 で同じ (201,558) を撃ち続けた形)
    func testSearchLeftOpenIsHandledAsTheLibraryList() {
        let driver = LibraryDriver(offscreenReads: 0, searchLeftOpen: true)
        let core = run(driver)
        XCTAssertTrue(core.finalRecord.passed, "\(sink.steps.map { "\($0.description ?? ""): \($0.detail ?? "")" })")
        XCTAssertEqual(driver.tappedRowFrames.map(\.y), [300], "キーボードの下(y=522・中心 558)の行を押した")
    }
}
