// clearInput(ロケータ付き)は type と同じく、キーボードの下の欄を reachPastKeyboard の前に容器を送って届かせる(inapp F8)。
// 走査の固定: clearInput の case に liftCoveredTarget(verb: "clearing")が在り、reachPastKeyboard より前にあること。

import XCTest

final class ClearInputLiftsCoveredTargetTests: XCTestCase {

    func testClearInputCaseLiftsBeforeReachingPastTheKeyboard() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FTCore/StepExecutor+Actions.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let caseStart = try XCTUnwrap(source.range(of: "case \"clearInput\":\n            if let refusal = nonTextInputPreflightRefusal"))
        let body = String(source[caseStart.upperBound...].prefix(2500))
        let lift = try XCTUnwrap(body.range(of: "liftCoveredTarget(", options: []), "clearInput が容器を送っていない")
        XCTAssertTrue(body.contains("verb: \"clearing\""))
        let reach = try XCTUnwrap(body.range(of: "reachPastKeyboard("))
        XCTAssertLessThan(lift.lowerBound, reach.lowerBound, "送ってから閉じる順(type と同じ)")
    }
}
