// セッションの回復前の「アプリは居るか」の問い: SpringBoard はアプリではないので問わない(問うと常に「居ない」= 正常なホーム画面のセッションを
// 落ちたと断る)・実機にも問いを渡す(渡さないと死んだアプリへの操作が冷間起動して別の画面を押す)。

import XCTest
@testable import FTBridgeClient

final class RecoveryProbeSystemShellTests: XCTestCase {
    func testSpringBoardIsNeverAskedAboutOnEitherKindOfDevice() async {
        let simulator = SimulatorAppProcess.recoveryProbe(simulatorUDID: "00000000-0000-0000-0000-000000000000")
        let physical = SimulatorAppProcess.recoveryProbe(simulatorUDID: nil, physicalUDID: "phys")
        XCTAssertNotNil(simulator)
        XCTAssertNotNil(physical, "実機に問いを渡していない")
        let sim = await simulator?("com.apple.springboard")
        let phys = await physical?("com.apple.springboard")
        XCTAssertNil(sim)
        XCTAssertNil(phys)
        XCTAssertNil(SimulatorAppProcess.recoveryProbe(simulatorUDID: nil, physicalUDID: nil))
        XCTAssertFalse(SimulatorAppProcess.asksAboutProcess(bundleID: "com.apple.springboard"))
        XCTAssertTrue(SimulatorAppProcess.asksAboutProcess(bundleID: "com.ftester.e2e"))
    }
}
