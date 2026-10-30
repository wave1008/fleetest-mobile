// 実機の clearAppData(入れ直し)に名指しされたパスが「パッケージの形」か(消す前に断る判定)。

import XCTest
@testable import FTCore

final class ReinstallPackageShapeTests: XCTestCase {
    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pkgshape-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testAppFolderWithInfoPlistIsAPackageButAPlainFolderOrPlistIsNot() throws {
        let dir = try temp()
        let app = dir.appendingPathComponent("A.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist = app.appendingPathComponent("Info.plist")
        XCTAssertFalse(ReinstallPackageCheck.looksLikePackage(path: app.path), "Info.plist の無い .app")
        try Data().write(to: plist)
        XCTAssertTrue(ReinstallPackageCheck.looksLikePackage(path: app.path))
        XCTAssertFalse(ReinstallPackageCheck.looksLikePackage(path: plist.path), "Info.plist 単体")
        XCTAssertFalse(ReinstallPackageCheck.looksLikePackage(path: dir.path), "ただのフォルダ")
        XCTAssertFalse(ReinstallPackageCheck.looksLikePackage(path: dir.appendingPathComponent("none.app").path))
    }

    func testIpaMustBeAFile() throws {
        let dir = try temp()
        let ipa = dir.appendingPathComponent("a.ipa")
        try Data().write(to: ipa)
        XCTAssertTrue(ReinstallPackageCheck.looksLikePackage(path: ipa.path))
        let folder = dir.appendingPathComponent("b.ipa")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertFalse(ReinstallPackageCheck.looksLikePackage(path: folder.path))
    }
}
