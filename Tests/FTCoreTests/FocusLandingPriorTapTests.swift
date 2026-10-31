// 直前の ref の tap が焦点を立てた欄への叩き直し(inapp F9)。実測 2026-11-01 E2EX-Flutter(in-app):
// 値入りの欄は木で `other`(入力欄と申告されない)・受け口は動かない 1x1 で、`tap(A); tap(B); type("x")` の救済が
// `FocusLanding.landed` で断られた。「動かなかった」だけで通すと容器を叩いた形が前の欄へ打つので、直前の tap が同じ id を叩いて
// その前から受け口が動いたときだけ通す。

import XCTest
@testable import FTCore

final class FocusLandingPriorTapTests: XCTestCase {

    private let receiver = CGRect(x: 16, y: 249, width: 1, height: 1)
    private let target = CGRect(x: 16, y: 248, width: 370, height: 56)

    /// 実測の形: 入力欄と申告されない・受け口は動かない 1x1 → 断られる。直前の tap の事実を足すと通る
    func testStaticReceiverOnAnUndeclaredFieldLandsOnlyWithThePriorTapFact() {
        XCTAssertFalse(FocusLanding.landed(receiver: receiver, tapped: CGPoint(x: 201, y: 276), target: target,
                                           targetIsInput: false, movedSinceTap: false, soleInnerInput: nil))
        XCTAssertTrue(FocusLanding.landed(receiver: receiver, tapped: CGPoint(x: 201, y: 276), target: target,
                                          targetIsInput: false, movedSinceTap: true, soleInnerInput: nil))
    }

    /// 実測 2026-11-01 の形: 木の包み (16,271 370x10)・救済の入れ先(中身)の枠も包みの中・受け口は箱の左上 (16,249)(木の枠の外)
    private let wrapperNow = CGRect(x: 16, y: 271, width: 370, height: 10)
    private let innerField = CGRect(x: 16, y: 271, width: 370, height: 10)

    /// 前提: 木の枠でも「動いたか」でも着地と読めない(= 実測の 409)
    func testTheMeasuredShapeIsRefusedByTheGeometryRule() {
        XCTAssertFalse(wrapperNow.contains(receiver.origin))
        XCTAssertFalse(FocusLanding.landed(receiver: receiver, tapped: CGPoint(x: 201, y: 276), target: wrapperNow,
                                           targetIsInput: false, movedSinceTap: false, soleInnerInput: nil))
    }

    func testPriorTapThatMovedTheReceiverLandsOnItsOwnTarget() {
        XCTAssertTrue(FocusLanding.priorTapLanded(receiverMovedSinceThatTap: true,
                                                  recordedTargetNow: wrapperNow, current: innerField))
    }

    /// 容器を叩いて焦点が動かなかった(その tap の前から受け口が動いていない)形は通さない
    func testReceiverThatDidNotMoveDidNotLand() {
        XCTAssertFalse(FocusLanding.priorTapLanded(receiverMovedSinceThatTap: false,
                                                   recordedTargetNow: wrapperNow, current: innerField))
    }

    /// 直前の tap の対象の外の要素(別の欄・外側の容器)は、その焦点のものではない
    func testElementOutsideThePriorTargetDidNotLand() {
        let otherField = CGRect(x: 16, y: 355, width: 370, height: 56)
        XCTAssertFalse(FocusLanding.priorTapLanded(receiverMovedSinceThatTap: true,
                                                   recordedTargetNow: wrapperNow, current: otherField))
        let container = CGRect(x: 0, y: 114, width: 402, height: 678)
        XCTAssertFalse(FocusLanding.priorTapLanded(receiverMovedSinceThatTap: true,
                                                   recordedTargetNow: wrapperNow, current: container))
    }

    func testMissingFramesDidNotLand() {
        XCTAssertFalse(FocusLanding.priorTapLanded(receiverMovedSinceThatTap: true, recordedTargetNow: nil, current: innerField))
        XCTAssertFalse(FocusLanding.priorTapLanded(receiverMovedSinceThatTap: true, recordedTargetNow: wrapperNow, current: nil))
    }

    /// in-app が型を使って決める(使わない版では判定が働かない)
    func testInAppBridgeFeedsThePriorTapFactIntoTheFocusRule() throws {
        var url = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            url.deleteLastPathComponent()
        }
        let source = try String(contentsOf: url.appendingPathComponent("InAppBridge/Sources/InAppBridge.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("FocusLanding.priorTapLanded("))
        XCTAssertTrue(source.contains("if landedByPriorTap { return nil }"))
        XCTAssertEqual(source.components(separatedBy: "landedByPriorTap = self.priorTapLanded(ref: ref)").count - 1, 2,
                       "type と clear の両方が渡すこと")
    }
}
