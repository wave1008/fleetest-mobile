// MCPServer+SessionTools.swift
// セッション・端末・アプリの管理系ツール(status / list_* / logs / install / launch / open_url / terminate / clear_app_data / doctor)。入口の振り分けは MCPServer+Dispatch.swift の dispatch

import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore

extension MCPServer {

    func ftStatus(_ args: [String: Any]) async throws -> [[String: Any]] {
        // **読み取り専用のここだけは、複数台でも失敗させない**(外部フィードバック)。
        // 操作系(tap/type/…)はエラーのままにする —— 曖昧なまま「どれか」を操作させない
        // 規律([[BridgeDiscovery]] と同じ)を崩さないため。status は状態を見るだけなので、
        // 全台を並べて返すほうが次の一手(serial: を選ぶ)に直結する
        if args["profile"] == nil, args["serial"] == nil,
           (args["platform"] as? String) == "android",
           case .ambiguous(let devices) = AndroidSerialResolver.decide(
               explicit: nil, connected: AndroidSerialResolver.connectedSerials()) {
            return text(await Self.androidFleetStatus(devices.map(\.serial)))
        }
        let status = try await driver(args).status()
        // **宛先とセッションの意味まで出す**: 「どこに繋がっているか」が見えないと、
        // 既定ポートの死・はぐれデバイスの誤掴み・ブリッジ再起動によるセッション消失が
        // どれも「応答はしているのに操作できない」に見える(フィードバック #2/#8)
        let statusKey = Self.sessionKey(args)
        // **同じシミュレータに in-app / XCUITest が同時に立つのが常態**(実アプリ
        // 監査: 10台に対し稼働ブリッジ17本)。どちらに繋がっているかで scrollable 検知・
        // キーボード遮蔽・型語彙・読み返しの有無が変わるので、宛先と一緒に出す。
        // **走査は増やさない** — driver(args) が解決時に埋めた bridges[key] を読むだけ
        // (android は platform で既に分かっているので冗長・出さない)
        let bridgeSuffix = bridges[statusKey].flatMap { $0 == "android" ? nil : " bridge: \($0)" } ?? ""
        let endpoint = connections[statusKey].map { " @ \($0)\(bridgeSuffix)" } ?? ""
        let session = status.sessionBundleID
            ?? "none (no app attached — ft_launch <bundleId> first;"
                + " a bridge restart clears the session)"
        // **session と「いま前面にあるもの」は別物**(外部フィードバック)。
        // session はブリッジが掴んでいるアプリで、ft_navigate home の後も変わらない。
        // 前面の照会は 1 往復で済むので、シナリオ冒頭の appIs 相当をここで賄えるようにする
        // **session がこのセッションの起動したアプリと違うなら、前面が「yes」でも別のアプリ**(Android はアプリが死ぬと
        // ブリッジの session が下から出たアプリへ付け替わり、`foregroundNote` は付け替え後の session を前面と照合して yes と答えていた。
        // ft_snapshot の「NOT the app you launched」と同じ事実を言う)
        let foreground: String
        if let launched = launchedBundleIDs[statusKey], let current = status.sessionBundleID, current != launched {
            foreground = " / foreground: no (the session now points at \(current), not \(launched), the app this session"
                + " launched — \(launched) may have crashed or been left; ft_snapshot says which, ft_launch \(launched) to come back)"
        } else if let covering = try? await driver(args).systemUICovering(), covering.covering,
                  covering.marker == "SBCoverSheetWindow" {
            // iOS(XCUITest ブリッジだけが答える): 端末がロックされている・通知センターが降りている間は、アプリは
            // 前面のまま木に答えるか、`/appstate` が false を返す。どちらも「別のアプリかホーム画面」とは言えない
            foreground = " / foreground: no (the lock screen or the notification centre is drawn over the app —"
                + " unlock the device or dismiss it, then ft_launch the bundleId with resume: true if the app is not back)"
        } else {
            foreground = await Self.foregroundNote(status.sessionBundleID, driver: try await driver(args))
        }
        return text(withPendingWarnings(
            "ready: \(status.ready) / \(status.device) (\(status.osVersion))\(endpoint)"
            + " / session: \(session)\(foreground)\(await Self.fmLivenessNote())", args: args))
    }

    func ftListDevices(_ args: [String: Any]) async throws -> [[String: Any]] {
        let listProject = args["project"] as? String
        let listProfile = args["profile"] as? String
        let listPlatform = args["platform"] as? String
        // **鍵は見出しが実際に組まれる回だけ消費する**(onceNonEmpty と同じ理由)。
        // devicesText 側の `abbreviated` クロージャに遅延評価させる — ここで同じ判定を
        // 先読みすると、once 系の鍵をここでも消費する二重実装になる。
        // **鍵は理由込み**(欠陥⑥): 理由に依存しない鍵だと、原因を直した後の呼び出しまで
        // 「初回に言った理由」として畳まれ、直ったかどうかを読む手段が消える
        return text(await DeviceInventory.devicesText(
            project: listProject, profile: listProfile, platform: listPlatform,
            abbreviated: { reason in !self.firstTime("machineProfileFallback:\(reason)") }))
    }

    func ftListApps(_ args: [String: Any]) async throws -> [[String: Any]] {
        // driver() を先に通す: profile 指定の解決(provision)と udids の記録がここで済み、
        // 直指定でも同じ宛先選択規則に乗る
        let appsDriver = try await driver(args)
        let appsFilter = (args["filter"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // **filter を渡したら既定で system も探す**: 絞り込む唯一の動機は「あのアプリを
        // 見つける」ことで、端末に載っている地図・ブラウザは system 側に居る。既定のままだと
        // 「入っていない」という誤った空振りになる(実測して adb へ落ちた)。
        // 明示の includeSystem: false は尊重する
        let includeSystem = args["includeSystem"] as? Bool ?? (appsFilter != nil)
        if let android = appsDriver as? AndroidDriver {
            return text(DeviceInventory.appsText(
                packages: try android.listPackages(includeSystem: includeSystem)
                    .filter { !BridgeSelfApps.isBridgeItself($0.id) },
                includeSystem: includeSystem, filter: appsFilter))
        }
        let deviceName = try await appsDriver.status().device
        let appsKey = Self.sessionKey(args)
        // **実機判定をシミュレータへの素通し(bootedSimulatorUDID)より先にする**(欠陥①):
        // 実機の /status は device に機種名("iPhone")しか返さず SIMULATOR_UDID も持たないので、
        // bootedSimulatorUDID は udid の出所がどこであれ必ず throw する。候補 udid を先に
        // 揃えてから実機かどうかを確かめ、実機でなければ初めてシミュレータ側へ素通しする。
        //
        // 候補 udid の3段は iosTargetUDID の doc
        let candidateUDID = iosTargetUDID(key: appsKey, args: args)
        // **実機は simctl ではなく devicectl**(欠陥⑤): udid の形はどちらも同じなので、
        // simctl へ素通しすると "Invalid device" で失敗する。実機かどうかは
        // IOSPhysicalDeviceCatalog の一覧に居るかで判定する(判定できなければ
        // シミュレータ側の通常の経路へ素通し = 断定しない側に倒す)
        if let candidateUDID,
           let physicalDevices = try? IOSPhysicalDeviceCatalog.devices(),
           physicalDevices.contains(where: { $0.udid == candidateUDID || $0.deviceCtlIdentifier == candidateUDID }) {
            let apps = try IOSPhysicalAppCatalog.apps(udid: candidateUDID)
            return text(DeviceInventory.renderAppLines(
                apps.filter { !BridgeSelfApps.isBridgeItself($0.id) }
                    .map { DeviceInventory.AppRow(id: $0.id, name: $0.name, isUser: $0.isUser) },
                includeSystem: includeSystem, filter: appsFilter, systemAppsCounted: true))
        }
        let udid = try candidateUDID ?? SimulatorAppCatalog.bootedSimulatorUDID(named: deviceName)
        return text(DeviceInventory.appsText(apps: try SimulatorAppCatalog.apps(udid: udid)
                                                .filter { !BridgeSelfApps.isBridgeItself($0.id) },
                                             includeSystem: includeSystem, filter: appsFilter))
    }

    /// ft_logs の実機判定(純粋関数)。`udid` を渡された回は**その udid の記録だけ**を実機の証拠にする ——
    /// 解決したポートの記録が別の実機のものなら採らない(ポートは別のデバイスへ使い回される)
    static func logsPhysicalUDID(udid: String?, recordAtPort: String?,
                                 isRecordedAnywhere: (String) -> Bool) -> String? {
        guard let udid else { return recordAtPort }
        return recordAtPort == udid || isRecordedAnywhere(udid) ? udid : nil
    }

    func ftLogs(_ args: [String: Any]) async throws -> [[String: Any]] {
        let isIOS = Self.platformName(args) == "ios"
        // **udid はここで解決する**(入口の畳み込みはブリッジを走査するので撃たない =
        // toolsResolvingUDIDWithoutBridge)。udid を毎回添える呼び手の鍵は `direct:ios:0:` になり、
        // 駆動中のセッション(鍵はポート入り)の記憶をどれも引けない —— 覚えているポートを載せて揃える
        let logsUDID = isIOS ? try Self.stringArgument(args, "udid") : nil
        let args = Self.injectingPort(
            args, port: try Self.portArgument(args) == nil ? rememberedPort(forUDID: logsUDID) : nil)
        let logBundleID = try Self.stringArgument(args, "bundleId", emptyHint: Self.attachedAppEmptyHint)
            ?? lastLaunchedBundleID(args)
        // iOS のクラッシュレポートはアプリ単位でしか引けない。本文で返すと isError=false になり、
        // 呼び手は「クラッシュ無し」と区別できない
        if Self.platformName(args) == "ios", logBundleID == nil {
            throw MCPError("bundleId is required on iOS — crash reports are looked up per app, and no"
                + " app was launched in this session. Pass bundleId")
        }
        // **ブリッジには一切問い合わせない**(CrashLogs の存在理由はまさにブリッジごと
        // 落ちた直後に使うこと)。唯一のブリッジ非依存な実機の手掛かりは
        // `.fleetest/bridge-<port>.device`(BridgeDeviceRecord。実機のときだけ書かれる)で、
        // port は明示引数かこのセッションが覚えている宛先(connectedPorts。driver() を経由した
        // 呼び出しで埋まる)から取る。**どちらも取れなければ nil = 実機でない証拠にはならない
        // ので待つ**(best-effort)
        let logsPort = try Self.portArgument(args) ?? connectedPorts[Self.sessionKey(args)]
        let repoRoot = try? RepoRoot.find()
        let logsPhysicalUDID = Self.platformName(args) == "ios"
            ? Self.logsPhysicalUDID(
                udid: logsUDID,
                recordAtPort: logsPort.flatMap { port in
                    repoRoot.flatMap { BridgeDeviceRecord.load(port: port, repoRoot: $0) }
                },
                isRecordedAnywhere: { udid in
                    repoRoot.map { BridgeDeviceRecord.isRecorded(udid: udid, repoRoot: $0) } ?? false
                })
            : nil
        return text(await CrashLogs.text(
            platform: Self.platformName(args),
            bundleID: logBundleID,
            serial: args["serial"] as? String,
            withinSeconds: try Self.intArgument(args, "sinceSeconds") ?? Self.logsDefaultSinceSeconds,
            maxLines: try Self.intArgument(args, "lines") ?? Self.logsDefaultLines,
            crashOnly: (args["all"] as? Bool) != true,
            physicalUDID: logsPhysicalUDID,
            simulatorUDID: logsPhysicalUDID == nil ? logsUDID : nil,
            // このセッションが起動したアプリのレポートなら、起動より前のものは今のプロセスのクラッシュではない
            launchedAt: logBundleID != nil && launchedBundleIDs[Self.sessionKey(args)] == logBundleID
                ? launchTimestamps[Self.sessionKey(args)] : nil))
    }

    func ftInstall(_ args: [String: Any]) async throws -> [[String: Any]] {
        let rawPackagePath = try Self.requiredStringArgument(args, "packagePath")
        // 相対パスはどの OS でも断る(MCP プロセスの cwd から解決される = 宛先に依らない)
        if let refusal = Self.relativePackagePathRefusal(rawPackagePath) { throw MCPError(refusal) }
        // **以降は `~` を展開したパスだけを使う**(devicectl / simctl / adb は `~` を展開しない。入れ直し元の控えにも
        // 展開後を置く = 後の ft_clear_app_data が読める)
        let packagePath = InstallPackagePath.expanded(rawPackagePath)
        let installKey = Self.sessionKey(args)
        let installDriver = try await driver(args)
        // **存在の確認は実機の iOS だけ**(devicectl の失敗は原因が出力の末尾にしか出ない。simctl / adb は先頭で言う)。
        // Simulator 用ビルドの断りは実機の install が必ず通る BridgeClient.install の1箇所(ここで重ねて読まない)
        if !(installDriver is AndroidDriver), await isPhysicalIOSDevice(key: installKey, args: args) {
            guard InstallPackagePath.exists(packagePath) else {
                throw MCPError("packagePath: package not found at \(packagePath)")
            }
        }
        let installNote = try await installDriver.install(packagePath: packagePath)
        // ft_clear_app_data が実機で uninstall+install に化けるときの再インストール元
        // (installedPackagePaths 参照)
        installedPackagePaths[installKey] = packagePath
        // インストール直後の初回起動で権限アラートが出ることがある(systemAlertProbePending 参照)
        systemAlertProbePending.insert(installKey)
        // **既に起動していたアプリの上書きインストールは、たいてい実行中のプロセスを止める**
        //。次の snapshot が switchedAppNote 経由で「クラッシュしたかも」と
        // 誤診しないよう、原因をこの操作へ帰属させておく(ft_launch で消える)
        var stoppedNote = ""
        if let launched = launchedBundleIDs[installKey] {
            toolStoppedBundleIDs[installKey] = "ft_install"
            // 入れ直したのがセッションのアプリなら、ランナーのセッションも畳む(残ると次の木が「落ちたかも(503)」と言う)。
            // パッケージの bundle ID が読めた iOS だけ(別アプリの install は走っているアプリを止めない)
            if !(installDriver is AndroidDriver),
               let installed = await ReinstallPackageCheck.bundleIDOffPool(path: packagePath), installed == launched {
                if (try? await installDriver.status())?.sessionBundleID == launched { try? await installDriver.terminate() }
                stoppedNote = "\nnote: \(launched) was running and the install replaced it — the app is stopped; ft_launch to continue"
            }
        }
        return text("Installed: \(packagePath)" + (installNote.map { "\n\($0)" } ?? "") + stoppedNote)
    }

    /// 相対パスの拒否(どの OS の ft_install も撃つ前に通す)。**スキーマ(packagePath: 絶対パス)に反する** ——
    /// MCP プロセスの cwd から解決されて別の場所を指す。`~` は展開してから見る。
    /// 存在の確認は実機の分岐だけ(devicectl へ直送すると原因が十数行の出力の末尾にしか出ない)
    static func relativePackagePathRefusal(_ raw: String) -> String? {
        guard !InstallPackagePath.expanded(raw).hasPrefix("/") else { return nil }
        return "packagePath must be an absolute path (got \(raw)) — a relative path would be resolved against"
            + " this MCP server's working directory, not yours."
    }

    /// ブリッジ自身(Android の ftbridge・iOS の XCUITest ランナー)は操作の対象にしない(`BridgeSelfApps`)。
    /// 起動・データ消去・終了はブリッジを自分で殺す(ホスト側で撃つ前に断る。ブリッジ側は触らない)
    static func bridgeSelfRefusal(tool: String, bundleID: String) -> String? {
        guard BridgeSelfApps.isBridgeItself(bundleID) else { return nil }
        return "\(bundleID) is fleetest's own bridge (the process this server drives the device through), not an app"
            + " under test — \(tool) on it would stop the bridge itself. Nothing was sent."
            + " Pass your app's bundle ID / package (ft_list_apps shows the installed apps)."
    }

    func ftLaunch(_ args: [String: Any]) async throws -> [[String: Any]] {
        resetOnceNotes(forScope: noteScope)   // 新しい探索の始まり = 初出の注記を数え直す(resetOnceNotes の doc)
        let bundleID = try Self.requiredStringArgument(args, "bundleId")
        if let refusal = Self.bridgeSelfRefusal(tool: "ft_launch", bundleID: bundleID) { throw MCPError(refusal) }
        let launchKey = Self.sessionKey(args)
        let launchDriver = try await driver(args)
        let springBoardNote = await recheckXCUITestRunnerBeforeLaunch(args: args)
        let resumes = args["resume"] as? Bool == true
        // **撃つ前に弾く**(ランナー死の予防。installedVerdict/launchGuardDecision のコメント参照)。
        // 段を切らないと在否の確認と起動の時間が直前の SpringBoard の確認に積まれる(実測: 確認 0.17s が 4.7s と出た)
        SlowCallWatchdog.mark("checking the app is installed")
        let installVerdict = await installedVerdict(bundleID: bundleID, driver: launchDriver, args: args)
        if let refusal = Self.launchGuardDecision(
            verdict: installVerdict, isAndroid: launchDriver is AndroidDriver,
            bridge: bridges[launchKey], bundleID: bundleID) {
            throw MCPError(refusal)
        }
        // 確かめられないまま撃つ経路(Android・in-app)は記録に残す
        if case .unknown(let reason) = installVerdict {
            Self.logStderr(Self.uncheckedNote(bundleID: bundleID, reason: reason))
        }
        // resume は「走っているアプリを前面へ戻す」約束。止まっていれば activate は新規起動になる(XCUIApplication.activate は
        // 未起動なら起動する)ので、**撃つ前に走っていたか**を見て文言と下書きの記録を分ける
        // **SpringBoard への ft_launch は attach**(何も起動しない)= 起動の記録・「走っていたか」の対象外
        let attachesToSpringBoard = bundleID == MCPServer.springboardBundleID
        let wasRunningBeforeResume: Bool? = resumes && !attachesToSpringBoard
            ? await appWasRunning(bundleID: bundleID, driver: launchDriver, key: launchKey, args: args) : nil
        let startedFresh = wasRunningBeforeResume == false
        SlowCallWatchdog.mark(resumes ? "activating the app" : "launching the app")
        if resumes {
            try await launchDriver.activate(bundleID: bundleID)
        } else {
            try await launchDriver.launch(bundleID: bundleID)
        }
        // 以後の snapshot は「これの木か」を突き合わせられる(switchedAppNote)
        launchedBundleIDs[launchKey] = bundleID
        launchTimestamps[launchKey] = Date()
        // 再起動した以上、以後の不在は今回の ft_clear_app_data/ft_install のせいではない
        toolStoppedBundleIDs[launchKey] = nil
        backgroundedByNavigate.remove(launchKey)
        // 次の ft_snapshot で一度だけ system alert を確かめる(systemAlertProbePending 参照)。
        // **springboard 自身への attach では立てない** —— そちらはアラートを読みに行く
        // 正規の経路そのものなので、覆いとして扱ってはいけない
        if !attachesToSpringBoard {
            systemAlertProbePending.insert(launchKey)
        }
        // 前面が入れ替わったので、古い木を起点にした覆い探針の記憶は使い回さない(F 節)
        lastScreenProbe[launchKey] = nil
        // 下書きの起点(F-3 の既定範囲は「直近の ft_launch 以降」)。
        // **resume は isLaunch を立てない** —— 立てると draft の既定スコープがここから始まり、
        // ScenarioCodeGen は scene 0 の condition に無条件で launchApp() を出すので、
        // 実際には状態を保ったまま activate しただけの手順が「新規起動」に化けて嘘になる
        recordAction(InteractionLog.Entry(
            step: nil, unresolved: nil, isLaunch: !attachesToSpringBoard && (!resumes || startedFresh), bundleID: bundleID,
            platform: launchDriver is AndroidDriver ? "android" : "ios",
            summary: !resumes ? "launch \(bundleID)"
                : startedFresh ? "launch \(bundleID) (resume asked, but it was not running)"
                // 走っていたかを確かめられなかった回は、返答と同じく断定しない
                : wasRunningBeforeResume == nil && !attachesToSpringBoard
                    ? "activate \(bundleID) (resume asked; whether it was already running could not be checked)"
                : "activate \(bundleID) (resumed, not relaunched)"), args: args)
        // snapshotAfter の読みは system alert の予約(上)を消費するので、立てた後に読む。
        // **操作前の木と比べない**(outsideTheAppTree: true): 起動し直しは前と同じ最初の画面に着くのが普通で、resume は背面から
        // 戻した木と前面だった頃の木を比べることになる。どちらも一致して「効かなかったかも」と出て、撃ち直しを誘っていた(実測)
        // SpringBoard は常に走っていて attach するだけ = 走っていたかを確かめない分の「起動し直したかも」を言わない
        return text(springBoardNote + (resumes && !attachesToSpringBoard
                                       ? Self.resumeSummary(bundleID: bundleID, wasRunning: wasRunningBeforeResume)
                                       : resumes ? "Activated: \(bundleID)" : "Launched: \(bundleID)")
            + waitForWithoutSnapshotAfterNote(args) + (await snapshotAfterBody(args, outsideTheAppTree: true)))
    }

    /// ft_launch resume: true の応答の1行目。**走っていたかで言い分けを変える**(止まっていたのに「relaunch せず」と言うと、
    /// 保たれていない状態を保たれたと読ませる)。nil = 確かめられなかった(断定しない)
    static func resumeSummary(bundleID: String, wasRunning: Bool?) -> String {
        switch wasRunning {
        case true?: return "Activated: \(bundleID) (resumed without relaunching)"
        case false?:
            return "Started: \(bundleID) was NOT running, so resume could not keep any state — activating it started it"
                + " fresh (a cold launch, same as ft_launch without resume)"
        case nil:
            return "Activated: \(bundleID) (could not check whether it was already running — if it was not, this"
                + " started it fresh and no earlier state was kept)"
        }
    }

    /// このデバイスの記録に、そのアプリの launch / 手があるか。**別の台で操作したアプリを「このセッションで操作した」と
    /// 言わない**(記録は台ごとに絞る = InteractionLog.scope)
    func appWasDrivenOnThisDevice(_ bundleID: String, args: [String: Any]) -> Bool {
        interactions.scope(all: true, device: draftDeviceKey(args)).contains { $0.bundleID == bundleID }
    }

    /// ft_terminate が XCUITest ランナーの 409(セッションが無い)を受けたときの文。**このセッションで起動したかで言い分ける** ——
    /// 起動していたのに「起動していない」と言うと、止めたいアプリを起動し直させる
    static func terminateNoSessionRefusal(bundleID: String, launchedHere: Bool) -> String {
        launchedHere
            ? "nothing to terminate: the XCUITest runner lost its session on \(bundleID), which was launched in this"
                + " session — the app may have crashed or been stopped already, or may still be running (the runner can lose"
                + " its session without the app stopping, and on a physical device this cannot be checked)."
                + " This session no longer tracks it, so ft_snapshot will not bring it back: ft_launch it if you need it again."
            : "nothing to terminate: the XCUITest runner has no session on \(bundleID) — it was not launched through"
                + " ft_launch in this session (or was already terminated). ft_launch it first if it is running and you need"
                + " to stop it."
    }

    /// この呼び出しの iOS の宛先 udid。候補は3段(先に見つかったもの): ①引数の `udid:` ②セッションの記憶(`udids[key]`。
    /// port: だけの呼び出しでは埋まらないことがある)③実機専用のポート記録(`.fleetest/bridge-<port>.device`。port: だけで
    /// 実機を指したときの唯一の手掛かり)。ft_list_apps・ft_install・resume の判定が共有する(別々に持つと port: だけの実機を片方だけ見落とす)
    func iosTargetUDID(key: String, args: [String: Any]) -> String? {
        (args["udid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? udids[key].flatMap { $0 }
            ?? connectedPorts[key].flatMap { port in
                (try? RepoRoot.find()).flatMap { BridgeDeviceRecord.load(port: port, repoRoot: $0) }
            }
    }

    /// udid → 実機か(答えが出た回だけ控える。udid の実機/Simulator はプロセスの生存中に変わらない)
    private static let physicalIOSUDIDMemo = LockedValue<[String: Bool]>([:])
    /// 実機の udid → インストール済みアプリの控え(resume の「走っていたか」用。`IOSPhysicalRunningApps.running` の doc =
    /// 一覧は滅多に変わらないので呼び手が控えを渡す)。入れ直しで実行ファイルのパスが変わりうるので、控えで「居ない」と
    /// 出た回だけ取り直して確かめる(`appWasRunning`)
    private static let physicalAppsMemo = LockedValue<[String: [IOSPhysicalAppCatalog.App]]>([:])

    /// この呼び出しの宛先が実機の iOS か。判らなければ false(断定しない側)。
    /// 実機の記録(`BridgeDeviceRecord`。実機の経路でだけ書かれる)があれば外部コマンドを撃たない。無ければ
    /// `SimulatorCatalog.isPhysical`(simctl の一覧を先に見る = Simulator なら devicectl を撃たない。どちらも同期の外部コマンド
    /// → 協調プールの外)に訊き、答えが出たら udid ごとに控える(判らない = nil は控えない)
    func isPhysicalIOSDevice(key: String, args: [String: Any]) async -> Bool {
        guard let udid = iosTargetUDID(key: key, args: args) else { return false }
        if let repoRoot = try? RepoRoot.find(), BridgeDeviceRecord.isRecorded(udid: udid, repoRoot: repoRoot) { return true }
        if let known = Self.physicalIOSUDIDMemo.withLock({ $0[udid] }) { return known }
        guard let found = await Self.runOffCooperativePool(name: "fleetest-mcp-is-physical",
                                                           { SimulatorCatalog.isPhysical(udid: udid) })
        else { return false }
        Self.physicalIOSUDIDMemo.withLock { $0[udid] = found }
        return found
    }

    /// resume の直前に、対象アプリのプロセスが居るか。**読めなければ nil**(居ないとは言わない)。
    /// Android = pidof / Simulator = launchctl list / 実機 = devicectl の processes(どれも同期の外部コマンド = 協調プールの外で撃つ)
    func appWasRunning(bundleID: String, driver: AppDriver, key: String, args: [String: Any]) async -> Bool? {
        if let android = driver as? AndroidDriver {
            // **撃つ相手のドライバの serial を先に使う**(引数・控えが空だと -s なしの adb になり、複数台で別の台に訊くか失敗する)
            let serial = android.serial ?? (args["serial"] as? String) ?? connectedAndroidSerials[key]
            return await Self.runOffCooperativePool(name: "fleetest-mcp-was-running") { AndroidAppProcessEvidenceQuery.query(package: bundleID, serial: serial)?.running }
        }
        guard let udid = iosTargetUDID(key: key, args: args) else { return nil }
        let isPhysical = await isPhysicalIOSDevice(key: key, args: args)
        guard isPhysical else {
            return await Self.runOffCooperativePool(name: "fleetest-mcp-was-running") { SimulatorAppProcess.isRunning(udid: udid, bundleID: bundleID) }
        }
        return await Self.runOffCooperativePool(name: "fleetest-mcp-was-running") { () -> Bool? in
            func check(_ apps: [IOSPhysicalAppCatalog.App]) -> Bool? {
                (try? IOSPhysicalRunningApps.running(udid: udid, apps: apps)).map { $0.contains(bundleID) }
            }
            if let cached = Self.physicalAppsMemo.withLock({ $0[udid] }), check(cached) == true { return true }
            guard let apps = try? IOSPhysicalAppCatalog.apps(udid: udid) else { return nil }
            Self.physicalAppsMemo.withLock { $0[udid] = apps }
            return check(apps)
        }
    }

    func ftOpenUrl(_ args: [String: Any]) async throws -> [[String: Any]] {
        let url = try Self.requiredStringArgument(args, "url")
        let openURLDriver = try await driver(args)
        let explicitBundleID = try Self.stringArgument(
            args, "bundleId", emptyHint: Self.attachedAppEmptyHint)
        let openURLBundleID = explicitBundleID ?? launchedBundleIDs[Self.sessionKey(args)]
        // installedVerdict は撃たない: simctl openurl/devicectl openURL・am start は OS の URL
        // ルーティングで、installedVerdict/launchGuardDecision が守っている
        // XCUIApplication.launch() のランナー死(ft_launch のコメント参照)とは経路が別
        // **既定で着地を待つ**。URL の配送は非同期なので、
        // `snapshotAfter` だけを渡すと**前の画面が黙って返る** —— 読み手は「開いた先の
        // 画面が欲しい」から snapshotAfter を付けているので、既定が誤りの側に倒れていた
        // (評価者の指摘。こちらも同セッションで踏んで snapshot を2回撮った)。
        // **比較の基準が要る**: `waitForChange` は「操作前の木」と比べるので、まだ1枚も
        // 読んでいないデバイス(ft_launch → ft_open_url が典型)では**待たずに素通りする**。
        // そこで基準が無いときだけ配送**前**に1枚読む。読めなくても配送は続ける
        // (主たる操作は URL の配送で、基準取りの失敗でそれを落とさない)。
        // 明示された `waitFor` / `waitForChange: false` は当然そのまま尊重する
        var openURLArgs = args
        let wantsLandingWait = args["snapshotAfter"] as? Bool == true
            && args["waitFor"] == nil && args["waitForChange"] == nil
        if wantsLandingWait {
            if lastSnapshots[Self.sessionKey(args)] == nil {
                _ = try? await freshSnapshot(openURLDriver, args: args)
            }
            openURLArgs["waitForChange"] = true
        }
        let treeBeforeDelivery = lastSnapshots[Self.sessionKey(args)]
        do {
            try await openURLDriver.openURL(url, bundleID: openURLBundleID)
        } catch where explicitBundleID == nil && openURLBundleID != nil && openURLDriver is AndroidDriver {
            // Android は bundleId を省くと最後に起動したアプリへ宛先を固定する(am start -p)。そのアプリが URL を扱わないと
            // am の生の出力だけが返り、宛先の固定が原因だと読めない
            throw MCPError(error.localizedDescription
                + "\nnote: bundleId was not given, so the URL was addressed to this session's last ft_launch on this device"
                + " (\(openURLBundleID ?? "")). If that app does not handle this URL, pass bundleId: <the app that handles it>"
                + " (e.g. a browser package for a web URL).")
        }
        // ディープリンクが未起動のアプリを新規に立ち上げることがある(systemAlertProbePending 参照)
        systemAlertProbePending.insert(Self.sessionKey(args))
        var openStep = FlowStep(action: "openURL")
        openStep.text = url
        recordAction(InteractionLog.Entry(step: openStep, unresolved: nil,
                                          summary: "openURL \"\(url)\""), args: args)
        // **「Delivered」は配送の事実だけ**: 初回の「開きますか?」確認は自動了承がベストエフォート
        // (BridgeClient.acknowledgeOpenURLConsent は (端末, bundleId) ごとに1回・bundleId が無いと
        // 試さない・in-app 接続では SpringBoard を見られない)で、戻り値を持たない。
        // 了承が効いたかは AppDriver の口からは分からないので、配送後に前面のアラートを観測して言う
        let consentDialogNote = await Self.openURLConsentDialogNote(driver: openURLDriver)
        return text(Self.openURLSummary(url: url, bundleID: openURLBundleID,
                                        bundleIDWasRemembered: explicitBundleID == nil,
                                        routedByScheme: !(openURLDriver is AndroidDriver),
                                        snapshotAfter: args["snapshotAfter"] as? Bool == true,
                                        waitFor: args["waitFor"] as? String,
                                        waitForChangeExplicit: args["waitForChange"] as? Bool)
            + consentDialogNote + (openURLDriver is AndroidDriver ? "" : Self.driverFallbackNote(openURLDriver))
            + waitForWithoutSnapshotAfterNote(args) + (await snapshotAfterBody(openURLArgs, outsideTheAppTree: false))
            + Self.openURLOtherAppCaveat(routedByScheme: !(openURLDriver is AndroidDriver),
                                         before: treeBeforeDelivery,
                                         after: args["snapshotAfter"] as? Bool == true
                                            ? lastSnapshots[Self.sessionKey(args)] : nil))
    }

    /// **iOS の URL は OS が受け手を選ぶ**(Web の URL は Safari・他アプリのスキームはそのアプリ)。受け手が別のアプリなら
    /// このセッションの木(アプリ)は変わらないので、「効かなかったかも」とだけ読ませない。言うのは木が配送の前後で同一だった
    /// 事実と、その可能性だけ(前面のアプリは iOS では照会しない = 断定しない)
    static func openURLOtherAppCaveat(routedByScheme: Bool, before: SnapshotResponse?,
                                      after: SnapshotResponse?) -> String {
        guard routedByScheme, let before, let after, looksUnchanged(before, after) else { return "" }
        return "note: the tree is still the one from before the URL was delivered. If another app handles this URL"
            + " (a web URL opens in Safari, another app's scheme opens that app), it opened there and its screen is"
            + " not in this session's tree — ft_screenshot shows what is in front.\n"
    }

    /// 配送後に前面のシステムアラートが観測できたときだけ言う(観測できない経路では黙る =
    /// 「出ていない」とは言えない)。確認ダイアログが残っていると配送は完了していない
    static func openURLConsentDialogNote(driver: AppDriver) async -> String {
        guard let alert = await frontSystemAlert(driver: driver) else { return "" }
        return " (warning: \(alert) is in front of the app after delivery — if it is the first-time"
            + " \"Open in …?\" confirmation, the automatic acceptance did not run or did not dismiss it,"
            + " and the URL has not been handled yet. Handle it with `ft_launch bundleId:"
            + " com.apple.springboard`, tap its button by ref, then `ft_launch` your app again)"
    }

    /// テスト対象でないシステムのアプリは撃つ前に断る(nil = 撃ってよい)。**iOS の Apple のアプリ**(`com.apple.*`・SpringBoard)は
    /// データを消せず入れ直しもできない。**Android のシステムのパッケージ**は連絡先・メッセージ等の利用者データを1回の承認で消せる
    /// ので、このセッションが起動したもの(テスト対象)以外を断る。`com.apple.` は Android では普通のパッケージ名(Apple Music 等)
    static func appleSystemAppRefusal(_ bundleID: String) -> String? {
        guard bundleID == MCPServer.springboardBundleID || bundleID.hasPrefix("com.apple.") else { return nil }
        return "\(bundleID) is an Apple system app (the home screen, Safari, Settings …), not an app under test —"
            + " its data cannot be wiped by this tool and it cannot be reinstalled. Nothing was sent."
    }

    func clearAppDataSystemTargetRefusal(_ bundleID: String, driver: AppDriver, args: [String: Any]) async -> String? {
        guard let android = driver as? AndroidDriver else {
            return Self.platformName(args) == "android" ? nil : Self.appleSystemAppRefusal(bundleID)
        }
        guard launchedBundleIDs[Self.sessionKey(args)] != bundleID else { return nil }
        let box = UncheckedTransfer(android)
        let probe = await Self.runOffCooperativePool(name: "fleetest-mcp-clear-app-data") {
            (box.value.isPersistentPackage(bundleID: bundleID), box.value.isSystemPackage(bundleID: bundleID))
        }
        guard probe.0 == true || probe.1 == true else { return nil }
        return "\(bundleID) is a system package, not an app under test — its data was NOT cleared (wiping system"
            + " apps can delete user data or break the device). If it really is the app under test, ft_launch it first."
    }

    func ftClearAppData(_ args: [String: Any]) async throws -> [[String: Any]] {
        resetOnceNotes(forScope: noteScope)
        let bundleID = try Self.requiredStringArgument(args, "bundleId")
        if let refusal = Self.bridgeSelfRefusal(tool: "ft_clear_app_data", bundleID: bundleID) { throw MCPError(refusal) }
        // Apple のアプリはドライバを作る前に断る(作るとブリッジの自動起動を払ってから断ることになる)。Android の宛先は下で判定する
        // プラットフォームは他の道具と同じ判定(明示・宛先・profile・FLEETEST_PLATFORM)で決める
        if Self.platformName(args) != "android", let refusal = Self.appleSystemAppRefusal(bundleID) {
            throw MCPError(refusal)
        }
        let clearAppDataDriver = try await driver(args)
        if let refusal = await clearAppDataSystemTargetRefusal(bundleID, driver: clearAppDataDriver, args: args) {
            throw MCPError(refusal)
        }
        let springBoardNote = await recheckXCUITestRunnerBeforeLaunch(args: args)
        let clearAppDataKey = Self.sessionKey(args)
        SlowCallWatchdog.mark("clearing the app's data")
        do {
            try await clearAppDataDriver.clearAppData(bundleID: bundleID)
        } catch let clearError where ReinstallSource.isClearAppDataUnsupported(clearError) {
            // **実機に devicectl の同等手段が無い**(BridgeClient.clearAppData の 501)。
            // 代わりに uninstall→install で再現する —— 権限も含めて全部消える点は同じ。
            // **先に消す前に入れ直せることを確かめる**(reinstallSource) —— 記憶したパスは
            // 再ビルドや DerivedData の掃除で消えており、確かめずに uninstall すると
            // 端末からアプリだけ消えて戻せなくなる
            // packagePath は ft_install と同じく `~` を展開し、相対パスは断る(撃つ前・消す前)
            // 端末に入っていないアプリは、別アプリの控えを入れ直し元に名指しした断りに化けない(入っていないと言う)
            if let udid = iosTargetUDID(key: clearAppDataKey, args: args),
               let installed = await BlockingWork.offPool(name: "fleetest-mcp-clear-app-data", {
                   (try? IOSPhysicalAppCatalog.apps(udid: udid))?.map(\.id)
               }), !installed.contains(bundleID) {
                throw MCPError("\(bundleID) is not installed on this device — nothing was uninstalled (ft_list_apps shows what is installed).")
            }
            let rawExplicit = args["packagePath"] as? String
            if let rawExplicit, let refusal = Self.relativePackagePathRefusal(rawExplicit) { throw MCPError(refusal) }
            let path: String
            switch Self.reinstallSource(explicit: rawExplicit.map(InstallPackagePath.expanded),
                                        remembered: installedPackagePaths[clearAppDataKey],
                                        exists: { FileManager.default.fileExists(atPath: $0) }) {
            case .success(let resolved): path = resolved
            case .failure(let error): throw error
            }
            // **消す前に**: 判定は DSL の clearAppData と同じ FTCore.ReinstallPackageCheck(文言だけここで持つ)
            if let refusal = Self.reinstallPackageRefusal(
                bundleID: bundleID, path: path, explicit: args["packagePath"] is String,
                verdict: await ReinstallPackageCheck.inspectOffPool(path: path, expectedBundleID: bundleID)) {
                throw MCPError(refusal)
            }
            // **名指しされたパスもパッケージの形でなければ消す前に断る**(フォルダ・Info.plist を devicectl は後から断り、
            // uninstall 済みのアプリが端末から消えたまま終わっていた)
            if rawExplicit != nil, !ReinstallPackageCheck.looksLikePackage(path: path) {
                throw MCPError("The app was NOT uninstalled. packagePath \(path) is not an app package (an .ipa file, or an"
                    + " .app folder that contains Info.plist) — a device cannot install it, so wiping \(bundleID) by"
                    + " reinstalling it would leave the app removed from the device. Pass packagePath: <the .app/.ipa of \(bundleID)>.")
            }
            // 形だけ整った空のパッケージ(zip でない .ipa・実行ファイルの無い .app)は devicectl が uninstall の後で断る
            if rawExplicit != nil, let empty = ReinstallPackageCheck.emptyPackageReason(path: path) {
                throw MCPError("The app was NOT uninstalled. packagePath \(path) is not an installable app: \(empty) — wiping"
                    + " \(bundleID) by reinstalling it would leave the app removed from the device."
                    + " Pass packagePath: <the .app/.ipa of \(bundleID)>.")
            }
            try await clearAppDataDriver.uninstall(bundleID: bundleID)
            let reinstallNote: String?
            do {
                reinstallNote = try await clearAppDataDriver.install(packagePath: path)
            } catch {
                // uninstall は済んでいる: 失敗の文だけだと消したことが読めない
                throw MCPError(error.localizedDescription + "\nnote: \(bundleID) was already uninstalled from the device"
                    + " before this install failed — it is NOT installed now. ft_install a device build to restore it.")
            }
            // 入れ直しでアプリのプロセスは消えた。ランナーのセッションが残っていると次の木・タップが
            // 「落ちたかも(503)」と言う —— 止めたのはこの操作なので、セッションのアプリならセッションも閉じる(ft_terminate と同じ文面になる)
            if (try? await clearAppDataDriver.status())?.sessionBundleID == bundleID {
                try? await clearAppDataDriver.terminate()
            }
            toolStoppedBundleIDs[clearAppDataKey] = "ft_clear_app_data"
            // 意図した再インストールなので、以後の別アプリの木は「すり替わり」ではない
            // (ft_terminate と同じ扱い)
            launchedBundleIDs[clearAppDataKey] = nil
            launchTimestamps[clearAppDataKey] = nil
            systemAlertProbePending.insert(clearAppDataKey)
            recordClearAppData(bundleID: bundleID, args: args)
            return text("Reinstalled \(bundleID) from \(path) (physical device: app data"
                + " wiped by uninstall + install; permission grants are reset too)"
                + (reinstallNote.map { "\n\($0)" } ?? ""))
        }
        // 次の ft_launch が初回起動と同じ扱いになる(systemAlertProbePending 参照)
        systemAlertProbePending.insert(clearAppDataKey)
        // この呼び出しでアプリを止めた事実を記録する。launchedBundleIDs は
        // ここでは消さない(再インストール分岐と違い bundleID はまだ同じアプリのまま —
        // 次の ft_launch は「初回起動」ではなく「再起動」)。switchedAppNote がこれを見て
        // 「クラッシュしたかも」ではなく「この操作で止めた」と言う
        // 消したのがセッションのアプリと別のアプリなら、セッションのアプリは止まっていない(帰属も案内も別のアプリに向けない)
        let clearedSessionApp = launchedBundleIDs[clearAppDataKey].map { $0 == bundleID } ?? true
        if clearedSessionApp { toolStoppedBundleIDs[clearAppDataKey] = "ft_clear_app_data" }
        recordClearAppData(bundleID: bundleID, args: args)
        return text(springBoardNote + (clearedSessionApp
            ? "Cleared the data of \(bundleID). The app is stopped — ft_launch to continue"
            : "Cleared the data of \(bundleID). It is stopped; this session's app (\(launchedBundleIDs[clearAppDataKey] ?? "")) was not touched"))
    }

    /// 下書きへ `clearAppData("<bundle ID>")` を残す(DSL に同じコマンドがある。実機の再インストールでも
    /// 消えるものは同じなので同じ行)
    private func recordClearAppData(bundleID: String, args: [String: Any]) {
        recordAction(InteractionLog.Entry(step: FlowStep(action: "clearAppData", text: bundleID), unresolved: nil,
                                          summary: "clearAppData \(bundleID)"), args: args)
    }

    func ftTerminate(_ args: [String: Any]) async throws -> [[String: Any]] {
        // **対象が分からなければ黙って何もしないのではなく、名指しで断る**:
        // ドライバの terminate() は Android では currentPackage が無いと何も撃たずに
        // 戻る(AndroidDriver.terminate)。target を知らずに「Terminated the app」と
        // 答えると、何も終了させていないのに成功したと誤解させる
        // **ドライバの terminate() は名指しできない**(attach 中のアプリを止めるだけ)。明示の
        // bundleId が起動中のアプリと違えば断り、起動していないデバイスへの明示指定は「送った」まで
        // しか言わない(Android は currentPackage が無ければ何も撃たない)
        let terminateKey = Self.sessionKey(args)
        let explicitBundleID = try Self.stringArgument(args, "bundleId", emptyHint: Self.attachedAppEmptyHint)
        if let explicitBundleID, let refusal = Self.bridgeSelfRefusal(tool: "ft_terminate", bundleID: explicitBundleID) {
            throw MCPError(refusal)
        }
        guard let terminateBundleID = explicitBundleID ?? launchedBundleIDs[terminateKey]
        else {
            throw MCPError("no known target to terminate — this session has no running app on record (nothing was launched"
                + " here, or the last one was already stopped by ft_terminate / ft_clear_app_data). Pass bundleId, or"
                + " ft_launch first.")
        }
        // **SpringBoard はアプリではない**: 止めるとホーム画面が再起動し、端末がロック画面に落ちる(パスコード付きの実機では
        // 解除できず以後の run が全滅しうる)。ft_launch com.apple.springboard は「向け直すだけ」で何も起動しないので、
        // 外すのも ft_launch でアプリへ向け直すこと
        if terminateBundleID == MCPServer.springboardBundleID {
            throw MCPError("\(terminateBundleID) is the home screen, not an app — terminating it restarts SpringBoard and drops"
                + " the device to the lock screen. Nothing was sent. ft_launch <your app's bundleId> to leave it.")
        }
        let terminateDriver = try await driver(args)
        // Android は名指しの package を force-stop できる(am force-stop <pkg>)ので、起動の有無に関わらず**名乗った相手を**止める
        // (ドライバの `terminate()` は控え `currentPackage` を止める。ft_open_url / ft_clear_app_data が控えを別アプリへ動かすと
        // 「Terminated A」と言いながら別のアプリを止めていた)。iOS は launch したアプリしか止められない
        let stopsByName = terminateDriver is AndroidDriver
        if !stopsByName, let explicitBundleID, let launched = launchedBundleIDs[terminateKey], explicitBundleID != launched {
            throw MCPError("this session launched \(launched), and ft_terminate can only stop the"
                + " app it is attached to — omit bundleId (or pass \(launched)) to stop that app")
        }
        // 止めたのがセッションのアプリ(または記録が無い)ときだけ、起動の記録を外す。別のアプリの名指しでは外さない
        let stopsSessionApp = launchedBundleIDs[terminateKey].map { $0 == terminateBundleID } ?? true
        var androidWasRunning: Bool?
        if stopsByName, let android = terminateDriver as? AndroidDriver {
            // **撃つ前に**: 入っていない package は `am force-stop` が 0 で黙るので「Terminated」と言ってしまう。
            // OS が常駐させるもの(systemui 等)は force-stop が画面を崩す。このセッションが起動したものは対象にする
            if !(launchedBundleIDs[terminateKey] == terminateBundleID) {
                let box = UncheckedTransfer(android)
                let probe = await Self.runOffCooperativePool(name: "fleetest-mcp-terminate") {
                    (box.value.isInstalled(bundleID: terminateBundleID),
                     box.value.isPersistentPackage(bundleID: terminateBundleID))
                }
                if probe.0 == false {
                    throw MCPError("\(terminateBundleID) is not installed on this device — nothing was stopped"
                        + " (ft_list_apps shows what is installed).")
                }
                if probe.1 == true {
                    throw MCPError("\(terminateBundleID) is a persistent system package (the OS keeps it running and restarts it;"
                        + " stopping it breaks the status bar and notifications), not an app under test — nothing was stopped.")
                }
            }
            let box = UncheckedTransfer(android)
            androidWasRunning = await Self.runOffCooperativePool(name: "fleetest-mcp-terminate") {
                box.value.isRunning(bundleID: terminateBundleID)
            }
        }
        let terminateUnverified = explicitBundleID != nil && launchedBundleIDs[terminateKey] == nil && !stopsByName
        // **シミュレータでは止まったことを simctl で確かめる**(ランナーの terminate はランナーのセッションが起動したアプリに
        // しか効かない = 止まっていないのに「Terminated」と言いうる。clearAppDataOnSimulator と同じ理由・同じ判定)
        // 宛先はセッションが特定した udid がシミュレータのときだけ(ドライバは包まれうるので型で見ない。実機は対象外)
        let isSimulator = isSimulatorUDID
        let candidateUDID = terminateDriver is AndroidDriver ? nil : udids[terminateKey] ?? nil
        let simulatorUDID: String? = await Self.runOffCooperativePool(name: "fleetest-mcp-terminate") {
            candidateUDID.flatMap { isSimulator($0) ? $0 : nil }
        }
        var runnerHadNoSession = false
        do {
            if stopsByName, let android = terminateDriver as? AndroidDriver {
                try await android.terminate(bundleID: terminateBundleID)
            } else {
                try await terminateDriver.terminate()
            }
        } catch DriverError.badResponse(409, _) where !(terminateDriver is AndroidDriver) {
            // XCUITest ランナーの 409 は「セッションが無い」(SessionRecoveryDriver の不変条件)。**アプリは生きていうる**
            // (ランナーだけ起動し直した等)ので、シミュレータは下の simctl で止めて確かめる。確かめられない実機は断る。
            // ランナー内部向けの文言(「ホストが /session で張り直す」)は MCP の読み手が取れる手段ではない。
            // 起動の記録も消す(ドライバの控えは SessionRecoveryDriver.terminate が消す = 食い違わせない)
            guard simulatorUDID != nil else {
                let launchedHere = launchedBundleIDs[terminateKey] != nil
                launchedBundleIDs[terminateKey] = nil
                launchTimestamps[terminateKey] = nil
                throw MCPError(Self.terminateNoSessionRefusal(bundleID: terminateBundleID, launchedHere: launchedHere))
            }
            runnerHadNoSession = true
        }
        if let simulatorUDID {
            let stop = stopAppOnSimulator
            try await BlockingWork.offPool(name: "fleetest-mcp-terminate") { try stop(terminateBundleID, simulatorUDID) }
        }
        // 意図して落としたので、以後の別アプリの木は「すり替わり」ではない
        if stopsSessionApp {
            launchedBundleIDs[terminateKey] = nil
            launchTimestamps[terminateKey] = nil
            toolStoppedBundleIDs[terminateKey] = nil
            systemAlertProbePending.remove(terminateKey)
        }
        // 前面が消えたので、覆い探針の記憶(F 節)は使い回さない
        lastScreenProbe[terminateKey] = nil
        // 下書きへ `terminateApp()` を残す(DSL の terminateApp は対象を取らない = セッションのアプリ)
        recordAction(InteractionLog.Entry(step: FlowStep(action: "terminate"), unresolved: nil,
                                          summary: "terminate \(terminateBundleID)"), args: args)
        // **Android は止めた後、前面に残った別のアプリへ session が移る**(兄弟アプリが見た目も #id も同じことがある)。
        // launchedBundleIDs を落とした以上 switchedAppNote は黙るので、ここで前面を言う。
        // 言うのは**このセッションで操作したアプリ**が前面に来たときだけ(ランチャーが前面なのは止めた後の普通の姿)
        var terminateFrontNote = ""
        if terminateDriver is AndroidDriver, !terminateUnverified,
           let front = (try? await terminateDriver.foregroundAppID()) ?? nil, !front.isEmpty,
           front != terminateBundleID, appWasDrivenOnThisDevice(front, args: args) {
            terminateFrontNote = "\nnote: \(front) is in front now — the session follows it, so the next ft_snapshot shows"
                + " \(front)'s tree, not \(terminateBundleID)'s (ft_launch your app to go back)."
        }
        // 409 を simctl で止めた回は、セッションで起動していなくても止まったことを確かめている = 未確認の文面にしない
        if androidWasRunning == false {
            return text("\(terminateBundleID) was not running — nothing was stopped" + terminateFrontNote)
        }
        return text(terminateUnverified && !runnerHadNoSession
            ? "Terminate sent for \(terminateBundleID) (nothing was launched in this session, so the"
                + " driver stopped whichever app it is attached to; nothing about the result is checked)"
            : "Terminated \(terminateBundleID)"
                + (stopsByName && !stopsSessionApp ? " (force-stopped by package name; it is not this session's app)" : "")
                + (runnerHadNoSession ? " (the XCUITest runner had no session for it, so it was stopped on the simulator directly)" : "")
                + terminateFrontNote)
    }

    func ftDoctor(_ args: [String: Any]) async throws -> [[String: Any]] {
        // **既定では撃たない**: 実呼び出しは Vision のモデルを読み(初回 25〜47s)、FM を起こす
        guard args["fmAndVision"] as? Bool == true else {
            return text("Not checked: MCP does not use Foundation Models or Vision by default (ft_run_scenario and"
                + " ft_start_run run without them). Pass fmAndVision: true to check them, or to use them in a run.")
        }
        let fm = await FMDoctor.checkLive()
        // **視覚系も実呼び出しで確かめる**(能力判定では足りない。text と vision は独立に死ぬ)
        let vision = await FMDoctor.visionCheckLive()
        // OCR も実呼び出しで(FM と独立に死ぬ。判定は RegionText.readerIsAlive の1箇所・CLI の doctor と共有)
        let ocrAlive = await RegionText.readerIsAlive()
        return text((fm.available ? "✅ " : "❌ ") + fm.detail
            + (fm.available ? "" : "\n   " + FMDoctor.unavailableImpact)
            + "\n" + (vision.available ? "✅ " : FMVisionSupport.isSupported ? "❌ " : "⚠️ ") + vision.detail
            + "\n" + (ocrAlive
                ? "✅ On-device OCR (Vision text recognition) read the built-in test image"
                : "❌ On-device OCR (Vision text recognition) read nothing from the built-in test image (an image"
                    + " with known text) — while it stays so, link-text taps fail, typed text cannot be read back from the"
                    + " screen, and the OCR stage of the text visibility check cannot read text (rebooting this"
                    + " Mac has cleared this state before)"))
    }
}
