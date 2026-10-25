// USB トンネル(iproxy)越しの実機だけに、ドライバのエラーへ注記を足すことの固定。
// lanTransportAdvice との排他(実機の LAN 接続はループバックでない・実機以外は常にループバック)も
// ここで固定する。
import XCTest
@testable import FTBridgeClient

final class UsbTunnelAdviceTests: XCTestCase {

    private func advice(_ url: String, physicalUDID: String?) -> String {
        BridgeClient.usbTunnelAdvice(baseURL: URL(string: url)!, physicalUDID: physicalUDID)
    }

    func testPhysicalDeviceOverLoopbackIsNamed() {
        let text = advice("http://127.0.0.1:8123", physicalUDID: "00008030-ABC")
        XCTAssertTrue(text.contains("USB tunnel"), text)
        XCTAssertTrue(text.contains("iproxy"), text)
        XCTAssertTrue(text.contains("cable"), text)
    }

    func testSimulatorOverLoopbackSaysNothing() {
        XCTAssertEqual(advice("http://127.0.0.1:8123", physicalUDID: nil), "")
    }

    func testPhysicalDeviceOverLanSaysNothing() {
        // LAN の実機は lanTransportAdvice が受け持つ(対の注記が両方付くと矛盾した助言になる)
        XCTAssertEqual(advice("http://192.168.20.5:8127", physicalUDID: "00008030-ABC"), "")
    }

    func testAdvicesAreMutuallyExclusive() {
        for (url, physicalUDID) in [
            ("http://127.0.0.1:8123", nil), ("http://127.0.0.1:8123", "00008030-ABC"),
            ("http://192.168.20.5:8127", nil), ("http://192.168.20.5:8127", "00008030-ABC"),
        ] as [(String, String?)] {
            let lan = BridgeClient.lanTransportAdvice(baseURL: URL(string: url)!)
            let usb = advice(url, physicalUDID: physicalUDID)
            XCTAssertTrue(lan.isEmpty || usb.isEmpty, "both fired for \(url) physicalUDID=\(String(describing: physicalUDID))")
        }
    }

    // MARK: - エラーの種類での切り分け(実測: SE3 に iproxy を張り、端末側の待受の有無と iproxy の生死を入れ替えて URLSession で撃った)

    private func advice(_ code: URLError.Code, macSide: BridgeDiscovery.ConnectProbe? = nil) -> String {
        BridgeClient.usbTunnelAdvice(baseURL: URL(string: "http://127.0.0.1:8130")!, physicalUDID: "00008110-ABC",
                                     error: URLError(code), macSide: macSide)
    }

    func testRefusedOnTheMacSideSaysTheTunnelIsGone() {
        let text = advice(.cannotConnectToHost)
        XCTAssertTrue(text.contains("tunnel itself is gone"), text)
        XCTAssertTrue(text.contains("port 8130"), text)
        XCTAssertFalse(text.contains("bridge on the device has stopped"), text)
    }

    /// 切れた接続は Mac 側の待受で言い分ける(実測: 要求の途中で iproxy を止めると同じ `.networkConnectionLost` になる)
    func testDroppedConnectionIsAttributedByTheMacSide() {
        let generic = advice("http://127.0.0.1:8130", physicalUDID: "00008110-ABC")
        let deviceSide = advice(.networkConnectionLost, macSide: .connected)
        XCTAssertTrue(deviceSide.contains("bridge on the device has stopped"), deviceSide)
        let tunnelGone = advice(.networkConnectionLost, macSide: .refused)
        XCTAssertTrue(tunnelGone.contains("tunnel went away during the request"), tunnelGone)
        XCTAssertFalse(tunnelGone.contains("bridge on the device has stopped"), tunnelGone)
        XCTAssertEqual(advice(.networkConnectionLost, macSide: .unknown), generic, "確かめが決まらなければ帰属を言わない")
        XCTAssertEqual(advice(.networkConnectionLost), generic, "確かめていなければ帰属を言わない")
        XCTAssertEqual(advice(.timedOut), generic, "切り分けられない種類は従来の案内")
    }
}
