// 名指しされた入れ直し元が「形は .ipa / .app だが中身が空」のとき、uninstall の前に断る判定(emptyPackageReason)。
// 空のパッケージは devicectl が uninstall の後で断り、アプリが端末から消えたまま終わる。

import XCTest
@testable import FTCore

final class ReinstallEmptyPackageTests: XCTestCase {
    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pkgempty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testIpaThatIsNotAZipIsEmpty() throws {
        let dir = try temp()
        let ipa = dir.appendingPathComponent("fake.ipa")
        try Data("garbage\n".utf8).write(to: ipa)
        XCTAssertNotNil(ReinstallPackageCheck.emptyPackageReason(path: ipa.path))
        let zip = dir.appendingPathComponent("real.ipa")
        try Data([0x50, 0x4B, 0x03, 0x04, 0, 0]).write(to: zip)
        XCTAssertNil(ReinstallPackageCheck.emptyPackageReason(path: zip.path))
    }

    func testAppWithoutExecutableIsEmpty() throws {
        let dir = try temp()
        let app = dir.appendingPathComponent("Fake.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.app"]
        try (plist as NSDictionary).write(to: app.appendingPathComponent("Info.plist"))
        XCTAssertNotNil(ReinstallPackageCheck.emptyPackageReason(path: app.path), "CFBundleExecutable が無い")

        let withName: [String: Any] = ["CFBundleIdentifier": "com.example.app", "CFBundleExecutable": "Fake"]
        try (withName as NSDictionary).write(to: app.appendingPathComponent("Info.plist"))
        XCTAssertNotNil(ReinstallPackageCheck.emptyPackageReason(path: app.path), "実行ファイルの実体が無い")

        try Data("x".utf8).write(to: app.appendingPathComponent("Fake"))
        XCTAssertNil(ReinstallPackageCheck.emptyPackageReason(path: app.path))
    }
}
