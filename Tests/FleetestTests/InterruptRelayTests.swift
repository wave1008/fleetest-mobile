import FTCore
import Foundation
import XCTest
@testable import fleetest

/// 並行する relay の1つを止めても、残りの子への横取りが解けないことを固定する
/// (受け手報告 2026-08-23: 手元の子が先に終わった分散 run の親へ kill -INT → 親だけ死んで
/// M1Max の子・ssh・リモートの run・dispatch.lock が残った)。
/// **このテストは自プロセスへ SIGINT を撃つ**: 横取りが解けていれば既定動作でテストプロセスごと
/// 落ちる(= 検出)。壊れていない限り無害
final class InterruptRelayTests: XCTestCase {

    override func tearDown() {
        InterruptRelay.resetReceivedInterruptForTesting()
        super.tearDown()
    }

    /// SIGTERM を受けた回数をファイルに書き続ける子(TERM では終わらない。後片付けで SIGKILL)
    private func termCounter() throws -> (process: Process, count: () -> Int) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("term-\(UUID().uuidString)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "n=0; trap 'n=$((n+1)); echo $n > \"$0\"' TERM; while :; do sleep 0.05; done", file.path]
        try p.run()
        addTeardownBlock {
            kill(p.processIdentifier, SIGKILL)
            try? FileManager.default.removeItem(at: file)
        }
        Thread.sleep(forTimeInterval: 0.2)   // trap を張り終えるまで
        return (p, { Int((try? String(contentsOf: file, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0 })
    }

    /// 登録より前に届いた中断は、catchUp の子へ登録の直後に1回だけ伝える
    func testCatchUpDeliversAnInterruptThatArrivedBeforeRegistrationOnce() throws {
        let keep = InterruptRelay.observing {}   // シグナルソースを張っておく(無いと SIGINT でテストごと落ちる)
        defer { keep.stop() }
        kill(getpid(), SIGINT)
        Thread.sleep(forTimeInterval: 0.3)
        let child = try termCounter()
        let relay = InterruptRelay.forwarding(to: child.process, escalateAfter: nil, catchUp: true)
        defer { relay.stop() }
        let deadline = Date().addingTimeInterval(5)
        while child.count() == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(child.count(), 1, "登録より前の中断を1回だけ伝えていない")
    }

    /// 登録の後に届いた中断は forwardToAll だけが伝える(catchUp が二重に送らない = 子の2回目の中断は後始末を飛ばす)
    func testCatchUpDoesNotDoubleAnInterruptThatArrivesAfterRegistration() throws {
        let child = try termCounter()
        let relay = InterruptRelay.forwarding(to: child.process, escalateAfter: nil, catchUp: true)
        defer { relay.stop() }
        // 誤って登録の時点で送っていれば、ここまでに1回数えられる(続けて撃つと同じ合図が1つに重なって数え分けられない)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(child.count(), 0, "中断の前の登録で合図を送った")
        kill(getpid(), SIGINT)
        let deadline = Date().addingTimeInterval(5)
        while child.count() == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(child.count(), 1)
        let late = try termCounter()
        let lateRelay = InterruptRelay.forwarding(to: late.process, escalateAfter: nil, catchUp: false)
        defer { lateRelay.stop() }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(late.count(), 0, "catchUp: false の登録へ過去の中断を伝えた")
    }

    /// 購読も同じ: 登録より前の中断は登録の直後に1回、登録の後の中断は通常の通知の1回だけ
    func testObservingCatchUpCallsOnceForAnEarlierInterruptAndNeverDoubles() throws {
        final class Count: @unchecked Sendable {
            // @unchecked の根拠: n は lock の下でしか触らない
            private let lock = NSLock()
            private var n = 0
            func bump() { lock.lock(); n += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        let keep = InterruptRelay.observing {}   // シグナルソースを張っておく
        defer { keep.stop() }
        kill(getpid(), SIGINT)
        Thread.sleep(forTimeInterval: 0.3)
        let early = Count()
        let lateRelay = InterruptRelay.observing(catchUp: true) { early.bump() }
        defer { lateRelay.stop() }
        XCTAssertEqual(early.value, 1, "登録より前の中断を補っていない")
        InterruptRelay.resetReceivedInterruptForTesting()
        let fresh = Count()
        let freshRelay = InterruptRelay.observing(catchUp: true) { fresh.bump() }
        defer { freshRelay.stop() }
        XCTAssertEqual(fresh.value, 0, "中断の前の登録で呼んだ")
        kill(getpid(), SIGINT)
        let deadline = Date().addingTimeInterval(5)
        while fresh.value == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(fresh.value, 1)
    }

    /// 3経路の配り手は、ロックの取得中に届いた中断を知るよう catchUp で購読する。api run は自前のシグナルソースを持たない(ソース走査)
    func testDispatchersObserveWithCatchUp() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let read = { (file: String) in
            try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
        }
        XCTAssertTrue(try read("Sources/fleetest/MultiTargetRunner.swift")
            .contains("InterruptRelay.observing(catchUp: true) { coordinator.interrupt() }"))
        XCTAssertTrue(try read("Sources/fleetest/DeviceMachineRunner.swift")
            .contains("InterruptRelay.observing(catchUp: true) { dispatcher.interrupt() }"))
        let api = try read("Sources/fleetest/ApiRunMachineFanout.swift")
        XCTAssertTrue(api.contains("InterruptRelay.observing(catchUp: true) {"))
        XCTAssertFalse(api.contains("makeSignalSource"), "api run が過去の中断を知らない自前のシグナルソースを持っている")
    }

    /// runEntry は catchUp で登録する(ソース走査)
    func testRunEntryRegistersWithCatchUp() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/fleetest/FleetRunner.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("InterruptRelay.forwarding(to: process, escalateAfter: nil, catchUp: true)"),
                      "runEntry が登録より前に届いた中断を子へ伝えない")
    }

    private func sleeper() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        return p
    }

    func testStoppingOneRelayKeepsForwardingToTheOthers() throws {
        let first = try sleeper()
        let second = try sleeper()
        defer {
            if first.isRunning { first.terminate() }
            if second.isRunning { second.terminate() }
        }
        let relayA = InterruptRelay.forwarding(to: first, escalateAfter: nil)
        let relayB = InterruptRelay.forwarding(to: second, escalateAfter: nil)
        XCTAssertEqual(InterruptRelay.registeredCount, 2)
        relayA.stop()
        XCTAssertEqual(InterruptRelay.registeredCount, 1)

        kill(getpid(), SIGINT)

        let deadline = Date().addingTimeInterval(5)
        while second.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(second.isRunning, "the remaining child must receive the relayed SIGTERM")
        XCTAssertTrue(first.isRunning, "a stopped relay must not forward to its (already released) child")
        relayB.stop()
        XCTAssertEqual(InterruptRelay.registeredCount, 0)
    }

    func testStopIsIdempotentAndRestoresDefaultOnlyWhenEmpty() throws {
        let p = try sleeper()
        defer { if p.isRunning { p.terminate() } }
        let relay = InterruptRelay.forwarding(to: p, escalateAfter: nil)
        relay.stop()
        relay.stop()
        XCTAssertEqual(InterruptRelay.registeredCount, 0)
    }

    /// `Process` を伴わない購読(手元の `api run`/`run` が中断ハンドラを登録する形)。
    /// **戻すと落ちる根拠**: `.observing` を消す/`forwardToAll` の `.observer` ケースを外すと、
    /// このテストは SIGINT を送ってもコールバックが呼ばれず既定動作(テストプロセスごと終了)に
    /// フォールバックする(このテスト自身が検出用に自分へ SIGINT を送る。壊れていなければ無害)
    func testObservingIsNotifiedOnSignalAndStopsAfterStop() throws {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var count = 0
            func increment() { lock.lock(); count += 1; lock.unlock() }
        }
        let flag = Flag()
        let relay = InterruptRelay.observing { flag.increment() }
        XCTAssertEqual(InterruptRelay.registeredCount, 1)

        kill(getpid(), SIGINT)
        let deadline = Date().addingTimeInterval(5)
        while flag.count == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertEqual(flag.count, 1, "observer は SIGINT のたびに呼ばれる")

        relay.stop()
        XCTAssertEqual(InterruptRelay.registeredCount, 0)
        // stop 後は既定動作(このプロセス自体は SIG_DFL に戻るが、テストを落とさないよう
        // 二度目の SIGINT は送らない —— 「呼ばれ続けない」ことは registeredCount==0 で確認済み)
    }

    /// process 版と observer 版が同時に登録されても、シグナルソースは1組のまま
    /// (1プロセスに1組。CLAUDE.md の規律)
    func testProcessAndObserverTargetsShareOneSignalSourceSet() throws {
        let p = try sleeper()
        defer { if p.isRunning { p.terminate() } }
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var count = 0
            func increment() { lock.lock(); count += 1; lock.unlock() }
        }
        let flag = Flag()
        let processRelay = InterruptRelay.forwarding(to: p, escalateAfter: nil)
        let observerRelay = InterruptRelay.observing { flag.increment() }
        XCTAssertEqual(InterruptRelay.registeredCount, 2)

        kill(getpid(), SIGINT)
        let deadline = Date().addingTimeInterval(5)
        while (p.isRunning || flag.count == 0), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertFalse(p.isRunning, "process 版も引き続き届く")
        XCTAssertEqual(flag.count, 1, "observer 版も同じシグナルで届く")

        processRelay.stop()
        observerRelay.stop()
        XCTAssertEqual(InterruptRelay.registeredCount, 0)
    }

    /// 中断を受けた後の runEntry は子を起こさずに 130(親の最後の確認からタスクが走るまでの間の中断で、起こしてから止めない)
    func testRunEntryDoesNotStartAChildAfterAnInterrupt() async throws {
        let keep = InterruptRelay.observing {}   // シグナルソースを張っておく(無いと SIGINT でテストごと落ちる)
        defer { keep.stop() }
        kill(getpid(), SIGINT)
        let deadline = Date().addingTimeInterval(5)
        while !InterruptRelay.hasReceivedInterrupt, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("runEntry-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: marker) }
        let code = await FleetRunner.runEntry(
            binary: "/usr/bin/touch", args: [marker], hostLabel: "t",
            ticket: DispatchTicketIssuer.issue(runGroup: "G", environment: [:]), lockMarker: nil,
            healCollection: HealSourceWriteBack.Collection())
        XCTAssertEqual(code, 130)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "中断の後に子を起こした")
    }
}
