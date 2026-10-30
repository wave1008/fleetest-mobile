// MCPServer+BridgeRecovery.swift
// MCP が長く駆動する xcuitest ブリッジ(シミュレータ)の死亡からの自動復帰と、劣化の測り直し。
// 本体は MCPServer.swift。
//
// 実地(B1): 3時間生きたランナーが a11y 照会の劣化の末に自壊し(ポートに何も応答しなくなり
// 台帳も消える)、以後そのセッションは connectionLostHint の案内(`fleetest bridge up` を打て)を
// 返すだけで、誰も打たないので二度と戻らなかった。ライブ操作(LiveBridgeAutoStarter)は同じ事象を
// 自動起動で凌ぐので、MCP にも同じ復帰を持たせる。**起動し直しは BridgeProvisioner.provision の1箇所**
// (`fleetest bridge up` / run の供給と同じ経路。二つ目の実装を書かない)。
//
// **対象はシミュレータの xcuitest ブリッジだけ**(RunnerMidRunRecheck.target と同じ絞り込み):
// inapp-boost モード/in-app ブリッジは起動し直しの単位が違う(対象アプリごと落ちる)・実機は provision() の対象外。
// それ以外の接続は connectionLostHint の案内だけに落ちる(退化ではなく対象外なだけ)。
//
// **入口は 2 つ**: ①覚えたポートの接続拒否(`dispatchRetryingAfterBridgeRecovery`)②udid の畳み込みで「その Simulator に
// 何も待ち受けていない」(`rebuildMissingSimulatorBridge`。`portForIOS` から)。udid を毎回添える呼び手は①を踏まない
// (走査が先に「no running bridge」で落ちる)ので、②が無いとランナーが死んだ瞬間からそのセッションは二度と戻らない
// (10/18 の負荷テスト: ランナーを殺した後の 5 分で 300 回)。どちらも provision は BridgeProvisioner.provision の 1 箇所。

import Foundation
import FTBridgeClient
import FTCore

extension MCPServer {

    /// dispatch の薄いラッパー。`DriverError.bridgeConnectionRefused` を受け、起動し直せる条件が
    /// 揃っていれば1回だけブリッジを起動し直して撃ち直す。起動し直せなければ元のエラーをそのまま
    /// 投げ、呼び出し元(call の catch)の connectionLostHint 等へ委ねる——文言・記憶の後始末を
    /// ここで重複して持たない
    /// 起動し直したことを**結果本文の先頭に載せる**(既存の注記と同じ前置の形)。
    /// stderr だけに出すと **JSON-RPC しか読まない呼び手には届かない** ——
    /// T1 の「唯一の警告が stderr」と同じ型。この呼び出しが数分かかった理由も、
    /// 「同じポートで別のランナーに変わった」ことも、ここにしか現れない
    static let bridgeRebuiltNote =
        "⚠️ the xcuitest bridge on this device had died (nothing was listening) and was rebuilt"
        + " before this call ran. Every ref from an earlier ft_snapshot is gone — take a fresh one."
        + " " + appStateNotChecked

    /// 起動し直したのはランナーだけ。provision はアプリを起動しない(実測: アプリの pid は前後で不変・画面も入力値も残る)ので、
    /// 「アプリが起動し直された・画面が最初に戻った」とは言わない。アプリが生きていたかはここでは確かめていない
    static let appStateNotChecked =
        "Only the runner was restarted; whether the app under test is still running was not checked."
        + " If the screen is not what you expect, ft_launch with resume: true brings the app back without resetting its state."

    /// 畳み込みの中でランナーを起動し直した呼び出しの応答(成功なら先頭・失敗ならエラー文の先頭)に載せる
    /// (`bridgeRebuiltNote` と同じ理由で本文に出す。起動し直した直後の ref 操作が失敗した回こそ ref の消失を言う必要がある)
    static let bridgeStartedForUDIDNote =
        "⚠️ no xcuitest bridge was running on this simulator (nothing listened for its udid), so one was started"
        + " before this call ran. Every ref from an earlier ft_snapshot is gone — take a fresh one."
        + " " + appStateNotChecked

    func dispatchRetryingAfterBridgeRecovery(tool: String, args: [String: Any]) async throws -> [[String: Any]] {
        do {
            return try await dispatch(tool: tool, args: args)
        } catch {
            guard await attemptXCUITestBridgeRecovery(args: args, error: error) else { throw error }
            let content = try await dispatch(tool: tool, args: args)
            return [["type": "text", "text": Self.bridgeRebuiltNote]] + content
        }
    }

    /// **純粋関数**: xcuitest ブリッジの自動での起動し直しを試すかの判定材料を1箇所にまとめる
    /// (I/O 抜きでテストできる。attemptXCUITestBridgeRecovery が I/O 込みで呼ぶ)。
    /// このセッションで一度失敗した sessionKey は再挑戦しない(`bridgeRecoveryFailed`。1回のビルド
    /// 失敗に分単位を払う経路なので、環境そのものが壊れているデバイスへ毎呼び出し撃ち続けない ——
    /// LiveBridgeAutoStarter.maxConsecutiveFailures と同じ「無限リトライにしない」規律だが、
    /// MCP は1呼び出しで完結するので上限は1回で足りる)。実機は provision() の対象外。
    /// **他のセッション(run・別の MCP)が使っているデバイスには撃たない**(`heldByAnotherSession` =
    /// `RunnerAccessibilityHealth.hasForeignLease`)—— 起動し直すのはそのデバイスのランナーなので、
    /// run が引き取ったデバイスでは run のレーンを落とす。引数に既定値を置かない = 呼び手の渡し忘れを止める
    static func shouldAttemptXCUITestBridgeRecovery(
        isConnectionRefused: Bool, bridge: String?, alreadyFailedThisSession: Bool, isPhysical: Bool?,
        heldByAnotherSession: Bool
    ) -> Bool {
        guard isConnectionRefused, bridge == "xcuitest", !alreadyFailedThisSession,
              !heldByAnotherSession else { return false }
        return isPhysical == false
    }

    /// run-lease / 他の MCP セッションの印(自分と親の分は数えない)。判定は供給の門と同じ1箇所
    static func heldByAnotherSession(udid: String, repoRoot: URL) -> Bool {
        RunnerAccessibilityHealth.hasForeignLease(
            udid: udid, stateDir: repoRoot.appendingPathComponent(".fleetest"))
    }

    static func skippedForAnotherSessionMessage(action: String, udid: String, port: UInt16) -> String {
        "not \(action) the xcuitest bridge on port \(port) for \(udid): another session (a fleetest run"
            + " or another MCP session) is using this device — restarting its runner would break that session"
    }

    /// 起動し直しの実行。判定は `shouldAttemptXCUITestBridgeRecovery` の1箇所(重複条件を書かない)。
    /// 成功時は `bridgeRecoveryFailed` へ insert しない——同じデバイスが後で再び死んだら、そのときはまた試してよい
    func attemptXCUITestBridgeRecovery(args: [String: Any], error: Error) async -> Bool {
        guard makeDriver == nil else { return false }
        let isConnectionRefused: Bool
        if case DriverError.bridgeConnectionRefused = error { isConnectionRefused = true }
        else { isConnectionRefused = false }
        let key = Self.sessionKey(args)
        guard let port = connectedPorts[key], let udid = udids[key] ?? nil,
              let repoRoot = try? RepoRoot.find() else { return false }
        let heldByAnotherSession = Self.heldByAnotherSession(udid: udid, repoRoot: repoRoot)
        guard Self.shouldAttemptXCUITestBridgeRecovery(
            isConnectionRefused: isConnectionRefused, bridge: bridges[key],
            alreadyFailedThisSession: BridgeRecoveryFailureLedger.blocksRetry(
                remembered: bridgeRecoveryFailed.contains(key), key: key),
            isPhysical: SimulatorCatalog.isPhysical(udid: udid), heldByAnotherSession: heldByAnotherSession)
        else {
            if isConnectionRefused, heldByAnotherSession {
                Self.logStderr("bridge recovery: " + Self.skippedForAnotherSessionMessage(
                    action: "rebuilding", udid: udid, port: port))
            }
            return false
        }
        SlowCallWatchdog.mark("rebuilding the xcuitest bridge on port \(port)")
        Self.logStderr("bridge recovery: port \(port) refused the connection — rebuilding the"
            + " xcuitest bridge for \(udid) and retrying the call once")
        let spec = DeviceSpec(name: udid, udid: udid, port: port, mode: "xcuitest")
        do {
            _ = try await BridgeProvisioner(repoRoot: repoRoot)
                .provision(devices: [(udid, spec)], log: Self.logStderr)
            Self.logStderr("bridge recovery: rebuilt the xcuitest bridge on port \(port) for \(udid)")
            return true
        } catch {
            bridgeRecoveryFailed.insert(key)
            BridgeRecoveryFailureLedger.record(key: key, detail: error.localizedDescription)
            Self.logStderr("bridge recovery: could not rebuild the xcuitest bridge on port \(port)"
                + " for \(udid) (\(error.localizedDescription)) — retried after"
                + " \(Int(BridgeRecoveryFailureLedger.retryCooldownSeconds))s")
            return false
        }
    }

    /// **純粋関数**: udid の畳み込みで「Simulator に何も待ち受けていない」とき、そのランナーを起動し直すかの判定材料
    /// (`shouldAttemptXCUITestBridgeRecovery` と同じ門: このセッションで一度失敗したら再挑戦しない・他のセッションの端末には撃たない。
    /// 実機は `portForIOS` が `.physical` へ分けるのでここへ来ない)。`lookup` が Simulator と言い切れ、診断が完走して何も
    /// 待ち受けていないときだけ。busy・固まり・答えたが確かめられない・予算切れ・一覧が読めないは「居ない」ではない
    static func shouldRebuildMissingSimulatorBridge(
        lookup: SimulatorCatalog.UDIDLookup, nothingListens: Bool, alreadyFailedThisSession: Bool,
        heldByAnotherSession: Bool
    ) -> Bool {
        guard nothingListens, lookup == .simulator, !alreadyFailedThisSession, !heldByAnotherSession else { return false }
        return true
    }

    /// 畳み込み(`portForIOS`)から。その udid の xcuitest ランナーを起動し直し、ポートを返す(起動し直さない・できないは nil)。
    /// `sessionKey` は畳む前の sessionKey(port 無し)= 失敗の記憶を置く DeviceSession の鍵(中身は udid ごと)。
    /// 起動し直したことの注記は呼び手(call)がその呼び出しの中だけで持つ(成功・失敗のどちらの応答にも載せる・次の呼び出しへ持ち越さない)
    func rebuildMissingSimulatorBridge(udid: String, diagnosis: UDIDBridgeDiagnosis, sessionKey: String) async -> UInt16? {
        guard makeDriver == nil, let repoRoot = try? RepoRoot.find() else { return nil }
        let heldByAnotherSession = Self.heldByAnotherSession(udid: udid, repoRoot: repoRoot)
        guard Self.shouldRebuildMissingSimulatorBridge(
            lookup: diagnosis.lookup, nothingListens: Self.nothingListensFor(diagnosis),
            alreadyFailedThisSession: BridgeRecoveryFailureLedger.blocksRetry(
                remembered: sessions[sessionKey]?.simulatorBridgeRebuildFailedUDIDs.contains(udid) ?? false, key: udid),
            heldByAnotherSession: heldByAnotherSession)
        else {
            if heldByAnotherSession {
                Self.logStderr("bridge recovery: not starting an xcuitest bridge for \(udid): another session (a fleetest run"
                    + " or another MCP session) is using this device")
            }
            return nil
        }
        SlowCallWatchdog.mark("starting the xcuitest bridge for \(udid) (nothing was listening)")
        Self.logStderr("bridge recovery: nothing listens for \(udid) — starting its xcuitest bridge and resolving the call again")
        let spec = DeviceSpec(name: udid, udid: udid, mode: "xcuitest")
        do {
            guard let provisioned = try await BridgeProvisioner(repoRoot: repoRoot)
                .provision(devices: [(udid, spec)], log: Self.logStderr).first else {
                sessions[sessionKey, default: DeviceSession()].simulatorBridgeRebuildFailedUDIDs.insert(udid)
                BridgeRecoveryFailureLedger.record(key: udid, detail: "provisioning returned no bridge")
                Self.logStderr("bridge recovery: provisioning returned no bridge for \(udid) — retried after"
                    + " \(Int(BridgeRecoveryFailureLedger.retryCooldownSeconds))s")
                return nil
            }
            Self.logStderr("bridge recovery: started the xcuitest bridge on port \(provisioned.port) for \(udid)")
            return provisioned.port
        } catch {
            sessions[sessionKey, default: DeviceSession()].simulatorBridgeRebuildFailedUDIDs.insert(udid)
            BridgeRecoveryFailureLedger.record(key: udid, detail: error.localizedDescription)
            Self.logStderr("bridge recovery: could not start the xcuitest bridge for \(udid)"
                + " (\(error.localizedDescription)) — retried after"
                + " \(Int(BridgeRecoveryFailureLedger.retryCooldownSeconds))s")
            return nil
        }
    }

    /// **純粋関数**: xcuitest ランナーの測り直しを撃つかの判定材料(ブリッジ・実機の絞り込みは RunnerMidRunRecheck.target と同じ)と、
    /// **他のセッションが使っているデバイスを除くこと**(`heldByAnotherSession`。起動し直すのはそのセッションのランナー。
    /// run 自身は RunnerMidRunRecheck で自分のレーンを測り直す)。**所要の門は持たない** —— 撃つのは起動の入口だけで、
    /// そこでは常に1問(健全なら 0.1〜0.2s)測る
    static func shouldAttemptXCUITestRunnerRecheck(
        bridge: String?, isPhysical: Bool?, injected: Bool, heldByAnotherSession: Bool
    ) -> Bool {
        guard bridge == "xcuitest", isPhysical == false, !heldByAnotherSession else { return false }
        return true
    }

    /// **ft_launch / ft_clear_app_data の入口で**、そのデバイスのランナーを1問測り、劣化していれば SpringBoard とランナーを
    /// 起こし直す(`BridgeProvisioner.recheckRunner` = run の RunnerMidRunRecheck と同じ経路)。
    /// **入口だけで撃つ**(ユーザー決定): 起こし直しは前面のアプリも落とすので、探索の途中(遅い呼び出しの直後)に撃つと
    /// 探っていた画面が消える。起動の入口ならどうせアプリを起動し直す。戻り値は応答に添える1行(何もしなければ空)
    func recheckXCUITestRunnerBeforeLaunch(args: [String: Any]) async -> String {
        guard makeDriver == nil else { return "" }
        let key = Self.sessionKey(args)
        guard let port = connectedPorts[key], let udid = udids[key] ?? nil,
              let repoRoot = try? RepoRoot.find() else { return "" }
        let injected = RunnerAccessibilityHealth.injectedSlowPorts().contains(port)
        let heldByAnotherSession = Self.heldByAnotherSession(udid: udid, repoRoot: repoRoot)
        guard Self.shouldAttemptXCUITestRunnerRecheck(
                  bridge: bridges[key], isPhysical: SimulatorCatalog.isPhysical(udid: udid),
                  injected: injected, heldByAnotherSession: heldByAnotherSession)
        else {
            if heldByAnotherSession {
                Self.logStderr(Self.skippedForAnotherSessionMessage(
                    action: "rechecking/restarting", udid: udid, port: port))
            }
            return ""
        }
        SlowCallWatchdog.mark("checking the simulator's SpringBoard before launching")
        let result = await BridgeProvisioner(repoRoot: repoRoot).recheckRunner(
            name: udid, udid: udid, port: port, injected: injected, log: Self.logStderr)
        switch result.outcome {
        case .healthy, .unmeasured, .skipped:
            return ""
        case .restarted(let afterSeconds):
            let before: String
            if case .answered(let seconds) = result.probe { before = String(format: "%.1fs", seconds) } else { before = "slow" }
            let now = afterSeconds.map { String(format: "%.2fs", $0) } ?? "not measured"
            return "note: this simulator's SpringBoard was slow (a system-alert query took \(before); normal is under"
                + " 0.3s, and every tap pays it), so SpringBoard and the XCUITest bridge were restarted before"
                + " continuing (now \(now)).\n"
        case .restartDidNotHelp:
            return "note: this simulator's SpringBoard is slow (a system-alert query takes over 2s; every tap pays it)"
                + " and restarting SpringBoard did not help — rebooting the simulator is the next thing to try.\n"
        case .unusable(let waited):
            return "note: this simulator's SpringBoard did not answer a system-alert query within \(Int(waited.rounded()))s"
                + " even after SpringBoard and the XCUITest bridge were restarted — reboot the simulator"
                + " (`fleetest api wipe-device --platform ios --udid \(udid)` erases it).\n"
        case .restartFailed(let reason):
            Self.logStderr("⚠️ \(udid): could not restart SpringBoard / the xcuitest bridge on port \(port) (\(reason))")
            return ""
        }
    }
}

/// 自動の起動し直しの失敗の控え(事実だけ: いつ・何と言って失敗したか)。プロセス内の台帳で、鍵は
/// 接続拒否の入口が sessionKey・udid の畳み込みの入口が udid。
/// **失敗を永久に覚えない**: 失敗の原因が一時的な衝突(空きに見えたポートを run の in-app ブリッジに取られた等)でも
/// 「このセッションでは再挑戦しない」が MCP の寿命いっぱい続き、全ツールが「no running bridge」を返し続けた。
/// 一方で環境そのものが壊れている端末へ呼び出しごとに分単位のビルドを撃たない規律は残す —— 間隔を空けて再挑戦する。
enum BridgeRecoveryFailureLedger {
    struct Entry { let at: Date; let detail: String }
    private static let entries = LockedValue<[String: Entry]>([:])

    /// 失敗の後に次の再挑戦を許すまでの間隔[秒]。根拠: 同じ型の失敗の再生を持つ Android ブリッジの失敗キャッシュ
    /// (`AndroidDriver.unavailableRetryInterval` = 60)と揃える。失敗1回のコストは起動の待ちを含め数十秒〜分なので、
    /// 呼び出しごとの再挑戦(嵐)は防ぎつつ、分単位で待たされない長さ
    static let retryCooldownSeconds: TimeInterval = 60

    static func record(key: String, detail: String, now: Date = Date()) {
        entries.withLock { $0[key] = Entry(at: now, detail: detail) }
    }

    static func entry(key: String) -> Entry? { entries.withLock { $0[key] } }

    /// 失敗の記憶が再挑戦をまだ止めるか。記憶が無ければ止めない。記憶が有って控えが無い(控えより前に立った旗)は止める。
    /// 控えが有れば間隔の間だけ止める
    static func blocksRetry(remembered: Bool, key: String, now: Date = Date()) -> Bool {
        guard remembered else { return false }
        guard let entry = entry(key: key) else { return true }
        return now.timeIntervalSince(entry.at) < retryCooldownSeconds
    }

    /// 「no running bridge」へ添える1文。止めている間だけ(間隔を過ぎた失敗は次の呼び出しで再挑戦されるので言わない)
    static func note(key: String, now: Date = Date()) -> String {
        guard let entry = entry(key: key), now.timeIntervalSince(entry.at) < retryCooldownSeconds else { return "" }
        let ago = max(0, Int(now.timeIntervalSince(entry.at).rounded()))
        return " An automatic restart of its XCUITest bridge was tried \(ago)s ago and failed: \(entry.detail)."
            + " It is tried again automatically after \(Int(retryCooldownSeconds))s."
    }
}
