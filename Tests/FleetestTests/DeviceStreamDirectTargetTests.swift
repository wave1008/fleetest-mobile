import XCTest
@testable import fleetest

/// `api device-stream --udid / --serial`(未登録の仮想デバイスへ宛先を直に渡す)の引数の検査。
/// 拡張(monitorDeviceStreamController.ts)が未登録のリモートの仮想デバイスにだけ渡す
final class DeviceStreamDirectTargetTests: XCTestCase {
    func testNeitherGivenKeepsTheRosterPath() throws {
        XCTAssertNil(try ApiDeviceStreamCommand.directTarget(platform: "ios", udid: nil, serial: nil))
        XCTAssertNil(try ApiDeviceStreamCommand.directTarget(platform: "android", udid: nil, serial: nil))
    }

    func testUdidAddressesASimulatorAndSerialAnEmulator() throws {
        XCTAssertEqual(try ApiDeviceStreamCommand.directTarget(platform: "ios", udid: "U-1", serial: nil),
                       .simulator(udid: "U-1"))
        XCTAssertEqual(try ApiDeviceStreamCommand.directTarget(platform: "android", udid: nil, serial: "emulator-5554"),
                       .emulator(serial: "emulator-5554"))
    }

    func testRefusesMismatchedOrConflictingOrEmptyTargets() {
        XCTAssertThrowsError(try ApiDeviceStreamCommand.directTarget(platform: "android", udid: "U-1", serial: nil),
                             "--udid は iOS だけ")
        XCTAssertThrowsError(try ApiDeviceStreamCommand.directTarget(platform: "ios", udid: nil, serial: "emulator-5554"),
                             "--serial は Android だけ")
        XCTAssertThrowsError(try ApiDeviceStreamCommand.directTarget(platform: "ios", udid: "U-1", serial: "emulator-5554"),
                             "両方は渡せない")
        XCTAssertThrowsError(try ApiDeviceStreamCommand.directTarget(platform: "ios", udid: "", serial: nil))
        XCTAssertThrowsError(try ApiDeviceStreamCommand.directTarget(platform: "android", udid: nil, serial: ""))
    }
}
