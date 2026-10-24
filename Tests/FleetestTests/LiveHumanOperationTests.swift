import XCTest
import FTBridgeClient
import FTCore
@testable import fleetest

/// run 中の人のライブ操作を台帳へ残す純粋な部分(label・書く条件)と serve の配線
final class LiveHumanOperationTests: XCTestCase {
    private func label(_ raw: [String: Any], name: String? = nil) -> String? {
        let cmd = raw["cmd"] as? String ?? ""
        return LiveHumanOperation.label(for: ApiLiveServeCommand(cmd: cmd, raw: raw), elementName: name)
    }

    func testCoordinateAndRefLabels() {
        XCTAssertEqual(label(["cmd": "tap", "x": 120.4, "y": 340.6]), "tap (120, 341)")
        XCTAssertEqual(label(["cmd": "tap", "ref": 12]), "tap ref 12")
        XCTAssertEqual(label(["cmd": "tap", "ref": 12], name: "Login"), "tap \"Login\"")
        XCTAssertEqual(label(["cmd": "doubleTap", "x": 1, "y": 2]), "double tap (1, 2)")
        XCTAssertEqual(label(["cmd": "press", "x": 5, "y": 6, "duration": 0.8]), "long press (5, 6) 0.8s")
        XCTAssertEqual(label(["cmd": "swipe", "direction": "up"]), "swipe up")
        XCTAssertEqual(label(["cmd": "drag", "fromX": 1, "fromY": 2, "toX": 3, "toY": 4]), "drag (1, 2) → (3, 4)")
        XCTAssertEqual(label(["cmd": "pinch", "scale": 1.5]), "pinch ×1.5")
        XCTAssertEqual(label(["cmd": "clear"]), "clear")
    }

    func testSimpleAndAppLabels() {
        XCTAssertEqual(label(["cmd": "hideKeyboard"]), "hide keyboard")
        XCTAssertEqual(label(["cmd": "home"]), "home")
        XCTAssertEqual(label(["cmd": "back"]), "back")
        XCTAssertEqual(label(["cmd": "appSwitcher"]), "app switcher")
        XCTAssertEqual(label(["cmd": "launch", "bundle": "com.example.app"]), "launch com.example.app")
        XCTAssertEqual(label(["cmd": "activate", "bundle": "com.example.app"]), "activate com.example.app")
        XCTAssertEqual(label(["cmd": "terminate"]), "terminate")
        XCTAssertEqual(label(["cmd": "clearAppData", "bundle": "com.example.app"]), "clear app data com.example.app")
        XCTAssertEqual(label(["cmd": "fold", "state": "fold"]), "fold")
        XCTAssertEqual(label(["cmd": "fold", "state": "unfold"]), "unfold")
        XCTAssertEqual(label(["cmd": "install", "path": "/Users/me/secret dir/App.app"]), "install App.app",
                       "ファイル名だけ(ディレクトリは残さない)")
    }

    /// 入力した文字列(OTP・パスワード)は label のどこにも入らない
    func testTypeKeepsOnlyTheCharacterCount() throws {
        let typed = try XCTUnwrap(label(["cmd": "type", "text": "s3cret-OTP"]))
        XCTAssertEqual(typed, "type (10 characters)")
        XCTAssertFalse(typed.contains("s3cret"))
        XCTAssertEqual(label(["cmd": "type", "text": "x"]), "type (1 character)")
        let withRef = try XCTUnwrap(label(["cmd": "type", "ref": 3, "text": "s3cret-OTP"], name: "Password"))
        XCTAssertFalse(withRef.contains("s3cret"))
    }

    func testObservationCommandsAndUnknownOnesAreNotRecorded() {
        XCTAssertNil(label(["cmd": "refresh"]))
        XCTAssertNil(label(["cmd": "frame"]))
        XCTAssertNil(label(["cmd": "no-such-command"]))
    }

    func testGestureLabelCountsFingers() {
        let finger: [String: Any] = ["points": [["x": 1, "y": 2, "t": 0], ["x": 3, "y": 4, "t": 0.1]]]
        XCTAssertEqual(label(["cmd": "gesture", "fingers": [finger, finger]]), "gesture (2 fingers)")
    }

    func testNamesUseLabelThenIdentifierAndNeverValue() {
        func element(_ ref: Int, label: String?, identifier: String?, value: String?) -> ElementInfo {
            ElementInfo(ref: ref, type: "staticText", identifier: identifier, label: label, value: value,
                        placeholder: nil, enabled: true, frame: FTRect(x: 0, y: 0, width: 1, height: 1), depth: 0)
        }
        let elements = [
            element(1, label: "Login", identifier: "btn", value: nil),
            element(2, label: nil, identifier: "otp", value: "123456"),
            element(3, label: "  ", identifier: nil, value: "x"),
            element(4, label: String(repeating: "あ", count: 100), identifier: nil, value: nil),
        ]
        let names = LiveHumanOperation.names(from: elements)
        XCTAssertEqual(names[1], "Login")
        XCTAssertEqual(names[2], "otp")
        XCTAssertNil(names[3])
        XCTAssertEqual(names[4]?.count, LiveHumanOperation.maxElementNameCharacters)
    }

    /// run が使用中(自分以外の生きた持ち主)のときだけ書く
    func testShouldRecordOnlyWhileAnotherProcessHoldsTheRunLease() {
        XCTAssertFalse(LiveHumanOperation.shouldRecord(runHolderPID: nil, ownPID: 10))
        XCTAssertTrue(LiveHumanOperation.shouldRecord(runHolderPID: 11, ownPID: 10))
        XCTAssertFalse(LiveHumanOperation.shouldRecord(runHolderPID: 10, ownPID: 10))
    }

    /// 実際の run-lease(launchd の pid は必ず生きている)を立てた/立てないときの serve 側の判定と書き込み
    func testLeaseRecordsOnlyWhileRunLeaseIsFresh() throws {
        let stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ft-live-human-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let lease = LiveDeviceLease(stateDir: stateDir, key: "UDID-RUN", pid: ProcessInfo.processInfo.processIdentifier,
                                    log: { _ in })
        XCTAssertFalse(lease.runIsUsingDevice(), "run-lease が無い = 普段のライブ操作")
        RunLease.write(stateDir: stateDir, key: "UDID-RUN", pid: 1)
        XCTAssertTrue(lease.runIsUsingDevice())
        let at = Date()
        lease.recordHumanOperation(label: "home", ok: true, at: at)
        let rows = HumanOperationLedger.entries(stateDir: stateDir, key: "UDID-RUN",
                                                from: at.addingTimeInterval(-1), to: at.addingTimeInterval(1))
        XCTAssertEqual(rows.map(\.label), ["home"])
    }

    // MARK: - 配線

    private func serveSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/ApiLiveCommand.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// handle は操作を撃つ前に label を作り(要素名は撃つ前の表から)、成功と失敗の両方で書く。書く条件は run の使用中
    func testHandleRecordsBothOutcomesGatedOnRunUsage() throws {
        let code = try serveSource()
        XCTAssertTrue(code.contains("deviceLease?.runIsUsingDevice() == true"))
        XCTAssertTrue(code.contains("command.drivesDevice, deviceLease?.runIsUsingDevice()"))
        XCTAssertTrue(code.contains("recordHumanOperation(label: humanLabel, ok: true, at: operatedAt)"))
        XCTAssertTrue(code.contains("recordHumanOperation(label: humanLabel, ok: false, at: operatedAt)"))
        let labelAt = try XCTUnwrap(code.range(of: "LiveHumanOperation.label(for: command"))
        let performAt = try XCTUnwrap(code.range(of: "try await perform(command: command"))
        XCTAssertLessThan(labelAt.lowerBound, performAt.lowerBound, "label(要素名)は操作の前に作る")
        XCTAssertTrue(code.contains("screenMemo.noteNames(LiveHumanOperation.names(from: snap.elements))"))
    }
}
