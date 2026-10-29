// 操作の対象が解決できなかった失敗(`cannot resolve the locator`)にも、画面を変えなかった前のタップを名指しする
// (sut-ec-mobile の xcuitest モード: 保存の tap が空振り → 戻る → 次の tap が解決できず、保存の空振りが文面に出なかった)

import XCTest
@testable import FTCore

/// 戻る(ref 2)を叩くと一覧の画面へ移る。保存(ref 1)は画面を変えない(空振り)
private final class FormDriver: AppDriver {
    private var onList = false
    private let form = [
        ElementInfo(ref: 1, type: "button", identifier: "btn_save", label: "保存", value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 16, y: 789, width: 370, height: 48), depth: 1),
        ElementInfo(ref: 2, type: "button", identifier: "btn_back", label: "戻る", value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 4, y: 132, width: 48, height: 48), depth: 1),
    ]
    private let list = [
        ElementInfo(ref: 3, type: "staticText", identifier: nil, label: "登録済みの住所がありません", value: nil,
                    placeholder: nil, enabled: true, frame: FTRect(x: 97, y: 477, width: 208, height: 19), depth: 1),
    ]

    func status() async throws -> StatusResponse {
        StatusResponse(ready: true, device: "fake", osVersion: "-", sessionBundleID: nil)
    }
    func install(packagePath: String) async throws -> String? { nil }
    func uninstall(bundleID: String) async throws {}
    func launch(bundleID: String) async throws {}
    func isAppForeground(bundleID: String) async throws -> Bool { true }
    func foregroundAppID() async throws -> String? { nil }
    func terminate() async throws {}
    func screenshot() async throws -> Data { Data() }
    func type(ref: Int?, text: String) async throws {}
    func tap(x: Double, y: Double) async throws {}
    func tap(ref: Int) async throws { if ref == 2 { onList = true } }
    func press(ref: Int, duration: Double) async throws {}
    func swipe(_ direction: FTSwipeDirection) async throws {}
    func snapshot() async throws -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                         elements: onList ? list : form, truncatedCount: 0)
    }
}

final class UnresolvedActionTapHintTests: XCTestCase {
    private func tap(_ id: String) -> FlowStep {
        FlowStep(action: "tap", locator: FlowLocator(id: id), timeout: 0)
    }

    func testUnresolvedTapNamesTheEarlierTapThatChangedNothing() async {
        let executor = StepExecutor(driver: FormDriver(), isAndroid: false, tunables: RunTunables())
        _ = await executor.execute(tap("btn_save"))
        _ = await executor.execute(tap("btn_back"))
        let outcome = await executor.execute(tap("tab_account"))

        guard case .failed(let message) = outcome.status else { return XCTFail("失敗するはず: \(outcome.status)") }
        XCTAssertTrue(message.contains("cannot resolve the locator"), message)
        XCTAssertTrue(message.contains("unchanged between tap id=btn_save"), "空振りした保存を名指しする: \(message)")
        XCTAssertFalse(message.contains("btn_back and"), "画面を変えた戻るは名指ししない: \(message)")
        XCTAssertFalse(message.contains("was also unchanged"), "前置きの無い文で also を言わない: \(message)")
        XCTAssertTrue(outcome.notes.contains(.unchangedTapBeforeFailure), "\(outcome.notes)")
    }

    /// 直前の tap が画面を変えなかったなら、この手の解決に使った木と比べて名指しする(まだ確定していない分)
    func testUnresolvedTapNamesTheImmediatelyPrecedingTapToo() async {
        let executor = StepExecutor(driver: FormDriver(), isAndroid: false, tunables: RunTunables())
        _ = await executor.execute(tap("btn_save"))
        let outcome = await executor.execute(tap("tab_account"))

        guard case .failed(let message) = outcome.status else { return XCTFail("失敗するはず: \(outcome.status)") }
        XCTAssertTrue(message.contains("unchanged between tap id=btn_save"), message)
    }

    /// 解決できなかった手がタップ以外(type)でも、画面を変えなかった直前のタップを名指しする(入口で記録を消す前に控える)
    func testUnresolvedTypeAlsoNamesTheTapThatChangedNothing() async {
        let executor = StepExecutor(driver: FormDriver(), isAndroid: false, tunables: RunTunables())
        _ = await executor.execute(tap("btn_save"))
        let outcome = await executor.execute(FlowStep(action: "type", locator: FlowLocator(id: "field_name"),
                                                      text: "x", timeout: 0))
        guard case .failed(let message) = outcome.status else { return XCTFail("失敗するはず: \(outcome.status)") }
        XCTAssertTrue(message.contains("unchanged between tap id=btn_save"), message)
        XCTAssertTrue(message.contains("and the step after it"), "次の手はタップとは限らない: \(message)")
    }

    /// 前のタップがどれも画面を変えていたら何も添えない(誤検知を出さない側)
    func testNoHintWhenEveryEarlierTapChangedTheScreen() async {
        let executor = StepExecutor(driver: FormDriver(), isAndroid: false, tunables: RunTunables())
        _ = await executor.execute(tap("btn_back"))
        let outcome = await executor.execute(tap("tab_account"))

        guard case .failed(let message) = outcome.status else { return XCTFail("失敗するはず: \(outcome.status)") }
        XCTAssertFalse(message.contains("unchanged between"), message)
    }
}
