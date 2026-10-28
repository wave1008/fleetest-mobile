// サーバーの控えの機械共通の索引(DS-18.10)と、監視がそれを読む `MonitorServicesReader` の検証。
// 守るもの: ①控えを書くと索引に載り、別の work(stateDir)の控えも1つの索引から読める ②消すと索引も外れる
// ③先の無い索引は読み手が出さず、次に書く人が掃く ④同じファイル名で別の控えを指す索引は外さない
// ⑤読めない控えは出さない ⑥持ち主の生死は pid と開始時刻の照合 ⑦控えの削除は `ServicesLeaseStore.remove` だけ(走査)。

import FTServices
import XCTest
@testable import fleetest

final class ServicesLeaseIndexTests: XCTestCase {
    private var root: URL!
    private var home: String!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("services-index-\(UUID().uuidString)")
        home = root.appendingPathComponent("home").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func lease(pid: Int32, prefix: String, project: String, kind: ServicesLease.Kind = .owner,
                       phase: ServicesLease.Phase = .running) -> ServicesLease {
        ServicesLease(pid: pid, pidStartedAt: "2026-10-29T00:00:00Z", kind: kind, runtime: "apple", endpoint: "apple",
                      prefix: prefix, generation: "g", workspace: "/ws", project: project, profile: "ios-1",
                      containers: ["\(prefix)-db": "c1"], phase: phase)
    }

    /// work(発行者ごとの作業フォルダ)を模した stateDir に控えを書く
    @discardableResult
    private func place(_ lease: ServicesLease, work: String) throws -> URL {
        let url = ServicesLeaseFile.directory(stateDir: root.appendingPathComponent(work).appendingPathComponent(".fleetest"))
            .appendingPathComponent(ServicesLeaseFile.fileName(pid: lease.pid, prefix: lease.prefix))
        try ServicesLeaseStore.write(lease, to: url, home: home)
        return url
    }

    private func pointerNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: ServicesLeaseIndex.directory(home: home).path)) ?? []).sorted()
    }

    func testLeasesInDifferentWorkFoldersAreReadThroughOneIndex() throws {
        try place(lease(pid: 101, prefix: "fleetest-aaaaaaaaaaaa", project: "ec-mobile"), work: "alice")
        try place(lease(pid: 202, prefix: "fleetest-bbbbbbbbbbbb", project: "shop", kind: .run, phase: .starting), work: "bob")
        let read = MonitorServicesReader.read(home: home) { pid, _ in pid == 101 }
        XCTAssertEqual(read, [
            ApiMonitorServicesLease(project: "ec-mobile", profile: "ios-1", holder: "owner", pid: 101,
                                    phase: "running", orphan: false),
            ApiMonitorServicesLease(project: "shop", profile: "ios-1", holder: "run", pid: 202,
                                    phase: "starting", orphan: true),
        ])
    }

    func testRewritingTheLeaseKeepsOnePointerAndRemovingItUnregisters() throws {
        let url = try place(lease(pid: 101, prefix: "fleetest-aaaaaaaaaaaa", project: "ec-mobile", phase: .starting), work: "alice")
        try ServicesLeaseStore.write(lease(pid: 101, prefix: "fleetest-aaaaaaaaaaaa", project: "ec-mobile"), to: url, home: home)
        XCTAssertEqual(pointerNames(), ["101~fleetest-aaaaaaaaaaaa.json"])
        XCTAssertEqual(MonitorServicesReader.read(home: home) { _, _ in true }.map(\.phase), ["running"])
        ServicesLeaseStore.remove(at: url, home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(pointerNames(), [], "控えを消したら索引も外れる")
    }

    func testDanglingPointerIsSkippedByTheReaderAndSweptByTheNextWriter() throws {
        let gone = try place(lease(pid: 101, prefix: "fleetest-aaaaaaaaaaaa", project: "ec-mobile"), work: "alice")
        try FileManager.default.removeItem(at: gone)  // 索引を外さずに消えた控え(手で消した等)
        XCTAssertEqual(MonitorServicesReader.read(home: home) { _, _ in true }, [], "先の無い索引は出さない")
        XCTAssertEqual(pointerNames(), ["101~fleetest-aaaaaaaaaaaa.json"], "読み手は掃かない")
        try place(lease(pid: 303, prefix: "fleetest-cccccccccccc", project: "shop"), work: "carol")
        XCTAssertEqual(pointerNames(), ["303~fleetest-cccccccccccc.json"], "新しい索引を作る書き手が掃く")
    }

    func testUnregisterLeavesAPointerThatNamesAnotherLease() throws {
        let alice = try place(lease(pid: 101, prefix: "fleetest-aaaaaaaaaaaa", project: "ec-mobile"), work: "alice")
        // 同じファイル名の控えが別の場所にある(索引はそちらを指している)
        let other = root.appendingPathComponent("elsewhere").appendingPathComponent(alice.lastPathComponent)
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: alice, to: other)
        try ServicesLeaseStore.write(lease(pid: 101, prefix: "fleetest-aaaaaaaaaaaa", project: "ec-mobile"), to: other, home: home)
        ServicesLeaseStore.remove(at: alice, home: home)
        XCTAssertEqual(ServicesLeaseIndex.leaseURLs(home: home).map(\.path), [other.standardizedFileURL.path])
    }

    func testUnreadableLeaseIsNotShown() throws {
        let url = try place(lease(pid: 101, prefix: "fleetest-aaaaaaaaaaaa", project: "ec-mobile"), work: "alice")
        try "{".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(MonitorServicesReader.read(home: home) { _, _ in true }, [])
    }

    /// 控えを直接 removeItem すると索引に先の無い行が残る(読み手は出さないが、`services status` と画面が食い違う時間ができる)
    func testLeaseFilesAreRemovedOnlyThroughTheStore() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/fleetest")
        let files = try FileManager.default.contentsOfDirectory(atPath: sources.path).filter { $0.hasSuffix(".swift") }
        XCTAssertTrue(files.contains("ServicesSession.swift"), "走査が Sources/fleetest に届いていない")
        var offenders: [String] = []
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated()
            where line.contains("removeItem(") && (line.contains("leaseURL") || line.contains("entry.url")) {
                offenders.append("\(file):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(offenders, [], "控えの削除は ServicesLeaseStore.remove を通す")
    }
}
