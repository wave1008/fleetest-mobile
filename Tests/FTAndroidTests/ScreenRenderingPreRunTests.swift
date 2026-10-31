import XCTest
import FTBridgeClient
import FTCore
@testable import FTAndroid

// 回復の後に印だけが残った台を run から外さない(外すと緑の確かめが来ず、案内がマシンの再起動まで消えない)
final class ScreenRenderingPreRunTests: XCTestCase {
    /// Simulator の起動に失敗した台 = 消えた台。読めないときは消えたと言わない
    func testSimulatorIsDownOnlyWhenTheListSaysSo() {
        let down = "    iPhone 17 (AAAA-1) (Shutdown)\n    iPhone 17 (BBBB-2) (Booted)"
        XCTAssertTrue(ScreenRenderingRecoverer.simulatorIsDown(down, udid: "AAAA-1"))
        XCTAssertFalse(ScreenRenderingRecoverer.simulatorIsDown(down, udid: "BBBB-2"))
        XCTAssertFalse(ScreenRenderingRecoverer.simulatorIsDown(nil, udid: "AAAA-1"))
        XCTAssertFalse(ScreenRenderingRecoverer.simulatorIsDown(down, udid: "CCCC-3"))
    }


    private final class NullDriver: AppDriver, @unchecked Sendable {
        func screenshot() async throws -> Data { Data() }
        func status() async throws -> StatusResponse {
            StatusResponse(ready: true, device: "-", osVersion: "-", sessionBundleID: nil)
        }
        func install(packagePath: String) async throws -> String? { nil }
        func uninstall(bundleID: String) async throws {}
        func launch(bundleID: String) async throws {}
        func isAppForeground(bundleID: String) async throws -> Bool { false }
        func foregroundAppID() async throws -> String? { nil }
        func terminate() async throws {}
        func snapshot() async throws -> SnapshotResponse {
            SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 0, height: 0),
                             elements: [], truncatedCount: 0)
        }
        func tap(ref: Int) async throws {}
        func tap(x: Double, y: Double) async throws {}
        func type(ref: Int?, text: String) async throws {}
        func press(ref: Int, duration: Double) async throws {}
        func swipe(_ direction: FTSwipeDirection) async throws {}
        func swipe(_ direction: FTSwipeDirection, intent: FTSwipeIntent,
                   path: FTSwipePath?) async throws {}
    }

    private func worker(_ serial: String) -> RunWorker {
        RunWorker(label: serial, platform: "android", driver: NullDriver(),
                  connection: DriverConnection(platform: "android", port: 8200, serial: serial))
    }

    private func prepared(drawing: Bool) async throws -> (ScreenRenderingRecoverer.PreRun, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("screen-prerun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DeviceScreenStateStore.publish(stateDir: dir, key: "emulator-1", state: .textless)
        ScreenRecoveryLedger.markFired(stateDir: dir, key: "emulator-1")
        UnrecoveredDeviceStore.publish(stateDir: dir, key: "emulator-1", name: "E1")
        let result = await ScreenRenderingRecoverer.prepareBeforeRun(
            [worker("emulator-1"), worker("emulator-2")], stateDir: dir, locale: "en", repoRoot: dir,
            recoverIOS: { _, _, _ in nil }, isStopped: { false }, bootTime: Date(timeIntervalSince1970: 0),
            drawing: { _ in drawing }, log: { _ in })
        return (result, dir)
    }

    func testAFiredDeviceThatIsDrawingStaysInTheRunAndLosesItsMarks() async throws {
        let (result, dir) = try await prepared(drawing: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(result.workers.map(\.label), ["emulator-1", "emulator-2"])
        XCTAssertTrue(result.excludedWorkers.isEmpty)
        XCTAssertNil(DeviceScreenStateStore.current(stateDir: dir, key: "emulator-1"))
        // 案内は緑の確かめ(シナリオの成功)まで残す。絵が一様でないことは文字が描けている根拠にならない
        XCTAssertEqual(UnrecoveredDeviceStore.list(stateDir: dir, bootTime: nil).map(\.key), ["emulator-1"])
    }

    func testAFiredDeviceStillBlankIsExcludedWithoutFiringAgain() async throws {
        let (result, dir) = try await prepared(drawing: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(result.excludedWorkers.map(\.label), ["emulator-1"])
        XCTAssertEqual(UnrecoveredDeviceStore.list(stateDir: dir, bootTime: nil).map(\.key), ["emulator-1"])
    }

    /// `begin` の二重で「撃った後」に化け、1度も撃たずに除外された形の回帰
    func testADeviceNotYetRestartedIsRestartedOnce() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("screen-prerun-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DeviceScreenStateStore.publish(stateDir: dir, key: "emulator-1", state: .blank)
        let fired = LockedValue(0)
        let result = await ScreenRenderingRecoverer.prepareBeforeRun(
            [worker("emulator-1"), worker("emulator-2")], stateDir: dir, locale: "en", repoRoot: dir,
            recoverIOS: { _, _, _ in nil }, isStopped: { false }, bootTime: Date(timeIntervalSince1970: 0), drawing: { _ in true },
            repairAndroid: { _, _ in fired.withLock { $0 += 1 }; return .deviceRestart }, log: { _ in })
        XCTAssertEqual(fired.withLock { $0 }, 1)
        XCTAssertEqual(result.repairedWorkers.map(\.label), ["emulator-1"])
        XCTAssertTrue(result.excludedWorkers.isEmpty)
        XCTAssertTrue(UnrecoveredDeviceStore.list(stateDir: dir, bootTime: nil).isEmpty)
        // 何で直したかが記録に残る(sleep/wake で済んだのに再起動と読まれない)
        XCTAssertEqual(result.anomalies.map(\.kind), ["preRunRepaired"])
        XCTAssertEqual(result.anomalies.first?.recovery, "deviceRestart")
    }

    /// 中断後は撃たない・台帳も残さない(撃っていないのに「撃った」になると、以降マシンの再起動まで回復されない)
    func testAnInterruptionBeforeFiringLeavesNoLedgerAndFiresNothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("screen-prerun-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DeviceScreenStateStore.publish(stateDir: dir, key: "emulator-1", state: .blank)
        DeviceScreenStateStore.publish(stateDir: dir, key: "emulator-2", state: .blank)
        // 1台目の begin の後に中断が届く = 2台目は begin もしない・1台目は撃たずに台帳を戻す
        let calls = LockedValue(0)
        let fired = LockedValue(0)
        let result = await ScreenRenderingRecoverer.prepareBeforeRun(
            [worker("emulator-1"), worker("emulator-2")], stateDir: dir, locale: "en", repoRoot: dir,
            recoverIOS: { _, _, _ in nil },
            isStopped: { calls.withLock { $0 += 1; return $0 > 1 } },
            bootTime: Date(timeIntervalSince1970: 0), drawing: { _ in true },
            repairAndroid: { _, _ in fired.withLock { $0 += 1 }; return .deviceRestart }, log: { _ in })
        XCTAssertEqual(fired.withLock { $0 }, 0)
        XCTAssertNil(ScreenRecoveryLedger.firedAt(stateDir: dir, key: "emulator-1"))
        XCTAssertNil(ScreenRecoveryLedger.firedAt(stateDir: dir, key: "emulator-2"))
        XCTAssertTrue(result.repairedWorkers.isEmpty)
    }

    func testIOSInterruptionBeforeTheRestartRestoresTheLedger() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("screen-prerun-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DeviceScreenStateStore.publish(stateDir: dir, key: "U1", state: .blank)
        let calls = LockedValue(0)
        let recovered = LockedValue(0)
        _ = await ScreenRenderingRecoverer.prepareBeforeRun(
            [iosWorker("U1")], stateDir: dir, locale: "en", repoRoot: dir,
            recoverIOS: { _, _, _ in recovered.withLock { $0 += 1 }; return nil },
            isStopped: { calls.withLock { $0 += 1; return $0 > 1 } },
            bootTime: Date(timeIntervalSince1970: 0), drawing: { _ in true }, log: { _ in })
        XCTAssertEqual(recovered.withLock { $0 }, 0)
        XCTAssertNil(ScreenRecoveryLedger.firedAt(stateDir: dir, key: "U1"))
    }

    /// 消えたデバイスを「回復済み」と記録しない・マシンの再起動を勧めない(消えた事実だけを残す)
    func testADeviceThatDisappearedIsNotRecordedAsRecoveredOrAdvised() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("screen-prerun-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DeviceScreenStateStore.publish(stateDir: dir, key: "emulator-1", state: .textless)
        let result = await ScreenRenderingRecoverer.prepareBeforeRun(
            [worker("emulator-1"), worker("emulator-2")], stateDir: dir, locale: "en", repoRoot: dir,
            recoverIOS: { _, _, _ in nil }, isStopped: { false }, bootTime: Date(timeIntervalSince1970: 0),
            drawing: { _ in true }, deviceGone: { $0.label == "emulator-1" },
            repairAndroid: { _, _ in nil }, log: { _ in })
        XCTAssertEqual(result.workers.map(\.label), ["emulator-2"])
        XCTAssertTrue(result.repairedWorkers.isEmpty)
        XCTAssertTrue(UnrecoveredDeviceStore.list(stateDir: dir, bootTime: nil).isEmpty)
        XCTAssertEqual(result.anomalies.map(\.kind), ["preRunExcluded"])
        XCTAssertEqual(result.anomalies.first?.cause, "deviceGone")
        XCTAssertNil(ScreenRecoveryLedger.firedAt(stateDir: dir, key: "emulator-1"))
    }

    func testTextlessSkipsTheSleepWakeThatCannotBeMeasured() {
        XCTAssertFalse(ScreenRenderingRecoverer.sleepWakeMeasurable(.textless))
        XCTAssertTrue(ScreenRenderingRecoverer.sleepWakeMeasurable(.blank))
    }

    private func iosWorker(_ udid: String) -> RunWorker {
        RunWorker(label: udid, platform: "ios", driver: NullDriver(),
                  connection: DriverConnection(platform: "ios", port: 8123, udid: udid))
    }

    /// 回復は全台を作り直す。点検が除外した台を run へ戻さない・撃った種類を事実どおり残す・何も撃てなければ台帳を戻す
    func testIOSRecoveryKeepsTheSurvivorsAndNamesTheStepThatFired() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("screen-prerun-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DeviceScreenStateStore.publish(stateDir: dir, key: "U1", state: .blank)
        let all = [iosWorker("U1"), iosWorker("U2"), iosWorker("EXCLUDED")]
        let result = await ScreenRenderingRecoverer.prepareBeforeRun(
            Array(all.prefix(2)), stateDir: dir, locale: "en", repoRoot: dir,
            recoverIOS: { _, _, restored in restored("U1"); return all }, isStopped: { false },
            bootTime: Date(timeIntervalSince1970: 0), drawing: { _ in true }, log: { _ in })
        XCTAssertEqual(result.workers.map(\.label), ["U1", "U2"])
        XCTAssertEqual(result.anomalies.map(\.kind), ["preRunRepaired"])

        DeviceScreenStateStore.publish(stateDir: dir, key: "U2", state: .blank)
        let failed = await ScreenRenderingRecoverer.prepareBeforeRun(
            Array(all.prefix(2)), stateDir: dir, locale: "en", repoRoot: dir,
            recoverIOS: { _, _, _ in nil }, isStopped: { false }, bootTime: Date(timeIntervalSince1970: 0),
            drawing: { _ in true }, log: { _ in })
        XCTAssertTrue(failed.excludedWorkers.isEmpty)
        XCTAssertNil(ScreenRecoveryLedger.firedAt(stateDir: dir, key: "U2"), "撃てなかった回は台帳に残さない")
    }

    func testRestartSlotsCapConcurrency() async {
        let slots = ScreenRenderingRecoverer.RestartSlots(limit: 2)
        let peak = LockedValue(0)
        let current = LockedValue(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    await slots.acquire()
                    let now = current.withLock { $0 += 1; return $0 }
                    peak.withLock { $0 = Swift.max($0, now) }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    current.withLock { $0 -= 1 }
                    await slots.release()
                }
            }
        }
        XCTAssertEqual(peak.withLock { $0 }, 2)
    }
}
