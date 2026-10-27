// in-app ブリッジと Android ブリッジが、要求の `expect`(identifier・型)を自分の ref の表と照らして
// **撃つ前に** 422 + `stale-ref` で断ることを、ソース走査で固定する(Swift/Java の本体は単体テストで動かせない)。
// 判定そのものは `StaleRefGuardTests`、XCUITest ランナー側は `BridgeRouterStatusContractTests` の隣の経路。
// 「撃つ前」の根拠: 断りが先なら何も届いていないので、ホストが木を撮り直して引き直してよい(CLAUDE.md の撃ち直し規律)。

import XCTest
@testable import FTCore

final class BridgeStaleRefExpectWiringTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// `func <name>` から次の `\n    private func ` / `\n    func ` までの本体
    private func swiftBody(_ name: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: "func \(name)("), "\(name) が見つからない")
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func ") ?? rest.range(of: "\n    func ")
        return String(end.map { rest[..<$0.lowerBound] } ?? rest)
    }

    private func javaBody(_ signature: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: signature), "\(signature) が見つからない")
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private ") ?? rest.range(of: "\n    static ")
        return String(end.map { rest[..<$0.lowerBound] } ?? rest)
    }

    // MARK: in-app

    /// 4つの要求のうち in-app が撃つ3つ(`/press` は常に 501 で何も撃たない)は、**撃つ操作より前に**照合する
    func testInAppHandlersRefuseBeforeFiring() throws {
        let source = try read("InAppBridge/Sources/InAppBridge.swift")
        let firing = ["tapByRef(", "performWithSettle", "FTSynthTap"]
        for name in ["handleTap", "handleType", "handleClear"] {
            let body = try swiftBody(name, in: source)
            let check = try XCTUnwrap(body.range(of: "try requireExpectedRef(ref, expect: req.expect)"),
                                      "\(name) が expect を照合していない")
            let firstFire = firing.compactMap { body.range(of: $0)?.lowerBound }.min()
            let fire = try XCTUnwrap(firstFire, "\(name) に撃つ操作が見つからない(走査の前提が崩れた)")
            XCTAssertLessThan(check.lowerBound, fire, "\(name): 照合は撃つ操作より前に置くこと")
        }
    }

    func testInAppRefusalIsStructured422() throws {
        let source = try read("InAppBridge/Sources/InAppBridge.swift")
        let body = try swiftBody("requireExpectedRef", in: source)
        XCTAssertTrue(body.contains("StaleRefGuard.contradicts(expect, stored: stored)"), "判定は共有の StaleRefGuard")
        XCTAssertTrue(body.contains("InAppError(422,") && body.contains("reason: BridgeAPI.staleRefReason"),
                      "断りは 422 + BridgeAPI.staleRefReason")
        XCTAssertTrue(source.contains("return .error(e.message, status: e.status, reason: e.reason)"),
                      "InAppError.reason が応答の reason に載らない(ホストは reason で分岐する)")
        XCTAssertTrue(source.contains("self.refElements = Dictionary("),
                      "照合先の表が /snapshot のたびに差し替わらない")
    }

    // MARK: Android

    /// ref の解決は `centerOf(ref, body)` を通ること(/tap・/press は resolvePoint 経由、/type・/clear は直接)。
    /// どれも注入より前
    func testAndroidHandlersResolveRefThroughTheExpectationCheck() throws {
        let source = try read("AndroidRunner/src/com/example/ftbridge/BridgeRouter.java")
        let resolve = try javaBody("private double[] resolvePoint(JSONObject body) {", in: source)
        XCTAssertTrue(resolve.contains("centerOf(body.optInt(\"ref\"), body)"), "resolvePoint が expect を照合していない")
        for (signature, fire) in [
            ("private BridgeHttpServer.Response handleTap(JSONObject body) {", "InputInjector.tap("),
            ("private BridgeHttpServer.Response handlePress(JSONObject body) {", "InputInjector.press("),
        ] {
            let body = try javaBody(signature, in: source)
            let resolveAt = try XCTUnwrap(body.range(of: "resolvePoint(body)"), "\(signature) が resolvePoint を通らない")
            let fireAt = try XCTUnwrap(body.range(of: fire))
            XCTAssertLessThan(resolveAt.lowerBound, fireAt.lowerBound, "\(signature): 解決(照合)は注入より前")
        }
        for (signature, fire) in [
            ("private BridgeHttpServer.Response handleType(JSONObject body) {", "tapUnlessAlreadyFocused("),
            ("private BridgeHttpServer.Response handleClear(JSONObject body) {", "tapUnlessAlreadyFocused("),
        ] {
            let body = try javaBody(signature, in: source)
            let resolveAt = try XCTUnwrap(body.range(of: "centerOf(ref, body)"), "\(signature) が expect を照合していない")
            let fireAt = try XCTUnwrap(body.range(of: fire))
            XCTAssertLessThan(resolveAt.lowerBound, fireAt.lowerBound, "\(signature): 照合は最初のタップより前")
        }
    }

    func testAndroidRefusalIsStructured422() throws {
        let source = try read("AndroidRunner/src/com/example/ftbridge/BridgeRouter.java")
        let centered = try javaBody("private double[] centerOf(int ref, JSONObject body) {", in: source)
        XCTAssertTrue(centered.contains("requireExpectedRef(ref, body.optJSONObject(\"expect\"))"))
        let check = try javaBody("private void requireExpectedRef(int ref, JSONObject expect) {", in: source)
        XCTAssertTrue(check.contains("new BridgeException(422,") && check.contains("STALE_REF_REASON"),
                      "断りは 422 + STALE_REF_REASON")
        XCTAssertTrue(source.contains("static final String STALE_REF_REASON = \"\(BridgeAPI.staleRefReason)\";"),
                      "Java の reason が BridgeAPI.staleRefReason と食い違っている")
        XCTAssertTrue(source.contains("Response.error(e.status, e.getMessage(), e.reason)"),
                      "BridgeException.reason が応答の reason に載らない")
        let server = try read("AndroidRunner/src/com/example/ftbridge/BridgeHttpServer.java")
        XCTAssertTrue(server.contains("o.put(\"reason\", reason)"), "エラー JSON に reason を書いていない")
        let snapshot = try read("AndroidRunner/src/com/example/ftbridge/SnapshotBuilder.java")
        XCTAssertTrue(snapshot.contains("types.put(ref, mappedType(node))"), "照合先の型の表が作られていない")
    }
}
