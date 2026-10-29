// 「絞り込みに合うデバイスが無い」の断りは、実際に絞った値で文面を組む(`--runner local` が機械の枠へ絞った回は
// フラグが空なので、フラグで組むと文面の頭が空になる)

import Foundation
import XCTest
@testable import fleetest
@testable import FTCore

final class DeviceFilterRefusalScopeTests: XCTestCase {
    private func emptyProfile() -> ResolvedProfile {
        ResolvedProfile(
            project: TestProject(name: "dummy", rootURL: URL(fileURLWithPath: "/tmp/dummy")),
            runName: "P", appName: "app", apps: [:],
            devices: [], fm: FMConfig(), heal: false,
            reportDir: URL(fileURLWithPath: "/tmp/dummy/reports"),
            defaultTimeout: nil, scenarioTimeout: nil, wipeDataOnBloat: true, updateWebView: false,
            wipeDataThresholdGB: 8, recoverCpuFallbackToGpu: false, locale: "ja_JP",
            iosPreActionPing: true, containerInference: true, ocrTextVisibilityCheck: true,
            preferCheckStateClassifier: true,
            enableAnimations: false, responseMeasurement: false, responseRepeat: 5,
            homeOnStart: true, playProtectBypass: true, record: false, recordFailuresOnly: false,
            recordBitrateKbps: 1500, recordFullResolution: false, warnings: [])
    }

    func testRefusalNamesTheEffectiveScopeNotTheEmptyFlags() throws {
        let common = try RunCommonOptions.parse([])
        XCTAssertThrowsError(try common.rejectDeviceFilterMatchingNothing(
            profile: "P", resolvedAll: emptyProfile(), filtered: emptyProfile(),
            devices: ["iPhone-01"], deviceMachine: "local")) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("--device iPhone-01 --device-machine local matched no device"), text)
        }
        // 絞っていなければ断らない(0台はプロファイル自体の誤り = resolve が言う)
        XCTAssertNoThrow(try common.rejectDeviceFilterMatchingNothing(
            profile: "P", resolvedAll: emptyProfile(), filtered: emptyProfile(), devices: [], deviceMachine: nil))
    }
}
