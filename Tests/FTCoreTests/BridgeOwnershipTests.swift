// ブリッジの持ち主の仕分け(BridgeOwnership.classify)。doctor と供給の計画段が共有する。

import XCTest
@testable import FTCore

final class BridgeOwnershipTests: XCTestCase {

    func testClassifiesTheFourOwnerships() {
        XCTAssertEqual(BridgeOwnership.classify(ownerRepo: "/repo", isOwnRepo: true,
                                                ownerExists: true, hasStateFile: false), .own)
        XCTAssertEqual(BridgeOwnership.classify(ownerRepo: "/other", isOwnRepo: false,
                                                ownerExists: true, hasStateFile: false),
                       .foreign(owner: "/other"))
        XCTAssertEqual(BridgeOwnership.classify(ownerRepo: "/gone", isOwnRepo: false,
                                                ownerExists: false, hasStateFile: false),
                       .orphan(owner: "/gone"))
        XCTAssertEqual(BridgeOwnership.classify(ownerRepo: nil, isOwnRepo: false,
                                                ownerExists: false, hasStateFile: false), .unknown)
        // 申告の無い旧ブリッジは自分の台帳で自分のものと分かる
        XCTAssertEqual(BridgeOwnership.classify(ownerRepo: nil, isOwnRepo: false,
                                                ownerExists: false, hasStateFile: true), .own)
    }

    /// 台帳はポートしか持たない。自分の古い台帳が残るポートに別のクローンのブリッジが居ても、
    /// 申告が別なら別のワークスペースのもの(台帳を先に見ると自分のものと誤って止める)
    func testTheReportedOwnerWinsOverAStaleLedgerOnTheSamePort() {
        XCTAssertEqual(BridgeOwnership.classify(ownerRepo: "/other", isOwnRepo: false,
                                                ownerExists: true, hasStateFile: true),
                       .foreign(owner: "/other"))
    }

    /// 改名で移ったクローンの旧パスには、動き続けるランナーが `.fleetest/xcresult` だけを作り直す。それはワークスペースではない
    func testAWorkspaceIsWherePackageSwiftIsNotWhereADirectoryIs() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftowner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".fleetest/xcresult"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(BridgeOwnership.ownerWorkspaceExists(dir.path))
        XCTAssertFalse(BridgeOwnership.ownerWorkspaceExists(dir.path + "-gone"))
        try Data().write(to: dir.appendingPathComponent("Package.swift"))
        XCTAssertTrue(BridgeOwnership.ownerWorkspaceExists(dir.path))
    }

    /// 持ち主の生存を作る呼び手(供給・doctor・foreignRunners)は全部 `ownerWorkspaceExists` を通る。
    /// 1箇所でもディレクトリの実在へ戻すと、供給と doctor が同じブリッジを別の持ち主と読む
    func testEveryOwnerExistenceCheckGoesThroughOwnerWorkspaceExists() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var statusCallers: [String] = []
        var launcher = ""
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if url.lastPathComponent == "BridgeLauncher.swift" { launcher = text }
            statusCallers += text.components(separatedBy: "\n").filter { $0.contains("ownerExists: status.") }
        }
        XCTAssertEqual(statusCallers.count, 2, "供給(BridgeProvisioner)と doctor の2箇所")
        for line in statusCallers { XCTAssertTrue(line.contains("ownerWorkspaceExists"), line) }
        XCTAssertTrue(launcher.contains("ownerWorkspaceExists(runner.ownerRepo)"), "foreignRunners")
        XCTAssertFalse(launcher.contains("fileExists(atPath: runner.ownerRepo)"), "foreignRunners")
    }

    func testSameRepoFoldsPathSpellings() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftowner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(BridgeOwnership.isSameRepo(dir.path + "/", dir))
        // /var と /private/var は同じ場所(temporaryDirectory は /var/folders/... 側)
        let privatePath = dir.path.hasPrefix("/var/") ? "/private" + dir.path : dir.path
        XCTAssertTrue(BridgeOwnership.isSameRepo(privatePath, dir))
        XCTAssertFalse(BridgeOwnership.isSameRepo(dir.path + "-other", dir))
    }

    /// 実際の `ps` の command 列(ランナーの起動引数)から端末・ポート・持ち主のワークスペースを読む
    func testRunnerProcessReadsDeviceAndOwnerFromTheLaunchArguments() throws {
        let command = "/Applications/Xcode_27.2_beta_3.app/Contents/Developer/usr/bin/xcodebuild test-without-building"
            + " -xctestrun /Users/me/github/ft-kb/.fleetest/DerivedData/Build/Products/FleetestRunner-8125.xctestrun"
            + " -destination platform=iOS Simulator,id=B422AB58-6C79-45BC-92F0-BEF88061C8E1"
            + " -resultBundlePath /Users/me/github/ft-kb/.fleetest/xcresult/bridge-8125-1792398295961.xcresult"
            + " -derivedDataPath /Users/me/github/ft-kb/.fleetest/DerivedData"
        let runner = try XCTUnwrap(BridgeOwnership.runnerProcess(fromCommand: command))
        XCTAssertEqual(runner, BridgeOwnership.RunnerProcess(udid: "B422AB58-6C79-45BC-92F0-BEF88061C8E1", port: 8125,
                                                             ownerRepo: "/Users/me/github/ft-kb"))
    }

    func testOtherProcessesAreNotRunners() {
        XCTAssertNil(BridgeOwnership.runnerProcess(fromCommand: "/usr/bin/xcodebuild build-for-testing -scheme Runner"))
        XCTAssertNil(BridgeOwnership.runnerProcess(fromCommand: "tail -f bridge-8125.log id=B422AB58"))
    }
}
