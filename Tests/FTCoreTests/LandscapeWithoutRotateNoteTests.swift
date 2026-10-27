// 失敗したステップに「横向きで、このシナリオは回していない」を注記する(StepNote.landscapeWithoutRotate)。
// 前のセッションが回したまま残した端末の赤を、レポートから辿れるようにする(run の冒頭の警告はログにしか出ない)

import XCTest
@testable import FTCore

final class LandscapeWithoutRotateNoteTests: XCTestCase {

    private func failingTap(orientation: FTOrientation?, rotateFirst: Bool) async -> [String] {
        await failingTapOutcome(orientation: orientation, rotateFirst: rotateFirst).notes.map(\.rawValue)
    }

    private func failingTapOutcome(orientation: FTOrientation?, rotateFirst: Bool) async -> StepOutcome {
        let driver = FakeAppDriver(name: "primary", log: CallLog(), snapshotElements: [[]])
        driver.statusOrientation = orientation
        let executor = StepExecutor(driver: driver, isAndroid: false, tunables: RunTunables())
        if rotateFirst { _ = await executor.execute(FlowStep(action: "rotateTo", direction: "landscape")) }
        return await executor.execute(FlowStep(action: "tap", locator: FlowLocator(id: "missing"), timeout: 0))
    }

    func testFailureInLandscapeWithoutRotateIsNoted() async {
        let notes = await failingTap(orientation: .landscape, rotateFirst: false)
        XCTAssertTrue(notes.contains("landscape-without-rotate"), "\(notes)")
        // 人が読むレポートは失敗の文言を出す(注記は結果 JSON にしか載らない)
        guard case .failed(let message) = await failingTapOutcome(orientation: .landscape, rotateFirst: false).status
        else { return XCTFail("失敗にならなかった") }
        XCTAssertTrue(message.contains("the screen was in landscape and this scenario never rotated it"), message)
    }

    /// シナリオが自分で回した横向き・縦向き・向きを申告しないブリッジでは黙る
    func testSilentWhenRotatedByTheScenarioOrPortraitOrUnknown() async {
        let rotated = await failingTap(orientation: .landscape, rotateFirst: true)
        XCTAssertFalse(rotated.contains("landscape-without-rotate"), "シナリオが回した横向きを注記した: \(rotated)")
        let portrait = await failingTap(orientation: .portrait, rotateFirst: false)
        XCTAssertFalse(portrait.contains("landscape-without-rotate"))
        let unknown = await failingTap(orientation: nil, rotateFirst: false)
        XCTAssertFalse(unknown.contains("landscape-without-rotate"))
    }
}
