// 親が取ったロックを子が「取らない・外さない」で受け取る配線。
//
// **型では守れない継ぎ目**(環境変数・親と子が別プロセス・取得と解放は ssh の向こう)なので
// ソース走査で縛る。とくに**取得と解放は両方向**を固定する —— 取得だけ飛ばすと子の defer が
// 親のロックを消し、解放だけ飛ばすと子が親のロックを待って詰む。どちらも緑の run では起きない。

import Foundation
import XCTest
@testable import fleetest

final class DispatchLockHandoffWiringTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// 親が居るときに飛ばす関数の集合を**等号で固定する**(増えても減っても落ちる)
    func testTheParentHeldGateCoversAcquireAndBothReleasePaths() throws {
        let text = try source("Sources/fleetest/RemoteRunDispatcher.swift")
        var enclosing = ""
        var gated: [String] = []
        for line in text.components(separatedBy: "\n") {
            if let range = line.range(of: "func ") {
                enclosing = String(line[range.upperBound...].prefix {
                    $0.isLetter || $0.isNumber || $0 == "_"
                })
            }
            // 宣言そのものの行・コメント行は数えない(門を置いた場所だけを見る)
            guard line.contains("parentHoldsThisLock"), !line.contains("private var"),
                  !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
            gated.append(enclosing)
        }
        XCTAssertEqual(gated.sorted(),
                       // logKeptDispatchLock はロック操作ではなく「保持している」と言うかの門
                       // (親が握るロックを子が「まだ終わっていないかも・保持」と言わない)
                       ["acquireDispatchLock", "logKeptDispatchLock", "releaseDispatchLock",
                        "releaseLockIfRunEnded"],
                       "親が握っているときに飛ばす箇所が増減した(取得と解放は必ず両方)")
    }

    /// 親も**子と同じ取得(待機列 FIFO)を通す** —— 2つ目の取得実装を作らない
    func testTheParentEntryPointReusesTheChildAcquisition() throws {
        let text = try source("Sources/fleetest/RemoteRunDispatcher.swift")
        let entry = try XCTUnwrap(text.range(of: "func acquireDispatchLockAsParent"))
        let body = text[entry.lowerBound...].prefix(600)
        XCTAssertTrue(body.contains(
            "try acquireDispatchLock(layout: layout, runGroup: runGroup, interruptFlag: interruptFlag)"),
            "親が独自の取得を書いている(待機列を通らない経路ができる)")
        XCTAssertTrue(body.contains("resolveLayout()"),
                      "親が layout を自分で組み立てている(同じ ssh を2つの実装で書かない)")
    }

    /// 親は**1台ずつ**取る —— 並行に撃つと順序が意味を失う(同時に撃った2台の前後は決まらない)
    func testTheParentAcquiresSequentially() throws {
        let text = try source("Sources/fleetest/DispatchPrelock.swift")
        for concurrent in ["withTaskGroup", "DispatchQueue", "Task {", "await "] {
            XCTAssertFalse(text.contains(concurrent), "取得を並行に撃っている: \(concurrent)")
        }
    }

    /// 3つの fan-out すべてが、**子を起こす前に**取り切り、**必ず解放する**。
    /// 機械分担の3経路は前段(MachineFanoutFrontHalf)が取り切り(失敗・中断では前段が解放する)、
    /// 呼び手は戻った後 `defer { held.close() }` で解放する。`--fleet` は自前
    func testEveryFanoutPrelocksBeforeLaunchingChildrenAndReleasesOnEveryExit() throws {
        let front = try source("Sources/fleetest/MachineFanoutFrontHalf.swift")
        XCTAssertTrue(front.contains("prelock?.releaseAll()"), "前段が失敗・中断でロックを残す")
        XCTAssertTrue(front.contains("lock.acquireInOrder("), "前段が取り切っていない")
        for path in ["Sources/fleetest/ApiRunMachineFanout.swift",
                     "Sources/fleetest/DeviceMachineRunner.swift",
                     "Sources/fleetest/MultiTargetRunner.swift"] {
            let text = try source(path)
            XCTAssertTrue(text.contains("defer { held.close() }"),
                          "\(path): 解放が defer に無い(失敗・中断でロックが残る)")
            let acquire = try XCTUnwrap(text.range(of: "MachineFanoutFrontHalf.run("),
                                        "\(path): 前段(親が取り切る)を通っていない")
            let launch = try XCTUnwrap(text.range(of: "addTask {") ?? text.range(of: "coordinator.start()"),
                                       "\(path): 子の起動が見つからない")
            XCTAssertLessThan(acquire.lowerBound, launch.lowerBound,
                              "\(path): 子を起こしてからロックを取っている(順序が意味を失う)")
        }
        let fleet = try source("Sources/fleetest/FleetRunner.swift")
        XCTAssertTrue(fleet.contains("defer { prelock.releaseAll() }"), "FleetRunner: 解放が defer に無い")
        let acquire = try XCTUnwrap(fleet.range(of: "prelock.acquireInOrder("))
        let addTask = try XCTUnwrap(fleet.range(of: "addTask {"))
        XCTAssertLessThan(acquire.lowerBound, addTask.lowerBound)
    }

    /// `--fleet` は素の経路と `--split` の2つが子を起こすので、どちらも取り切ること
    func testBothFleetPathsPrelock() throws {
        let text = try source("Sources/fleetest/FleetRunner.swift")
        XCTAssertEqual(text.components(separatedBy: "prelock.acquireInOrder(").count - 1, 2,
                       "--fleet と --fleet --split のどちらかが取り切っていない")
    }

    /// 子を起こす2経路が印を渡していること(渡さなければ親が握ったロックを子が待つ)
    func testBothSpawnSitesForwardTheHandoffMarker() throws {
        for path in ["Sources/fleetest/ApiRunMachineFanout.swift", "Sources/fleetest/FleetRunner.swift"] {
            let text = try source(path)
            XCTAssertTrue(text.contains("lockHeldTarget: lockMarker"),
                          "\(path): 子の環境に印が載っていない")
        }
    }
}
