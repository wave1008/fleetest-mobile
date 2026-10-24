import XCTest
@testable import fleetest

/// モニターの絵(monitorFrame)とライブ操作の観測(snapshot)の `capturedAtMs` —— 拡張のグリッドビューは、観測の一枚絵より
/// 前に撮られたポーリングの絵を捨てる(古い絵に戻らない)。**時刻は撮り始める前に採る**(後に採ると、観測より前に撮った
/// ポーリングの絵が「後」に見えて残る)。同期相手: vscode-fleetest/src/monitorDeviceModel.ts・liveModel.ts
final class CaptureTimestampWiringTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testMonitorFrameCarriesTheCaptureTime() throws {
        let event = ApiMonitorFrameEvent(device: "ios:A", jpegBase64: "AA==", width: 1, height: 1, capturedAtMs: 42)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(event), encoding: .utf8))
        XCTAssertTrue(json.contains("\"capturedAtMs\":42"), json)
    }

    func testMonitorTakesTheTimeBeforeFetchingScreenshots() throws {
        let code = try source("Sources/fleetest/ApiMonitorCommand.swift")
        let stamp = try XCTUnwrap(code.range(of: "let captureStartedAt = Date()"))
        let fetch = try XCTUnwrap(code.range(of: "await Self.fetchScreenshots(captureStates"))
        XCTAssertLessThan(stamp.lowerBound, fetch.lowerBound, "撮り始める前に時刻を採る")
        XCTAssertTrue(code.contains("capturedAtMs: Int64(captureStartedAt.timeIntervalSince1970 * 1000)"))
    }

    func testLiveObservationTakesTheTimeBeforeTheScreenshot() throws {
        let code = try source("Sources/fleetest/ApiLiveCommand.swift")
        let start = try XCTUnwrap(code.range(of: "private func emitObservation("))
        let body = code[start.upperBound...]
        let stamp = try XCTUnwrap(body.range(of: "let capturedAt = Date()"))
        let shot = try XCTUnwrap(body.range(of: "try await driver.screenshot()"))
        XCTAssertLessThan(stamp.lowerBound, shot.lowerBound, "撮り始める前に時刻を採る")
        XCTAssertTrue(body.contains("capturedAtMs: Int64(capturedAt.timeIntervalSince1970 * 1000)"), "成功の観測に時刻を載せる")
        XCTAssertTrue(body.contains("capturedAtMs: nil"), "失敗の観測は null(欄は常に出す)")
    }
}
