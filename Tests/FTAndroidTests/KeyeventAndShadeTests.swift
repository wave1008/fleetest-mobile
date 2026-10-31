// adb の keyevent の失敗は「届いたか分からない」(error: closed は終了コード 1 でも届いていた)・クイック設定が前面のときの
// hideKeyboard は畳み切るまで BACK を重ね、閉じられなければ成功と言わない・覆いが焦点を持つ ref 無しの clearInput は撃たない。

import FTCore
import XCTest
@testable import FTAndroid

final class KeyeventAndShadeTests: XCTestCase {
    private var dir: URL!
    private var serial: String!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ft-keyevent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        serial = "fake-\(UUID().uuidString.prefix(8))"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("fleetest-android-\(serial!).json"))
    }

    private func fakeADB(_ body: String) throws -> String {
        let url = dir.appendingPathComponent("adb")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func isDeliveryUnknown(_ error: Error) -> Bool {
        if case DriverError.bridgeUnreachable = error { return true }
        return false
    }

    func testKeyeventFailureIsDeliveryUnknownForEveryNonZeroExit() async throws {
        for status in [1, 255] {
            let driver = AndroidDriver(serial: serial, adbPath: try fakeADB("echo 'error: closed' >&2; exit \(status)"))
            for (name, call) in [("back", { try await driver.back() }), ("home", { try await driver.home() }),
                                 ("appSwitcher", { try await driver.openAppSwitcher() })] {
                do {
                    try await call()
                    XCTFail("\(name) exit \(status) を成功と読んだ")
                } catch {
                    XCTAssertTrue(isDeliveryUnknown(error), "\(name) exit \(status): \(error)")
                    XCTAssertFalse("\(error)".contains("failed to go back"), "断定の文言が残っている: \(error)")
                }
            }
        }
    }

    /// n 回目の BACK の後の窓の並びを script で決める。shadeUntil = シェードが見えている BACK の回数(この回数に達すると閉じる)
    /// `focusHeld: false` = 窓は可視だが入力フォーカスはアプリのまま(通知の到着)
    private func hidingADB(shadeUntil: Int, keyboardUntil: Int = 3, focusHeld: Bool = true) throws -> String {
        let count = dir.appendingPathComponent("n").path
        return try fakeADB("""
        n=$(cat '\(count)' 2>/dev/null || echo 0)
        case "$*" in
        *keyevent*) echo $((n+1)) > '\(count)'; exit 0;;
        *displays*)
          if \(focusHeld ? "true" : "false") && [ "$n" -lt \(shadeUntil) ]; then echo '  mCurrentFocus=Window{a u0 NotificationShade}'
          else echo '  mCurrentFocus=Window{c u0 com.app/com.app.Main}'; fi
          exit 0;;
        *dumpsys*)
          if [ "$n" -lt \(shadeUntil) ]; then echo '  Window #1 Window{a u0 NotificationShade}:'; echo '    isVisible=true'; fi
          if [ "$n" -lt \(keyboardUntil) ]; then echo '  Window #2 Window{b u0 InputMethod}:'; echo '    isVisible=true'; fi
          exit 0;;
        *) exit 1;;
        esac
        """)
    }

    private func backs() -> Int { Int((try? String(contentsOf: dir.appendingPathComponent("n"), encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0") ?? 0 }

    /// クイック設定 → 通知シェード → 閉じる の 2 回 + キーボードの 1 回 = 3 回で閉じて true
    func testHideKeyboardUnderQuickSettingsPressesBackUntilTheKeyboardIsGone() async throws {
        let driver = AndroidDriver(serial: serial, adbPath: try hidingADB(shadeUntil: 2))
        let hid = try await SettleOverride.$skip.withValue(true) { try await driver.hideKeyboardIfShown() }
        XCTAssertTrue(hid)
        XCTAssertEqual(backs(), 3)
    }

    /// 上限まで撃ってもシェードが残るなら「閉じた」と言わない
    func testHideKeyboardThrowsWhenTheShadeNeverCloses() async throws {
        let driver = AndroidDriver(serial: serial, adbPath: try hidingADB(shadeUntil: 99, keyboardUntil: 99))
        do {
            _ = try await SettleOverride.$skip.withValue(true) { try await driver.hideKeyboardIfShown() }
            XCTFail("キーボードが出たままなのに閉じたと返した")
        } catch {
            XCTAssertTrue("\(error)".contains("still showing"), "\(error)")
        }
        XCTAssertEqual(backs(), AndroidDriver.hideKeyboardMaxBacks)
    }

    /// シェードが無いときは従来どおり 1 回だけ(読み直さない・2 回目を撃たない)
    func testHideKeyboardWithoutShadePressesBackOnce() async throws {
        let driver = AndroidDriver(serial: serial, adbPath: try hidingADB(shadeUntil: 0))
        let hid = try await SettleOverride.$skip.withValue(true) { try await driver.hideKeyboardIfShown() }
        XCTAssertTrue(hid)
        XCTAssertEqual(backs(), 1)
    }

    /// 通知の到着で窓が可視でも BACK はキーボードに届く。閉じ途中を見て重ねるとアプリの画面が戻る
    func testHideKeyboardUnderAVisibleShadeWithoutFocusPressesBackOnce() async throws {
        let driver = AndroidDriver(serial: serial, adbPath: try hidingADB(shadeUntil: 99, keyboardUntil: 99, focusHeld: false))
        let hid = try await SettleOverride.$skip.withValue(true) { try await driver.hideKeyboardIfShown() }
        XCTAssertTrue(hid)
        XCTAssertEqual(backs(), 1)
    }

    /// 焦点は `dumpsys window displays` にだけ出る(`windows` に読みに行くと Android 12〜15 で常に false)
    func testClearInputWithoutRefRefusesWhenTheShadeHoldsTheFocus() async throws {
        let driver = AndroidDriver(serial: serial, adbPath: try hidingADB(shadeUntil: 99, keyboardUntil: 0))
        do {
            try await driver.clearInput(ref: nil)
            XCTFail("覆いが焦点を持つのに clearInput を撃った")
        } catch {
            XCTAssertTrue("\(error)".contains("nothing was cleared"), "\(error)")
        }
    }

    func testInputFocusHeldByShadeReadsOnlyTheFocusLine() {
        XCTAssertTrue(AndroidForegroundWindows.inputFocusHeldByShade(
            dumpsys: "  mCurrentFocus=Window{a u0 NotificationShade}"))
        XCTAssertFalse(AndroidForegroundWindows.inputFocusHeldByShade(
            dumpsys: "  mCurrentFocus=Window{a u0 com.app/com.app.Main}"))
        // 行が無い OS(ヘッズアップで窓が可視でも入力フォーカスは持たない)は断らない
        XCTAssertFalse(AndroidForegroundWindows.inputFocusHeldByShade(
            dumpsys: "  Window #1 Window{a u0 NotificationShade}:\n    isVisible=true"))
    }

    func testUnlockCooldownIsPinnedAndGatesTheWait() {
        XCTAssertEqual(AndroidPhysicalDevice.unlockRetryCooldownSeconds, 60)
        let now = Date()
        XCTAssertFalse(AndroidPhysicalDevice.inUnlockCooldown(failedAt: nil, now: now))
        XCTAssertTrue(AndroidPhysicalDevice.inUnlockCooldown(failedAt: now.addingTimeInterval(-30), now: now))
        XCTAssertFalse(AndroidPhysicalDevice.inUnlockCooldown(failedAt: now.addingTimeInterval(-61), now: now))
    }
}
