import XCTest
@testable import FTAndroid
import FTCore

/// フォーカス不在以外の失敗(ロック画面の下の SET_TEXT 拒否・アプリが落ちた後の読み返し失敗)でも前面を言う。
/// 長押し・ドラッグの adb 切断(終了コード 255)は「届いたか分からない」
final class TypeFailureFrontAdviceTests: XCTestCase {
    func testNonFocusFailureNamesShadeAndMissingApp() {
        let error = DriverError.badResponse(status: 500, body: "this field does not accept ACTION_SET_TEXT")
        guard case .badResponse(_, let shade)? = AndroidDriver.noFocusFrontAdvice(
            after: error, front: "com.android.systemui", lastTreePackage: "com.app") else { return XCTFail() }
        XCTAssertTrue(shade.contains("holds the input focus"), shade)
        guard case .badResponse(_, let gone)? = AndroidDriver.noFocusFrontAdvice(
            after: error, front: "com.launcher", lastTreePackage: "com.app") else { return XCTFail() }
        XCTAssertTrue(gone.contains("com.launcher is in front, not com.app"), gone)
        XCTAssertNil(AndroidDriver.noFocusFrontAdvice(after: error, front: "com.app", lastTreePackage: "com.app"))
    }

    func testAdbExit255IsDeliveryUnknownOthersStayFailures() {
        let context = DriverErrorContext(bridge: .android, physicalDevice: false)
        let cut = AndroidDriver.shellInputCutOff(Shell.Result(status: 255, output: "closed"), verb: "long-press", context: context)
        guard case .bridgeUnreachable? = cut else { return XCTFail("\(String(describing: cut))") }
        XCTAssertNil(AndroidDriver.shellInputCutOff(Shell.Result(status: 1, output: "device not found"),
                                                    verb: "long-press", context: context))
    }
}
