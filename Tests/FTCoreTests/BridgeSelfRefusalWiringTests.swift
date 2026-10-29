// app ID を取ってアプリを操作する DSL コマンド(`_ appID: String? = nil` を取るもの)は、撃つ前に必ずブリッジ自身を断る
// (`refuseBridgeItself`)。門の無いコマンドを足すと、シナリオがブリッジを起動・消去・アンインストールして自滅する。
// 確かめるだけの appIs(`_ appID: String` = 省略不可)は対象外。

import XCTest

final class BridgeSelfRefusalWiringTests: XCTestCase {
    func testEveryAppTargetingDSLCommandRefusesTheBridge() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FTDSL/CommandsAppControl.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        let chunks = code.components(separatedBy: "\npublic func ").dropFirst()
        var checked: [String] = []
        for chunk in chunks where chunk.contains("(_ appID: String? = nil") {
            let name = String(chunk.prefix { $0 != "(" })
            checked.append(name)
            XCTAssertTrue(chunk.contains("refuseBridgeItself(command: \"\(name)\""),
                          "\(name) はブリッジ自身を断る門(refuseBridgeItself)を通していない")
        }
        XCTAssertEqual(Set(checked), ["launchApp", "restartApp", "clearAppData", "removeApp"], "\(checked)")
    }
}
