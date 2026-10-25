// ライブ操作で撃った1コマンドを、同じ操作の Swift DSL の1行にする純粋関数(操作記録の右列に出す。
// actionResult の `dsl` 欄 = Sources/fleetest/ApiLiveCommand.swift 冒頭の契約)。
//
// 変換は MCP の下書き(ft_draft_scenario)と同じ道を通す: 撃ったコマンド → `FlowStep` →
// `ScenarioCodeGen.command(for:)`。セレクタの名付けは `SelectorNaming`、但し書きは `DraftNotes`。
// 写像表をここと MCP で別々に持たない(行の形が食い違う)ための置き場。
// 対向: vscode-fleetest/src/liveModel.ts(dsl を表示するだけ。TS 側に変換は持たない)。

import FTCore
import Foundation

enum LiveOperationDSL {

    // MARK: 長押し判定時間

    /// iOS の長押し判定時間[秒]。`UILongPressGestureRecognizer.minimumPressDuration` の既定 0.5 秒
    /// (アプリが変えていればこの値とずれる)。ドラッグの静止がこれ以上なら、OS は押し始めを長押しとして
    /// 扱い得るので `swipePointToPoint`(押してすぐ動く)では同じ操作にならず、`gesture` で書く
    static let iosLongPressSeconds: Double = 0.5
    /// Android の長押し判定時間[秒]。`ViewConfiguration.getLongPressTimeout()` の既定 400ms
    /// (OS の版・端末の「長押しの時間」設定で変わり得る)。使い方は `iosLongPressSeconds` と同じ
    static let androidLongPressSeconds: Double = 0.4

    static func longPressThresholdSeconds(platform: String?) -> Double {
        platform == "android" ? androidLongPressSeconds : iosLongPressSeconds
    }

    // MARK: 行

    /// 撃ったコマンドの DSL の1行(行末コメントつき)。組めない(観測だけ・DSL に対応する行が無い・
    /// ref が直近の観測に無い)ときは nil。
    /// - snapshot: 利用者が見ていた直近の観測の木(ref の解決用。操作の**前**のもの)
    static func line(for command: ApiLiveServeCommand, platform: String?,
                     snapshot: SnapshotResponse?, screen: FTRect?) -> String? {
        guard let step = step(for: command, platform: platform, snapshot: snapshot, screen: screen),
              var line = ScenarioCodeGen.command(for: step) else { return nil }
        if let comment = step.note, !comment.isEmpty {
            line += "  // \(comment.replacingOccurrences(of: "\n", with: " "))"
        }
        return line
    }

    /// 座標の表示は 0.1、秒は 0.001 に丸める(木の枠は 120.30000000000001 のような値で来る)
    private static func point(_ value: Double) -> Double { (value * 10).rounded() / 10 }
    private static func seconds(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

    static func step(for command: ApiLiveServeCommand, platform: String?,
                     snapshot: SnapshotResponse?, screen: FTRect?) -> FlowStep? {
        switch command.cmd {
        case "tap":
            if let ref = command.ref {
                return refStep(action: "tap", ref: ref, snapshot: snapshot)
            }
            guard let x = command.x, let y = command.y else { return nil }
            return pointStep(action: "tap", x: x, y: y, snapshot: snapshot)
        case "press":
            guard let x = command.x, let y = command.y, let hold = command.duration else { return nil }
            var step = pointStep(action: "tap", x: x, y: y, snapshot: snapshot)
            step.duration = seconds(hold)
            step.maxGestureSeconds = command.maxGestureSeconds
            return step
        case "doubleTap":
            if let ref = command.ref {
                return refStep(action: "doubleTap", ref: ref, snapshot: snapshot)
            }
            guard let x = command.x, let y = command.y else { return nil }
            return pointStep(action: "doubleTap", x: x, y: y, snapshot: snapshot)
        case "type":
            guard let text = command.text else { return nil }
            var step = FlowStep(action: "type", text: text)
            // ref を叩いてから打つ操作なので、書けるセレクタがあれば付ける(無ければフォーカス任せの行)
            if let ref = command.ref, let named = named(ref: ref, snapshot: snapshot) {
                step.locator = named.locator
                step.note = named.note
            }
            return step
        case "clear":
            var step = FlowStep(action: "clearInput")
            if let ref = command.ref, let named = named(ref: ref, snapshot: snapshot) {
                step.locator = named.locator
                step.note = named.note
            }
            return step
        case "hideKeyboard": return FlowStep(action: "hideKeyboard")
        case "swipe":
            guard let raw = command.direction, FTSwipeDirection(rawValue: raw) != nil else { return nil }
            return FlowStep(action: "swipe", direction: raw)
        case "drag":
            return dragStep(command, platform: platform, screen: screen)
        case "gesture":
            guard let fingers = command.fingers, !fingers.isEmpty, let screen else { return nil }
            var step = FlowStep(action: "gesture")
            step.gesture = TouchGesture.ratioFingers(TouchGesture.fingers(fromPoints: fingers), screen: screen)
            guard !(step.gesture ?? []).isEmpty else { return nil }
            step.maxGestureSeconds = command.maxGestureSeconds
            return step
        case "pinch":
            let scale = command.scale ?? 2.0
            guard scale > 0, scale != 1, scale.isFinite else { return nil }
            var step = FlowStep(action: scale > 1 ? "pinchOut" : "pinchIn")
            step.scale = scale
            let duration = command.duration ?? ApiLiveGestureDefaults.pinchDurationSeconds
            // 既定の所要時間は書かない(DSL の pinchStep と同じ判定)
            step.duration = duration == FlowStep.defaultPinchDurationSeconds ? nil : seconds(duration)
            step.maxGestureSeconds = command.maxGestureSeconds
            if let ref = command.ref {
                // 対象を名指しした操作を、全画面のピンチの行に化けさせない
                guard let named = named(ref: ref, snapshot: snapshot) else { return nil }
                step.locator = named.locator
                step.note = named.note
            }
            return step
        case "home": return FlowStep(action: "home")
        case "back": return FlowStep(action: "back")
        case "appSwitcher": return FlowStep(action: "appSwitcher")
        case "terminate": return FlowStep(action: "terminate")
        case "fold":
            guard command.state == "fold" || command.state == "unfold" else { return nil }
            return FlowStep(action: command.state)
        default:
            // refresh / frame = 観測だけ。launch / activate / install は ScenarioCodeGen に対応する行が無い
            // (launchApp は下書きでは condition に固定で出す形)。clearAppData は対象のアプリが撃つときに
            // 決まる(resolveBundleForClearAppData)ので、撃つ前には行を組めない
            return nil
        }
    }

    // MARK: 部品

    /// 座標で撃った tap / press / doubleTap: 点に写る要素に書けるセレクタがあればその行(`PointTarget`)、
    /// 無ければ座標の行(+ 座標の但し書き)
    private static func pointStep(action: String, x: Double, y: Double, snapshot: SnapshotResponse?) -> FlowStep {
        guard let snapshot, let graded = PointTarget.writableSelector(atX: x, y: y, in: snapshot) else {
            return coordinateStep(action: action, x: x, y: y)
        }
        var step = FlowStep(action: action, locator: FTSelector.parse(graded.selector).primary)
        step.note = DraftNotes.selectorDurability(graded.durability)
        return step
    }

    private static func coordinateStep(action: String, x: Double, y: Double) -> FlowStep {
        var step = FlowStep(action: action, x: point(x), y: point(y))
        step.note = DraftNotes.coordinates
        return step
    }

    /// 直近の観測の木で ref の要素を引き、`SelectorNaming` で書けるセレクタを返す
    private static func named(ref: Int, snapshot: SnapshotResponse?)
        -> (locator: FlowLocator, note: String?)? {
        guard let snapshot, let element = snapshot.elements.first(where: { $0.ref == ref }),
              let graded = SelectorNaming(snapshot).graded(for: element, in: snapshot) else { return nil }
        return (FTSelector.parse(graded.selector).primary, DraftNotes.selectorDurability(graded.durability))
    }

    /// ref で撃つ tap / doubleTap: セレクタが書ければそれ、無ければ要素の中心の座標(+ 座標の但し書き)。
    /// ref が直近の観測に無ければ nil(撃った先を言えない)
    private static func refStep(action: String, ref: Int, snapshot: SnapshotResponse?) -> FlowStep? {
        guard let snapshot, let element = snapshot.elements.first(where: { $0.ref == ref }) else { return nil }
        var step: FlowStep
        if let named = named(ref: ref, snapshot: snapshot) {
            step = FlowStep(action: action, locator: named.locator)
            step.note = named.note
        } else {
            step = coordinateStep(action: action, x: element.frame.centerX, y: element.frame.centerY)
        }
        return step
    }

    /// drag: 押してから動かすまでの静止が OS の長押し判定時間に届かなければ `swipePointToPoint`
    /// (座標 + 但し書き)、届いていれば `gesture { FTFinger.hold.move }`(画面に対する比率)
    private static func dragStep(_ command: ApiLiveServeCommand, platform: String?, screen: FTRect?) -> FlowStep? {
        guard let fromX = command.fromX, let fromY = command.fromY,
              let toX = command.toX, let toY = command.toY else { return nil }
        let press = command.press ?? ApiLiveGestureDefaults.dragPressSeconds
        let duration = command.duration ?? ApiLiveGestureDefaults.dragDurationSeconds
        if press < longPressThresholdSeconds(platform: platform) {
            var step = FlowStep(action: "swipePointToPoint",
                                duration: duration == FlowStep.defaultSwipeDurationSeconds ? nil : seconds(duration),
                                maxGestureSeconds: command.maxGestureSeconds,
                                x: point(fromX), y: point(fromY), toX: point(toX), toY: point(toY))
            step.note = DraftNotes.coordinates
            return step
        }
        guard let screen else { return nil }
        let finger = FTFinger(x: fromX, y: fromY)
            .hold(seconds: press)
            .move(x: toX, y: toY, durationSeconds: duration)
        var step = FlowStep(action: "gesture")
        step.gesture = TouchGesture.ratioFingers([finger], screen: screen)
        guard !(step.gesture ?? []).isEmpty else { return nil }
        // 静止 + 移動の合計が既定の上限を超えたら、その秒数を上書きとして書く(書かないと貼った先の DSL が断る。
        // 拡張は静止を 3 秒・移動を 8 秒で切るので合計は 11 秒まで = 上書きの天井には届かない)
        let total = press + duration
        step.maxGestureSeconds = command.maxGestureSeconds
            ?? (total > BridgeAPI.defaultMaxGestureSeconds ? total.rounded(.up) : nil)
        return step
    }
}
