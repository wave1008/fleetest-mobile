// api run の機械分担の「手元のデバイスの使用中の待ち」を NDJSON に出す(`localDevicesWaiting`)。
// dispatchWaiting(dispatch.lock の待機列)とは別のイベント。
import XCTest
@testable import FTCore
import FTBridgeClient
@testable import fleetest

final class LocalDevicesWaitingEventTests: XCTestCase {
    private var tempDir: URL!
    private var project: TestProject!
    private var stateDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LocalDevicesWaiting-\(UUID().uuidString)")
        project = TestProject(name: "P", rootURL: tempDir.appendingPathComponent("TestProjects/P"))
        stateDir = tempDir.appendingPathComponent(".fleetest")
        for dir in [project.appsDir, project.runsDir, stateDir!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try """
        { "ios": { "appName": "App", "app": "com.example.app" } }
        """.write(to: project.appsDir.appendingPathComponent("app.json"), atomically: true, encoding: .utf8)
        try """
        { "app": "app",
          "devices": [ { "platform": "ios", "machine": "local", "name": "A", "kind": "physical", "udid": "UA" } ] }
        """.write(to: project.runsDir.appendingPathComponent("fleet.json"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// 1行の形: 専用の kind・経過・上限(上限が無ければキーごと省く)
    func testEventLineShape() throws {
        let lines = LockedValue<[String]>([])
        ApiLocalDevicesWaitingEvent.emit(elapsedSeconds: 60, limitSeconds: 900) { line in lines.withLock { $0.append(line) } }
        ApiLocalDevicesWaitingEvent.emit(elapsedSeconds: 0, limitSeconds: nil) { line in lines.withLock { $0.append(line) } }
        XCTAssertEqual(lines.value, [
            #"{"elapsedSeconds":60,"kind":"localDevicesWaiting","limitSeconds":900}"#,
            #"{"elapsedSeconds":0,"kind":"localDevicesWaiting"}"#,
        ])
    }

    /// 待ちの進行ログと同じ刻み(初回 + 60 秒ごと)で、同じ if から出る。空いたら終わりのイベントは出さない
    func testEmitsAtTheSameCadenceAsTheProgressLog() throws {
        RunLease.write(stateDir: stateDir, key: "UA", pid: 1)
        let emitted = LockedValue<[[Int?]]>([])
        let logged = LockedValue(0)
        let sleeps = LockedValue(0)
        try ProfileRunner.rejectIfLocalDevicesLeasedBeforeDispatch(
            project: project, profileName: "fleet", setOverrides: [:],
            localDeviceNames: ["A"], localScenarios: [ScenarioInfo(id: "C.S0", title: "t")],
            broadcast: false, waitLock: 300, interruptCheck: { false }, leaseStateDir: stateDir,
            log: { _ in logged.withLock { $0 += 1 } },
            emitWaiting: { elapsed, limit in emitted.withLock { $0.append([elapsed, limit]) } },
            sleepSeconds: { [stateDir] _ in
                if sleeps.withLock({ $0 += 1; return $0 }) == 7 { RunLease.remove(stateDir: stateDir!, key: "UA") }
            })
        XCTAssertEqual(emitted.value, [[0, 300], [60, 300]])
        XCTAssertEqual(logged.value, emitted.value.count, "ログと NDJSON の刻みが食い違っている")
    }

    /// 出し口を渡さなければ何も出ない(`fleetest run` の stdout は人間向け)
    func testNoEmitterNoEvent() throws {
        RunLease.write(stateDir: stateDir, key: "UA", pid: 1)
        XCTAssertNoThrow(try ProfileRunner.rejectIfLocalDevicesLeasedBeforeDispatch(
            project: project, profileName: "fleet", setOverrides: [:],
            localDeviceNames: ["A"], localScenarios: [ScenarioInfo(id: "C.S0", title: "t")],
            broadcast: false, waitLock: 300, interruptCheck: { false }, leaseStateDir: stateDir,
            sleepSeconds: { [stateDir] _ in RunLease.remove(stateDir: stateDir!, key: "UA") }))
    }

    /// 配線: api run の機械分担だけが出し口を渡し(専用のイベントで。dispatchWaiting を流用しない)、run 側は渡さない
    func testOnlyTheApiRunFanoutWiresTheEmitter() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ name: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent("Sources/fleetest/\(name)"), encoding: .utf8)
        }
        let api = try source("ApiRunMachineFanout.swift")
        XCTAssertTrue(api.contains("emitLocalDevicesWaiting: { ApiLocalDevicesWaitingEvent.emit("))
        XCTAssertFalse(api.contains("ApiDispatchWaitingEvent"), "dispatch.lock の待機のイベントを流用している")
        for name in ["DeviceMachineRunner.swift", "MultiTargetRunner.swift"] {
            XCTAssertTrue(try source(name).contains("emitLocalDevicesWaiting: nil"),
                          "\(name) が人間向けの stdout に NDJSON を混ぜている")
        }
        XCTAssertTrue(try source("MachineFanoutFrontHalf.swift").contains("emitWaiting: settings.emitLocalDevicesWaiting"),
                      "前段が出し口を使用中の待ちへ渡していない")
    }
}
