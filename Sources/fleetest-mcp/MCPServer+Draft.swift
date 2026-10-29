// MCPServer+Draft.swift
// 探索の操作列からのシナリオ下書き生成と、操作の記録。本体は MCPServer.swift

import Foundation
import FTFoundationModels
import FTAndroid
import FTBridgeClient
import FTCore

extension MCPServer {

    /// 探索の操作列から Swift シナリオの**下書き**を組む(F)。
    ///
    /// **ファイルには書かない**(F-2): 置き場所と命名はスキルの仕事で、MCP は文字列を返すだけ。
    /// 生成そのものは `ScenarioCodeGen.render` に委ねる —— CAE の形も DSL の綴りも1箇所で決める
    /// (2つ目の実装を作らない)。
    ///
    /// **アサーションは推測で作らない**(F-5): expectation は空の骨格で出し、
    /// ft_dry_run の「アサーションの無い expectation ブロック」検出に埋めさせる。
    /// **セレクタを解決できなかった手は TODO で残す**(F-4) —— 消すと手順と食い違う
    func draftScenario(_ args: [String: Any]) throws -> String {
        // **下書きは1台分**: 1つのプロセスで2台を操作した記録は、最後に操作した台の手だけを使う
        // (混ぜると、別の台の画面にしか無いセレクタが1本のシナリオに並ぶ)。残りは header で言う
        let draftDevice = interactions.latestDevice
        let recorded = interactions.scope(all: args["all"] as? Bool == true, device: draftDevice)
        guard !recorded.isEmpty else {
            return "No interactions recorded yet. Drive the app with ft_launch / ft_tap / ft_type"
                + " / ft_scroll_to first — this tool turns that sequence into a scenario draft."
        }
        // **刈り込みは下書きの質そのもの**: 記録は「やったこと」であって
        // 「意図」ではないので、行き止まりのタップや試し打ちがそのまま載る。自動では
        // 本筋と回り道を見分けられない(どちらも成功した操作)ので、**番号を見せて選ばせる**
        // **範囲は intArgument が見る**(ArgumentBounds.numeric["lastN"] = 1以上。型だけ見て
        // 0 や負を通すと、黙って「全部」か「空」になる)
        let lastN = try Self.intArgument(args, "lastN")
        let (scope, droppedCount, ignoredNumbers) = InteractionLog.prune(
            recorded, lastN: lastN,
            drop: try Self.intArrayArgument(args, "drop") ?? [])
        guard !scope.isEmpty else {
            return "Every recorded step was pruned away (\(recorded.count) recorded,"
                + " \(droppedCount) dropped). Call ft_draft_scenario again with a smaller"
                + " drop list — the numbering is 1-based over the steps shown in the listing."
        }
        let target = interactions.target(in: scope, device: draftDevice)
        let unresolved = scope.compactMap(\.unresolved)
        let steps = scope.compactMap(\.step)
        // **解決できなかった手はその場に残す**。まとめて先頭へ出すと action の
        // 並びからその手が消え、生成コードが実際の手順と食い違う(33 手の下書きで実際に起きた:
        // チェックアウト→住所画面へ移る手が抜けたまま #btn_add_address を叩く形になった)
        var notesBeforeStep: [Int: [String]] = [:]
        // 一覧の番号(1 起点・刈り込み後)→ steps の位置。scenes: もこの対応で読む
        var stepIndexForListing: [Int] = []
        var resolved = 0
        // 範囲で最初の launch(condition の launchApp() に写る)。先に宣言(irregularHandler)があっても位置 0 とは限らない
        let firstLaunch = scope.firstIndex(where: \.isLaunch)
        for (position, entry) in scope.enumerated() {
            stepIndexForListing.append(resolved)
            if let described = entry.unresolved {
                notesBeforeStep[resolved, default: []].append(
                    "TODO: no stable selector — \(described)"
                        + " (step \(position + 1) of the exploration)")
            } else if entry.step != nil {
                resolved += 1
            } else if let note = Self.unrenderedStepNote(entry, position: position, isFirstLaunch: position == firstLaunch,
                                                         target: target.app) {
                // **DSL の行にならない手も黙って捨てない**(launch / activate / 将来の step なしの記録)。
                // 先頭の launch だけは condition の launchApp() に写る
                notesBeforeStep[resolved, default: []].append(note)
            }
        }
        let sceneBreaks = (try Self.intArrayArgument(args, "scenes") ?? [])
            .compactMap { number -> Int? in
                guard number >= 1, number <= stepIndexForListing.count else { return nil }
                return stepIndexForListing[number - 1]
            }
        let flow = Flow(name: args["title"] as? String ?? "explored with ft_* (draft)",
                        app: target.app, platform: target.platform,
                        goal: nil, generatedBy: Self.draftGeneratedBy, steps: steps)
        let className = (args["className"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "DraftedScenario"
        // **書き出せない名前をそのまま生成しない**(判定は ScenarioCodeGen の1箇所・文言はここ)
        guard ScenarioCodeGen.isWritableClassName(className) else {
            throw MCPError("className \"\(className)\" cannot be a Swift class name — use letters,"
                + " digits and _ only, and do not start with a digit (Japanese names are fine)")
        }
        let code = ScenarioCodeGen.render(flow: flow, className: className,
                                          generatedBy: Self.draftGeneratedBy,
                                          emptyExpectation: true,
                                          notesBeforeStep: notesBeforeStep,
                                          sceneBreaks: sceneBreaks)
        var header = "Draft for \(target.app.isEmpty ? "(unknown app)" : target.app)"
            + " from \(scope.count) recorded interaction(s)"
            + (unresolved.isEmpty ? "" : ", \(unresolved.count) of which have no stable selector")
            + ".\nWrite it under TestProjects/<project>/scenarios/ and run ft_dry_run."
            + " **The expectation block is intentionally empty** — dry-run will report it,"
            + " and that is the signal to fill in what this scenario proves.\n"
        let others = interactions.otherDevices(than: draftDevice, all: args["all"] as? Bool == true)
        if others.count > 0 {
            header += "⚠️ this draft covers only the device you drove last (\(draftDevice ?? "?")):"
                + " \(others.count) recorded interaction(s) on other device(s)"
                + " (\(others.keys.joined(separator: ", "))) were left out. A scenario runs on one device —"
                + " draft the other one separately.\n"
        }
        // SpringBoard への attach はアプリの起動ではない(target と同じ扱い)
        let launchedApps = Set(scope.compactMap(\.bundleID).filter { $0 != MCPServer.springboardBundleID })
        if launchedApps.count > 1 {
            header += "⚠️ the steps launch \(launchedApps.count) different apps"
                + " (\(launchedApps.sorted().joined(separator: ", "))) but the class is written for"
                + " \(target.app) — see the TODO comments where the app changes.\n"
        }
        if interactions.droppedFromFront > 0 {
            header += "note: the \(interactions.droppedFromFront) oldest interaction(s) were"
                + " dropped from the log (it keeps the most recent"
                + " \(InteractionLog.maximumEntries)).\n"
        }
        if droppedCount > 0 {
            header += "note: \(droppedCount) step(s) were pruned at your request.\n"
        }
        if !ignoredNumbers.isEmpty {
            // **黙って無視しない**: 番号を1つ外しただけで別の手が落ちるので、
            // 「効かなかった指定がある」ことに気付けないと誤った下書きを持ち帰る
            header += "⚠️ drop \(ignoredNumbers.map(String.init).joined(separator: ", "))"
                + " is out of range (1…\(recorded.count)) and was ignored.\n"
        }
        return header + Self.pruningListing(scope) + "\n" + code
    }

    /// DSL の行を持たない記録(step も unresolved も無い)を、行の位置に残す TODO コメントへ直す。
    /// 範囲で最初の launch(`isFirstLaunch`)が対象アプリなら `launchApp()`(condition)が担うので nil
    /// (位置 0 で見ない = 先に irregularHandler の宣言があると誤って「起動し直した」と言う)。
    /// **resume(activate)は DSL に対応が無い**ので、状態を保った前面化だったことを残す
    static func unrenderedStepNote(_ entry: InteractionLog.Entry, position: Int, isFirstLaunch: Bool,
                                   target: String) -> String? {
        let what = entry.summary.isEmpty ? "(unnamed step)" : entry.summary
        if entry.isLaunch {
            if isFirstLaunch, entry.bundleID == target { return nil }
            let app = entry.bundleID ?? target
            return "TODO: the exploration launched the app again here (\(what)); a scenario starts it only"
                + " once, in condition — if the restart is needed, add restartApp(\"\(app)\") here"
                + " (it also terminates first)"
        }
        if entry.bundleID == MCPServer.springboardBundleID {
            return "TODO: the exploration attached to SpringBoard here (\(what)) to act on the home screen or a"
                + " system alert, not the app — in a scenario, close the alert with an irregular handler or drop these steps"
        }
        if let bundleID = entry.bundleID {
            return "TODO: the exploration brought \(bundleID) to the front without relaunching"
                + " (\(what)); the DSL has no activate — use appSwitcher() / home() or openURL(...) to get"
                + " back, or drop this step"
        }
        return "TODO: no DSL line for \(what) (step \(position + 1) of the exploration)"
    }

    /// 実体は `FTCore.SelectorNaming.asWritten`(needsEscaping/computeGraded が使うため
    /// SelectorNaming と一緒に FTCore に置く)。ここは呼び出し元の綴りを変えないための転送
    static func asWritten(_ selector: String) -> String {
        SelectorNaming.asWritten(selector)
    }

    /// 下書きの行末に残す但し書き。安定なセレクタには**付けない** ——
    /// 全行にコメントが付くと読み飛ばされ、本当に危ない行が埋もれる
    static func indexedSelectorNote(_ durability: Durability) -> String? {
        DraftNotes.selectorDurability(durability)
    }

    /// 下書きに入った手の番号付き一覧。**これを見て `drop:` を組む**ので、番号は
    /// 刈り込み後の並び(次の呼び出しで同じ番号が同じ手を指す)
    static func pruningListing(_ scope: [InteractionLog.Entry]) -> String {
        let rows = scope.enumerated().map { index, entry -> String in
            "  \(index + 1). \(entry.summary.isEmpty ? "(unnamed step)" : entry.summary)"
        }
        return "Steps in this draft — re-run with drop: [n, …] to remove the dead ends,"
            + " lastN: <k> to keep only the last k, or scenes: [n, …] to cut it into scenes"
            + " at those steps:\n" + rows.joined(separator: "\n") + "\n"
    }

    static let draftGeneratedBy = "fleetest MCP exploration (ft_draft_scenario)"

    /// 操作を1手ぶん記録する(F)。**E と同じ `SelectorNaming` でセレクタを決める** ——
    /// 戻り値に出したセレクタと、下書きに書かれるセレクタが食い違わないようにするため。
    ///
    /// セレクタを解決できなかった手も**捨てずに**残す(`unresolved`)。落とすと、
    /// 出来上がったシナリオが実際の手順と食い違う(F-4)
    /// 記録した手のセレクタを**どの木で名付けるか**。
    ///
    /// **`lastSnapshots` は「最後に読んだ木」であって「その ref が属する木」ではない。**
    /// 記録より先に撮り直す経路がある —— `ft_type` は入力の読み返しと `snapshotAfter` を
    /// 記録の前に通すので、そこでは ref は別世代の番号になっている。実機の観測:
    ///
    ///     REC action=tap  ref=14 refs=1,2,3,…    → 引ける
    ///     REC action=type ref=21 refs=26,27,28,… → 引けない(木が入力後の世代)
    ///
    /// 引けないと `// TODO: no stable selector — type` として下書きへ落ちる ——
    /// **`#id` を持つ欄でも**。Google メッセージの `#ContactSearchField` で 3/3 再現し、
    /// 修正後は 2/2 で `type("#ContactSearchField", …)` になった。
    ///
    /// **世代が無いときだけ最新の木へ落ちる**(座標タップ等、世代を持たない経路はこちら)。
    ///
    /// **配線(ここを呼ぶこと)も単体テストで守っている**(`DraftTypeSelectorTests`)。
    /// ただし台本には条件がある —— **操作後の木の顔ぶれを変えること**。`adoptSnapshot` は
    /// identity(ref/type/identifier/label)が同じなら世代を使い回すので、`value` だけが
    /// 変わる木では ref が進まず**欠陥そのものが起きない**(最初に書いたテストはこれで
    /// 空回りし、変異が生き残った)。詳細は FakeDriver.scriptedSnapshots の罠の項
    static func namingSnapshot(ref: Int, generation: SnapshotResponse?,
                               latest: SnapshotResponse?) -> SnapshotResponse? {
        if let generation, generation.elements.contains(where: { $0.ref == ref }) { return generation }
        return latest
    }

    /// 下書きを台ごとに分ける鍵 = **解決した実体**(iOS の udid・Android の serial)。sessionKey は同じ台でも profile: と
    /// udid:/port: で別の値になり、1台の探索が「別の台」に割れて launch や手が下書きから落ちる。実体が引けなければ sessionKey
    func draftDeviceKey(_ args: [String: Any]) -> String {
        let key = Self.sessionKey(args)
        if Self.platformName(args) == "android" {
            if let serial = (args["serial"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) ?? connectedAndroidSerials[key] {
                return "android:\(serial)"
            }
            return key
        }
        return iosTargetUDID(key: key, args: args).map { "ios:\($0)" } ?? key
    }

    /// `interactions.record` の唯一の通し口: 記録と同時に、この sessionKey へ
    /// このセッションが何かを撃った回数(`sessionActionCounts`)も刻む。**素の
    /// `interactions.record` を直に呼ばない** —— そちらへ戻すと、その手だけ
    /// `screenChangedUnderRefNote` の出自判定から抜け、木の変化を誤って外部要因のせいにする
    func recordAction(_ entry: InteractionLog.Entry, args: [String: Any]) {
        sessionActionCounts[Self.sessionKey(args), default: 0] += 1
        lastActionCallIDs[Self.sessionKey(args)] = Self.currentCallID
        var tagged = entry
        if tagged.deviceKey == nil { tagged.deviceKey = draftDeviceKey(args) }
        interactions.record(tagged)
    }

    func recordInteraction(action: String, resolvedRef: Int?, args: [String: Any],
                           text: String? = nil, direction: String? = nil,
                           coordinate: (x: Double, y: Double)? = nil,
                           duration: Double? = nil, maxGestureSeconds: Double? = nil,
                           scale: Double? = nil, degrees: Double? = nil,
                           replace: Bool = false) {
        // tap → type の間に別の操作が入ったら「叩いた欄へ入れる」意図ではない(DSL と同じ規律)。
        // **ref を渡した type も捨てる**: 欄を名指しした後の ref なし type は、その欄の続きであって数手前のタップの続きではない
        // (残すと、画面遷移のタップ → ref つき type → ref なし type が、遷移先の別の欄へ打った。Emulator の E2EX で 2/2)
        if action != "tap", action != "type" || resolvedRef != nil { lastTapTargets[Self.sessionKey(args)] = nil }
        // type の後のキーボードの出現待ち(pendingTypeKeyboardCheck)は、間に別の操作を挟んだら捨てる —— 打つ前の木が古くなり、
        // Android では「出ていない → 出るはず」と読んで、閉じた後の ref 操作でも上限(1.5 秒)まで待つ
        if action != "type" { pendingTypeKeyboardChecks[Self.sessionKey(args)] = nil }
        var selector: String?
        var durability: Durability = .stable
        var described = "\(action)"
        // **ref が属する世代の木で名付ける**。`lastSnapshots` は「最後に読んだ木」で、
        // **記録より先に撮り直す経路がある**(ft_type は入力の読み返し・snapshotAfter を
        // 記録の前に通す)。そこを見ると ref は別世代の番号なので引けず、**#id を持つ欄でも
        // 下書きが `// TODO: no stable selector — type` になる**。実機の観測:
        //   REC action=tap  ref=14 refs=1,2,3,…   → 引ける
        //   REC action=type ref=21 refs=26,27,28,… → 引けない(木が入力後の世代)
        // 世代を先に見て、無ければ最新の木へ落ちる
        if let resolvedRef,
           let snapshot = Self.namingSnapshot(
               ref: resolvedRef, generation: generationSnapshot(containing: resolvedRef, args: args),
               latest: lastSnapshots[Self.sessionKey(args)]),
           let element = snapshot.elements.first(where: { $0.ref == resolvedRef }) {
            let graded = Self.SelectorNaming(snapshot).graded(for: element, in: snapshot)
            selector = graded?.selector
            durability = graded?.durability ?? .stable
            described = "\(action) ref \(resolvedRef) — \(RefGuard.describe(element))"
        } else if let coordinate {
            described = "\(action) at (\(coordinate.x), \(coordinate.y))"
        }
        // ロケータ不要の手(swipe / フォーカス任せの type・clearInput / 全画面ピンチ)はセレクタが無くても行にできる
        let needsLocator = !["swipe", "type", "clearInput", "pressEnter", "back", "home", "appSwitcher",
                             "pinchOut", "pinchIn", "hideKeyboard", "fold", "unfold", "hinge"]
            .contains(action) || (resolvedRef != nil || coordinate != nil)
        // **座標タップは行にできる**(DSL の `tap(x:y:)` へ 1:1 で書き出せる)。
        // **ただし用途で重みが違う**(ユーザー方針): 対話中の探索では座標のほうが速いことがあるが、
        // **シナリオに残す目的ならセレクタが最優先**。下書きは実行できる行を出したうえで、
        // 置き換えるべきであることを行末コメントに残す(ScenarioCodeGen が `step.note` を出す)
        // 座標の長押し(`ft_long_press {x,y}` = action "press")は `tap(x:y:holdSeconds:)`、座標の doubleTap は
        // `doubleTap(x:y:)` へ落とす(どちらも TODO に落とさない)。**点に写る要素に書けるセレクタがあればその行**
        // (`PointTarget`。ライブ操作の操作記録と同じ判定)。木は撃つ前に読んだ最後の木(記録は撃った直後・snapshotAfter より前)
        if ["tap", "press", "doubleTap"].contains(action), selector == nil, let coordinate {
            let isDoubleTap = action == "doubleTap"
            var step: FlowStep
            if let tree = lastSnapshots[Self.sessionKey(args)],
               let graded = PointTarget.writableSelector(atX: coordinate.x, y: coordinate.y, in: tree) {
                step = FlowStep(action: isDoubleTap ? "doubleTap" : "tap",
                                locator: FTSelector.parse(graded.selector).primary)
                step.note = DraftNotes.joined(
                    DraftNotes.selectorDurability(graded.durability),
                    graded.pressesThePoint ? nil : DraftNotes.pressedPoint(x: coordinate.x, y: coordinate.y))
            } else {
                step = FlowStep(action: isDoubleTap ? "doubleTap" : "tap", x: coordinate.x, y: coordinate.y)
                step.note = DraftNotes.coordinates
            }
            if !isDoubleTap {
                step.duration = duration
                step.maxGestureSeconds = maxGestureSeconds
            }
            recordAction(InteractionLog.Entry(step: step, unresolved: nil,
                                              summary: described), args: args)
            return
        }
        if selector == nil, needsLocator, action != "swipe" {
            recordAction(InteractionLog.Entry(step: nil, unresolved: described,
                                              summary: "\(described) [no selector]"), args: args)
            return
        }
        var step = FlowStep(action: action)
        if let selector { step.locator = FTSelector.parse(selector).primary }
        step.text = text
        step.direction = direction
        // 実際に撃った値を残す(落とすと draft が既定値で再生成され、3秒の長押しが
        // 1秒に化けたシナリオが黙って出る)。maxGestureSeconds も同じ理由 —— 落とすと
        // 既定10秒を超える長押し/ピンチが再生成後に再現不能な(検査で断られる)シナリオになる
        step.duration = duration
        step.maxGestureSeconds = maxGestureSeconds
        step.scale = scale
        step.degrees = degrees
        step.replace = replace ? true : nil
        // **下書きの本文にも格付けを残す**(掃討で判明): 注記と ft_tap の戻り値だけに
        // 印を出しても、その場で読まれなければ意味が無い —— 添字付きのセレクタは
        // シナリオに書かれた後で静かに壊れるので、コードの側に理由を残す。
        // **セッション内2回目以降は短縮形**(once)にする — 同じ探索で添字セレクタが何度も
        // 出る画面(一覧行の連打など)では、同じ長文がそのぶん下書きに繰り返される
        step.note = selector == nil ? nil : Self.indexedSelectorNote(durability).map { full in
            once("indexedSelectorNote", full: full, short: "index-based selector (see the first note)")
        }
        let detail = [selector.map { "\"\($0)\"" }, text.map { "\"\($0)\"" }, direction]
            .compactMap { $0 }.joined(separator: " ")
        recordAction(InteractionLog.Entry(
            step: step, unresolved: nil,
            summary: detail.isEmpty ? action : "\(action) \(detail)"), args: args)
    }

    /// 撮ったスナップショットの `#id` をプロジェクトの台帳へ足す(ft_dry_run が綴り誤りの照合に使う。
    /// SelectorInventory 参照)。**best-effort** —— プロジェクトを特定できない・書けないなら黙って諦める
    /// (探索の邪魔をしない。台帳が薄いと dry-run が黙るだけで、誤検知にはならない)
    static func recordSelectors(_ snapshot: SnapshotResponse, _ platform: String,
                                _ args: [String: Any]) {
        guard let project = try? ScenarioHost.project(named: args["project"] as? String) else { return }
        SelectorInventory.record(ids: SelectorInventory.ids(in: snapshot), platform: platform,
                                 at: SelectorInventory.url(projectRoot: project.rootURL))
    }
}
