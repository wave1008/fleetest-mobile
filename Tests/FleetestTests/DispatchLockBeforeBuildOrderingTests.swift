// D4: 複数機械にまたがる run(`fleetest run` の DeviceMachineRunner / `fleetest api run` の
// ApiRunMachineFanout)は、この Mac の dispatch.lock を**ローカルの build/シナリオ一覧取得より前**に
// 一時的に取る(規律③「取るのは run の入口(ビルドにもデバイスにも触る前)」= build の直列化)。
// 後ろだと、build + 配分にかかる時間ぶんロックが空いて見え、他の run と重い swift build が並走する
// (実測 07:32:09〜07:32:35)。
//
// **ただし全順序どおりの本取得(local 含む)は `DispatchPrelock.acquireInOrder` が配分確定後に
// 改めて行う** —— local の早取りを「取得済み」として `DispatchPrelock` の取得を飛ばすと、
// local だけ全順序の外に出て循環待ちを構造的に作れてしまう(RR-18.10)。
// 早取りしたロックは配分確定直後に無条件で手放し、待機列の**チケットだけ**を build 前の epoch で
// 発行しておく(FIFO の公平性を保ったまま、ロック本体の全順序は動かさない)。
//
// **この経路は緑の run では1度も実行されない**(競合が起きないと早取りの効果は観測できない)ので、
// ソース走査で呼び出しの順序・不変条件を固定する(RunCompletionSweepWiringTests と同じ流儀)。

import Foundation
import XCTest
@testable import fleetest

final class DispatchLockBeforeBuildOrderingTests: XCTestCase {

    /// 前段は MachineFanoutFrontHalf の1箇所。順序はその `run` の中で固定され、build は呼び手の差分(`build` の呼び出し)
    private static let sources = ["Sources/fleetest/MachineFanoutFrontHalf.swift"]
    private static let fanouts = [
        "Sources/fleetest/DeviceMachineRunner.swift",
        "Sources/fleetest/ApiRunMachineFanout.swift",
        "Sources/fleetest/MultiTargetRunner.swift",
    ]
    private static let buildCall = "try build("

    /// 3経路は前段の `run` に build を渡すだけ —— ロック・チケット・Prelock を自前で作らない(手書きの写しに戻さない)。
    /// ビルドは前段の `run` の呼び出しの内側(= ロックを握った後)に書く
    func testThreeFanoutsDelegateTheFrontHalf() throws {
        for path in Self.fanouts {
            let text = try Self.source(path)
            let run = try XCTUnwrap(text.range(of: "MachineFanoutFrontHalf.run("), "\(path): 前段を通っていない")
            let build = try XCTUnwrap(text.range(of: "ScenarioHost.build("), "\(path): ScenarioHost.build が無い")
            XCTAssertLessThan(run.lowerBound, build.lowerBound, "\(path): ビルドが前段の外(ロックの前)にある")
            for owned in ["LocalDispatchLock(", "DispatchTicketIssuer.issue(", "DispatchPrelock(", "RunRecorder.makeRunGroupID("] {
                XCTAssertFalse(text.contains(owned), "\(path): 前段の持ち物 \(owned) を自前で作っている")
            }
        }
    }

    func testTheLocalDispatchLockIsAcquiredBeforeTheLocalBuildAndScenarioList() throws {
        for path in Self.sources {
            let lines = try Self.codeLines(path)
            guard let lockLine = lines.firstIndex(where: { $0.contains("LocalDispatchLock(") }) else {
                return XCTFail("\(path): ローカルの dispatch.lock 取得が見当たらない")
            }
            guard let buildLine = lines.firstIndex(where: { $0.contains(Self.buildCall) }) else {
                return XCTFail("\(path): build 呼び出しが見当たらない")
            }
            XCTAssertLessThan(lockLine, buildLine, "\(path): dispatch.lock がビルド・一覧取得の後に取られている")
        }
    }

    /// 待機列のチケット(`DispatchTicketIssuer.issue`)も build より前に発行する ——
    /// 早取りしたロックを配分確定後に手放しても、このチケットが build 前の epoch を持つ限り、
    /// build 中に列へ並んだ別 run より自分が先に並んでいたことを FIFO が忘れない
    func testTheDispatchTicketIsIssuedBeforeTheLocalBuild() throws {
        for path in Self.sources {
            let lines = try Self.codeLines(path)
            guard let issueLine = lines.firstIndex(where: { $0.contains("DispatchTicketIssuer.issue(") })
            else {
                return XCTFail("\(path): DispatchTicketIssuer.issue 呼び出しが見当たらない")
            }
            guard let buildLine = lines.firstIndex(where: { $0.contains(Self.buildCall) }) else {
                return XCTFail("\(path): build 呼び出しが見当たらない")
            }
            XCTAssertLessThan(issueLine, buildLine,
                              "\(path): 待機チケットの発行がビルドの後(epoch が遅れて FIFO の公平性を失う)")
            // 発行しただけでは自分自身の再取得には効かない(LocalDispatchLock/RemoteRunDispatcher は
            // 環境変数からチケットを読む)。setenv で自分のプロセス環境へも書いていることを固定する
            XCTAssertTrue(lines.contains { $0.contains("setenv(DispatchTicket.environmentKey") },
                          "\(path): 発行したチケットをプロセス環境へ書いていない(取り直しで epoch が新しくなる)")
        }
    }

    /// 恒久固定: local を「取得済み」扱いにして `DispatchPrelock` の実取得を飛ばす口
    /// (差し戻した `preacquiredLocal` のような形)を二度と作らない。local 分岐は
    /// **必ず** `LocalDispatchLock(...).acquire()` を呼んでから応答する(呼ぶ前に return しない)
    func testDispatchPrelockNeverSkipsTheRealLocalAcquire() throws {
        let text = try Self.source("Sources/fleetest/DispatchPrelock.swift")
        guard let acquireClosureStart = text.range(of: "acquire: { machine in")?.upperBound else {
            return XCTFail("acquire クロージャが見当たらない")
        }
        guard let elseStart = text.range(
            of: "guard !MachineDispatch.isExplicitLocal(machine.machine) else {",
            range: acquireClosureStart..<text.endIndex
        )?.upperBound else {
            return XCTFail("acquire クロージャの local 分岐(isExplicitLocal else)が見当たらない")
        }
        guard let afterBlock = text.range(
            of: "let target = try dispatcher(for: machine)", range: elseStart..<text.endIndex
        )?.lowerBound else {
            return XCTFail("local 分岐の終わり(次の非 local 経路)が見当たらない")
        }
        let body = String(text[elseStart..<afterBlock])
        let codeOnly = body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)[0] }
            .joined(separator: "\n")
        guard let acquireCallRange = codeOnly.range(of: "let local = LocalDispatchLock(") else {
            return XCTFail("local 分岐が実際のロック取得(LocalDispatchLock)を呼んでいない: \(codeOnly)")
        }
        let beforeAcquireCall = codeOnly[codeOnly.startIndex..<acquireCallRange.lowerBound]
        XCTAssertFalse(beforeAcquireCall.contains("return"),
                       "LocalDispatchLock を呼ぶ前に return している(取得を飛ばす経路がある): \(beforeAcquireCall)")
    }

    /// コメント行を除き、前後の空白を落としたソース行
    private static func codeLines(_ path: String) throws -> [String] {
        let text = try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("//") ? "" : trimmed
        }
    }

    private static func source(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}
