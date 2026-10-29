import XCTest
@testable import FTCore

/// iOS の hideKeyboard でキーボードが出ていなかったときは、何も撃たずに注記なしで通し、型付きの印(`hideKeyboardFoundNoKeyboard`)だけを立てる
/// (MCP の ft_hide_keyboard はこの印で「送った」と言わずに済ませる。文言の一致で見分けない)
final class HideKeyboardNotShownNoteTests: XCTestCase {
    private let screen = FTRect(x: 0, y: 0, width: 402, height: 874)

    func testNotShownPassesSilentlyAndSendsNothing() async {
        let elements = [ElementInfo(ref: 1, type: "scrollView", identifier: nil, label: nil, value: nil, placeholder: nil,
                                    enabled: true, frame: screen, depth: 0)]
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [elements])
        driver.keyboardFrames = [nil]
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        let outcome = await executor.execute(FlowStep(action: "hideKeyboard"))
        guard case .passed = outcome.status else { return XCTFail("\(outcome.status)") }
        XCTAssertNil(outcome.driverFallback, "冪等の無操作にレポートの注記を付けた")
        XCTAssertTrue(executor.hideKeyboardFoundNoKeyboard)
        XCTAssertTrue(driver.coordinateTaps.isEmpty, "出ていないのに叩いた")
    }

    /// Android の経路も入口で印を戻す(ドライバが投げた回に、前のステップの「送らなかった」を残さない)
    func testAndroidFlagDoesNotCarryOverToAFailedStep() async {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[]])
        let executor = StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())
        driver.keyboardShownForHide = false
        _ = await executor.execute(FlowStep(action: "hideKeyboard"))
        XCTAssertTrue(executor.hideKeyboardFoundNoKeyboard)
        driver.hideKeyboardError = DriverError.badResponse(status: 500, body: "dumpsys failed")
        _ = await executor.execute(FlowStep(action: "hideKeyboard"))
        XCTAssertFalse(executor.hideKeyboardFoundNoKeyboard, "失敗したステップに前の「送らなかった」が残った")
    }

    /// Android で何も送らなかった回も、次の操作に「木からキーボードが消えるのを待つ」を立てる
    func testAndroidNoOpStillArmsTheKeyboardWait() async {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[]])
        let executor = StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())
        driver.keyboardShownForHide = false
        _ = await executor.execute(FlowStep(action: "hideKeyboard"))
        XCTAssertNotNil(executor.pendingHideKeyboardWait, "dumpsys が閉じたと答えても木は数秒キーボードを残す(Pixel 3a の実測)")
    }

    /// 印はステップの入口で毎回戻す(hideKeyboard の処理へ届かないステップにも前の値を残さない = MCP の ft_batch が読む)
    func testFlagIsClearedByAnyFollowingStep() async {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[]])
        let executor = StepExecutor(driver: driver, isAndroid: true, tunables: RunTunables())
        driver.keyboardShownForHide = false
        _ = await executor.execute(FlowStep(action: "hideKeyboard"))
        XCTAssertTrue(executor.hideKeyboardFoundNoKeyboard)
        _ = await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "missing"), timeout: 0))
        XCTAssertFalse(executor.hideKeyboardFoundNoKeyboard, "hideKeyboard 以外のステップの後に前の値が残った")
    }
}
