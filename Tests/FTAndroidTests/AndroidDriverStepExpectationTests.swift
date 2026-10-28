// ステップ実行器の期待(RefExpectationScope)が AndroidDriver の最新の ref の表(重複の除去・DOM の差し込みの後)と食い違えば、
// adb もブリッジも呼ばずに staleRef で断ることの固定。tap / press はホストが座標へ直して撃つので、ブリッジの expect は届かない。

import FTCore
import XCTest
@testable import FTAndroid

final class AndroidDriverStepExpectationTests: XCTestCase {
    private var dir: URL!
    private var serial: String!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ft-expect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        serial = "fake-\(UUID().uuidString.prefix(8))"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-android-\(serial!).json"))
    }

    /// 呼び出しを1行ずつ記録し、すべて失敗する adb
    private func driver() throws -> (AndroidDriver, URL) {
        let log = dir.appendingPathComponent("calls.log")
        let url = dir.appendingPathComponent("adb")
        try "#!/bin/sh\necho \"$*\" >> '\(log.path)'\nexit 1\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let driver = AndroidDriver(serial: serial, adbPath: url.path)
        let element = ElementInfo(ref: 1, type: "button", identifier: "send", label: "Send", value: nil,
                                  placeholder: nil, enabled: true,
                                  frame: FTRect(x: 10, y: 20, width: 100, height: 44), depth: 1)
        driver.syncLocalState(from: SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 1080, height: 2400),
                                                     elements: [element], truncatedCount: 0))
        return (driver, log)
    }

    private func calls(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func isStaleRef(_ error: Error) -> Bool {
        if case DriverError.staleRef? = error as? DriverError { return true }
        return false
    }

    func testContradictingExpectationIsRefusedWithoutTouchingTheDevice() async throws {
        let (driver, log) = try driver()
        let wrong = RefExpectation(identifier: "cancel", type: "button")
        let operations: [(String, () async throws -> Void)] = [
            ("tap", { try await driver.tap(ref: 1) }),
            ("press", { try await driver.press(ref: 1, duration: 0.5) }),
            ("type", { try await driver.type(ref: 1, text: "x") }),
            ("clear", { try await driver.clearInput(ref: 1) }),
        ]
        for (name, operation) in operations {
            do {
                try await RefExpectationScope.$expected.withValue(wrong) { try await operation() }
                XCTFail("\(name): 食い違う期待なのに断らなかった")
            } catch {
                XCTAssertTrue(isStaleRef(error), "\(name): staleRef になっていない: \(error)")
            }
        }
        XCTAssertEqual(calls(log), [], "断ったのに adb を呼んだ")
    }

    /// 陽性対照: 一致する期待なら撃ちに行く(adb が失敗するので別のエラーになる)
    func testMatchingExpectationGoesOnToFire() async throws {
        let (driver, log) = try driver()
        do {
            try await RefExpectationScope.$expected.withValue(RefExpectation(identifier: "send", type: "button")) {
                try await driver.tap(ref: 1)
            }
        } catch {
            XCTAssertFalse(isStaleRef(error), "一致する期待なのに断った: \(error)")
        }
        XCTAssertFalse(calls(log).isEmpty, "撃ちに行っていない")
    }
}
