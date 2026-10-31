// StepExecutor+ScrollSearch.swift
// スクロール探索(runScrollSearch とその注記・ジャンプ計算)。本体は StepExecutor.swift(instance 状態はそちらに置く)

import Foundation

/// 半開きボトムシートの幾何判定の唯一の定義元。**判定は1箇所** —— `scrollFrame` 明示時
/// (対象の容器そのもの)と未指定時(申告された scrollable 要素からの推測)のどちらもここを通す。
///
/// 高さ比だけの判定(容器の高さが画面の 15〜80%)は**位置を見ない**ため、下端が画面下端から離れた
/// 固定高リストや、シートの無い通常画面の容器にも同じ高さ比のものがあり誤って発火する
/// (実測: 逆走査で見つかった探索・シートの無いホーム画面の `tap` の両方に
/// `sheet-collapsed` が付いた)。ボトムシートは「下端が画面下端に接し、上端が画面の上のほうに
/// 無い」という**位置**が本質なので、これを主判定にする
public enum SheetGeometry {
    /// 下端が画面下端からこれ以上離れていたら「別の chrome(タブバー等)が下に居る」とみなし
    /// 対象外にする(pt/dp)。根拠: iOS のホームインジケータの標準セーフエリアが 34pt
    /// (`BridgeDTO.bottomChromeClearance` の内訳と同じ実測系列)—— これを超える隙間は
    /// 「シートが画面下端まで伸びていない」ことの印であって、量子化の揺らぎではない
    public static let bottomEdgeTolerance: Double = 34
    /// 上端がこの比率より上(画面の上のほう)にあれば全画面寄りの容器とみなし対象外にする。
    /// 半開きシートは画面下半分から現れるものなので、上から 1/4 より上に上端があるなら
    /// 「シートというより本文そのもの」と判定する
    public static let topMinRatioOfScreen: Double = 0.25

    /// 1つの矩形が半開きボトムシートの幾何に合うか
    public static func looksLikeBottomSheet(frame: FTRect, screen: FTRect) -> Bool {
        guard screen.height > 0 else { return false }
        let bottomGap = (screen.y + screen.height) - (frame.y + frame.height)
        guard bottomGap <= bottomEdgeTolerance else { return false }
        return (frame.y - screen.y) > screen.height * topMinRatioOfScreen
    }

    /// `scrollFrame` 未指定のときの、**申告された(scrollable)容器だけ**からの判定
    /// (推測まで混ぜると全画面リストでも鳴る)
    public static func declaredSheetExists(in snapshot: SnapshotResponse) -> Bool {
        snapshot.elements.contains {
            $0.scrollable == true && looksLikeBottomSheet(frame: $0.frame, screen: snapshot.screen)
        }
    }
}

extension StepExecutor {
    /// 半開のボトムシートの中で止まった探索の総称ヒント(失敗文の末尾)。**MCP はシート展開の救済を撃った回にこれを
    /// 失敗文から外す**(救済が同じことを試して結果を名指ししているので、残すと「3回目もうまくいかない」の直後に
    /// 「広げて再試行」と言う矛盾になる = 計測で指摘)
    public static let halfOpenSheetHint = " If the list sits inside a half-open bottom sheet, expand the sheet first"
        + " (drag its grabber upward) and retry."


    struct ScrollSearchResult {
        var found: Bool
        /// 解決に使ったフォールバック節(プライマリで解決したら nil)
        var fallback: FlowLocator?
        /// 1回でも XCUITest 経由で swipe したか(記録の注記に載せる)
        let viaXCUITest: Bool
        /// スクロールヒントで置き換えた長距離ドラッグの回数(記録の注記に載せる)
        let hintJumps: Int
        /// 探索終端の静止待ちが**収束せずに打ち切られた**。黙って返すと「動いている画面で
        /// 掴んだ座標」を後段がタップすることになり、失敗は沈黙(誤った成功)として現れる
        var settleCapped: Bool = false
        /// 実際に撃ったスワイプ数(見つからなかったときの理由文に使う)
        var swipes: Int = 0
        /// **もう動かないので上限より手前で打ち切った**。上限まで振り続けても結果は変わらないため
        var stoppedUnmoving: Bool = false
        /// 探索中に木が**一度でも変わったか**。`stoppedUnmoving` の2形を分けるためだけに持つ:
        /// true = スクロールできていて末尾に着いた / false = 最初から1度も動いていない
        /// (指が容器の外・上に重なったモーダル・そもそもスクロールしない画面)。
        /// **この区別が無いと「stopped early」としか言えず**、末尾に着いただけの回を
        /// 「途中で諦めた」と読ませて maxSwipes の引き上げを繰り返させる
        var contentEverMoved: Bool = false
        /// 上限の本数を使い切るまで中身が動いていた(= 端に着いていない)。`stoppedUnmoving` が偽の失敗文で
        /// 「上限を上げれば届くかもしれない」と言うための印(上げても無駄と言う枝と取り違えない)
        var exhaustedWhileMoving: Bool = false
        /// 探索の途中で画面の大きさが変わった(回転)。端とも「動かなかった」とも言わず、向きが変わったと言う
        var screenResized: Bool = false
        /// 逆走査(slowDrag 最大 `reverseSweepMaxSwipes` 本・`swipes` に数えない)を**1本以上撃てた**か(`reverseSweepDragsSent`。見つけた回は found が真なので
        /// 文言は読まない)。失敗文が「after N scroll(s)」と言うだけだと、直後に反対向きへ遅いドラッグが走り画面が
        /// 動いたこと・所要時間の大半がそれであることが読み手に見えない
        var reverseSweepRan: Bool = false
        /// 端まで来ても見つからず、**逆向きの細刻みで拾い直した**回数(0 か 1。注記に載せる)
        var reverseSweeps: Int = 0
        /// 拾い直しに使った容器を**そのまま書けるセレクタ**にしたもの(nil = 名指しできない)。
        /// 注記で `scrollFrame:` を勧めるときに実物の名前を出すために持つ
        var suggestedScrollFrame: String?
        /// `step.scrollFrame` が明示されているのに、探索開始時点(または探索中)の snapshot で
        /// 1件も解決できず、**スワイプを1本も送らずに**打ち切った。全画面スワイプへ黙って
        /// 退化すると画面上の別の物(カードのボタン等)を発火させ得るための fail-fast
        var scrollFrameMissing: Bool = false
        /// `stoppedUnmoving` の時点で、明示 scrollFrame が画面高の80%未満しかない(半開シート等)。
        /// シート展開ヒント(scrollNotFoundMessage)を**全画面リストの末尾到達**にまで出さないためのゲート
        var containerIsPartialHeight: Bool = false
        /// 探索の**どこか1周でも**木が要素上限で打ち切られていた件数の最大。
        ///
        /// **最終木だけを見ても分からない**(ブラウザ監査): 目的の行が画面に
        /// 入っていた周回では打ち切られていても、探索が通り過ぎた先の最終画面は上限に
        /// 当たらないことがある。そのとき失敗文は「見つからない」としか言わず、
        /// **実在する行を探し続ける**。最終木だけで判定していたため、実測の2回のうち
        /// 1回はこの警告が出ないままだった
        var maxTruncatedDuringSearch: Int = 0
        /// `stoppedUnmoving` 判定時点の実効キーボード矩形(chrome 込み。`KeyboardOcclusion`)。
        /// nil = キーボード非表示。**`!contentEverMoved` のときだけ**
        /// scrollNotFoundMessage が読む ——
        /// ソフトキーボードの上でスワイプすると始点がキー面に乗って「1度も動かなかった」に
        /// 見えるため(ScrollGeometry.viewport 参照)、その主因を名指しする
        var keyboardFrame: FTRect? = nil
        /// `scrollFrame` 未指定で全画面探索したときだけ埋める —— 探索方向に合う
        /// (縦横比から推定)、書けるセレクタを持つスクロール容器が木にあったら、その名前。
        /// found の成否に関わらず埋まりうる(失敗文が「scrollFrame: を検討しろ」と
        /// 具体名で言うための材料。`suggestedScrollFrame` とは別 —— あちらは reverseSweeps が
        /// 実際に拾い直した容器、こちらは探索を試す前から木にあった宣言候補)
        var directionMatchedScrollFrameCandidate: String?
        /// 明示 scrollFrame の容器が**探索の軸と違う軸にしか動かない**(横の一覧を縦に払った等)と木から言える。
        /// `stoppedUnmoving` の文が縦の逆向きを勧める誤誘導を避けるためだけに持つ(`scrollFrameRunsOtherAxis`)
        var scrollFrameOtherAxis: Bool = false
        /// 「動かなくなった」と判定した時点で、**探索の対象のアプリが前面に居なかった**ときの前面の名前
        /// (iOS で前面を答えられないドライバでは "another app")。nil = 前面に居た・確かめられなかった。
        /// 木が変わらない理由が「端」ではなく「前面を奪われた」だったのに、失敗文が端と言い切っていた
        var appLeftForeground: String? = nil
        /// 見つけた要素(found のときだけ)。scrollTo が「掴んだ要素」として返す
        /// (無いと DSL の `scrollTo` が lastElement を空で上書きしていた)
        var element: ElementInfo? = nil
    }

    /// **半開きシートを広げるドラッグ**(探索が半開きシートの中で1度も動かずに止まったときに1回だけ撃つ)。
    /// 探索の送りは短く遅い(容器基準・速度 50pt/s)ので、一覧の上の払いを先にシートの伸縮へ使う作り
    /// (Compose の ModalBottomSheet・SwiftUI の detents)では、しきい値に届かず元の高さへ戻って「動かない」になる
    /// (E2EY-CMP のシート S0020・XCUITest: 64pt を 1.3 秒で払って毎回戻った。同じ容器の中で 166pt を 0.3 秒で払うと
    /// 全開になった)。始点は容器の下端(画面下端の a11y 空白帯は避ける)・終点は容器の上端 = 容器の高さぶん。
    /// **利用者が scrollFrame で指した容器の中だけを払う**(当てずっぽうに画面を動かさない)。
    /// 払える距離が無ければ nil
    /// `bottomGestureBand` は Android の下端のジェスチャ帯の高さ(px。iOS・3 ボタンは 0)。**帯の中から払うとホームへ抜ける**
    /// (E2EY-Flutter のシート S0020: 床が iOS の pt の空白帯 48 のままで、Android の px の木では帯 84px の中 = y 2375 から払い、
    /// ランチャーが前面になった)ので、大きいほうを床にする
    static func sheetExpandDrag(container: FTRect, screen: FTRect,
                                bottomGestureBand: Double) -> (x: Double, fromY: Double, toY: Double)? {
        let fromY = min(container.y + container.height - 1,
                        screen.y + screen.height - max(bottomUncoveredBand, bottomGestureBand) - 1)
        let toY = container.y + 1
        guard fromY - toY >= minSheetExpandDistance else { return nil }
        return (container.x + container.width / 2, fromY, toY)
    }

    /// 進む先の縁に付いた要素を送り直す量(容器の送る向きの長さに対する比)。縁から出始めた要素の先頭が中央へ来る = 半分。
    /// これより大きいと先頭が反対側の縁へ寄り、慣性が無くても次の判定で再び縁に付きうる
    static let leadingEdgeNudgeRatio: Double = 0.5
    /// 送り直す見えている厚みの上限(pt/dp。Android は `pointScale` で px へ)。根拠: 指で押せる大きさ(Apple の 44pt・Material の 48dp の
    /// 小さいほう)。これ以上見えていれば中心を押して届く
    static let leadingEdgeNudgeMinVisiblePt: Double = 44

    /// 広げるドラッグの所要(秒)。根拠は sheetExpandDrag の doc の実測(0.3 秒で全開・探索の 1.3 秒では戻った)
    static let sheetExpandDragSeconds: Double = 0.3
    /// これより払える距離が短ければ撃たない(pt)。探索の1本(実測 64pt)より短い払いでは広げられない
    static let minSheetExpandDistance: Double = 64

    /// 探索の注記を組み立てつつ、**機械可読コードを今のステップへ記録する**。
    /// 探索の打ち切りは文言が別(「after the search」)だが `settleCapped` として同じ棚で数える ——
    /// 集計側の関心は「動いている画面のまま進んだか」で、どの経路で起きたかではない
    func recordedScrollSearchNote(_ result: ScrollSearchResult,
                                  scrollFrameNote: String? = nil) -> String? {
        scrollSwipesThisStep = result.swipes
        if result.settleCapped { noteCodesThisStep.insert(.settleCapped) }
        if result.scrollFrameMissing { noteCodesThisStep.insert(.scrollFrameMissing) }
        // 文言側のシート展開ヒント(scrollNotFoundMessage)と**同じ条件**を機械可読で出す。
        // 片方だけ変えない —— MCP はこのコードで自動展開へ分岐する。
        // [F7b] **見つかった回には出さない** —— 端で一度 stoppedUnmoving になっても、その後の
        // 逆走査(reverseSweep)で見つかれば `result.found` が立つが `stoppedUnmoving` /
        // `containerIsPartialHeight` は立てたまま返る(このファイル下方の reverseSweep 経路参照)。
        // 通った探索に「シートを広げろ」を付けると読み手を誤誘導する
        if !result.found, result.stoppedUnmoving, result.containerIsPartialHeight {
            noteCodesThisStep.insert(.sheetCollapsed)
        }
        // **見つかった回には出さない**: 打ち切りが害になるのは「不在」と読まれる回だけで、
        // 成功した探索にまで付けると毎回出る注記になる(StepNote の採用基準に反する)
        if !result.found, result.maxTruncatedDuringSearch > 0 {
            noteCodesThisStep.insert(.truncatedDuringSearch)
        }
        return Self.scrollSearchNote(result, scrollFrameNote: scrollFrameNote)
    }

    /// スクロール探索の注記(XCUITest フォールバック / ヒント跳躍)。無ければ nil
    static func scrollSearchNote(_ result: ScrollSearchResult,
                                 scrollFrameNote: String? = nil) -> String? {
        var parts: [String] = []
        if result.viaXCUITest { parts.append("fell back to XCUITest") }
        if result.hintJumps > 0 { parts.append("\(result.hintJumps) long drag(s) from scroll hints") }
        if result.settleCapped { parts.append("the screen did not settle after the search (poll limit)") }
        // **黙って拾い直さない**: 順方向で飛び越したことは利用者の書き方(scrollFrame 未指定)に
        // 由来するので、逆走査で救えたことを見せて `scrollFrame` を書く判断材料にする
        if result.reverseSweeps > 0 {
            // **具体名まで出す**: 総称の「scrollFrame を書け」だけだと、読み手は容器の名前を
            // 探すためにスナップショットを撮り直すことになる(困った瞬間に答えを渡す)
            let how = result.suggestedScrollFrame.map { "specify scrollFrame: \($0)" }
                ?? "specify scrollFrame:"
            parts.append("found by sweeping back after overshooting it"
                + " (\(how) to step within the container instead)")
        }
        if let scrollFrameNote { parts.append(scrollFrameNote) }
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }

    /// `select` が掴めなかったときの skip 理由。**失敗ではない**(DSL は空要素を返す)ので、
    /// 読み手が「見つからないのに緑」と誤読しないよう理由文で契約を名乗る
    static let selectNotFoundReason = "element not found; select returned an empty element"

    /// `defaultMaxSwipes`: step に上限が無いときの既定(呼び手の `tunables.defaultMaxSwipes`)
    static func scrollNotFoundMessage(_ step: FlowStep,
                                      _ result: ScrollSearchResult? = nil,
                                      defaultMaxSwipes: Int) -> String {
        // **fail-fast は別の文**: 実際にはスワイプを1本も送っていないので、通常の
        // 「N 回振って見つからなかった」は嘘になる
        if result?.scrollFrameMissing == true {
            let base = Self.scrollFrameFailFastMessage(step, action: "search", swipes: result?.swipes ?? 0)
            guard let front = result?.appLeftForeground else { return base }
            return base + " The app was not in the foreground at that point (\(front) was in front: the screen went off,"
                + " a shade or another app came up), so the container did not vanish from the app — \(bringBackAdvice(front: front))."
        }
        let direction = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
        let vertical = direction == .up || direction == .down
        let limit = max(0, step.maxSwipes ?? defaultMaxSwipes)
        // 打ち切ったときは**実際の回数**を出す(上限を名乗ると「8回も振ったのに」と読めてしまう)
        let swipes = result?.stoppedUnmoving == true || result?.appLeftForeground != nil || result?.screenResized == true
            ? (result?.swipes ?? limit) : limit
        // **「stopped early」と言わない**。旧文言は「途中で諦めた」としか
        // 読めず、実際には**リストの末尾に着いていた**回(iOS の設定アプリで実測)を欠陥と
        // 受け取らせ、maxSwipes を上げた再試行を誘っていた。上げても結果は変わらないので明言する。
        // **2形を分ける**: `contentEverMoved`(順方向)で「動いた末の停止」か「1度も動かなかった」か。
        // 後者では逆走査を撃たない(runScrollSearch の guard)ので、反対側は探していないと言う
        let stopped: String
        if let front = result?.appLeftForeground {
            // 端とも「何も動かなかった」とも言わない: 前面が別のアプリになった間の払いは、木が変わらないだけで端の証拠にならない
            stopped = " (the app was not in the foreground when the search stopped — \(front) was in front — so the"
                + " screen did not show where the list ends; \(bringBackAdvice(front: front)))"
        } else if result?.stoppedUnmoving == true {
            if result?.contentEverMoved == true {
                stopped = " (the scroll area reached its end — the content stopped moving,"
                    + " so raising maxSwipes will not help)"
            } else {
                // 何も動かなかったとき、スワイプが領域に届いていないのか、既にその向きの端なのかは
                // ツールには区別できない(どちらも木が変わらない)。帰属を断定せず両方を事実として言う
                // 反対側は探していないので、向きを名指しして書き直せるようにする。`direction` は指の向き =
                // 反対の**スクロールの向き**はその rawValue そのもの。引数名はコマンドで違う(scrollTo = `direction:` /
                // tap・exist 等 = `scroll:`。MCP の ft_scroll_to は `direction`、ft_batch は DSL の行なので同じ名前で通じる)
                let oppositeArgument = step.action == "scrollTo" ? "direction" : "scroll"
                // **渡した容器が別の軸にしか動かないなら、逆向きを勧めない**(横の一覧に縦の逆向きを勧めても動かない)。
                // 軸の向きは一覧の並びから言うだけで、どちらへ送るかは対象の側による
                let tail = result?.scrollFrameOtherAxis == true
                    ? "the scrollFrame container scrolls \(vertical ? "horizontally" : "vertically"), not \(vertical ? "vertically" : "horizontally"),"
                        + " so search along its own axis with \(oppositeArgument): \(vertical ? ".left / .right" : ".up / .down")"
                    : "the opposite direction was not searched — if the element"
                        + " is on that side, search with \(oppositeArgument): .\(direction.rawValue)"
                stopped = " (nothing moved at all during the search — either the swipes did not reach a"
                    + " scrolling area or it was already at its end in this direction; the tool cannot tell which,"
                    + " and raising maxSwipes will not help; \(tail))"
            }
        } else if result?.screenResized == true {
            stopped = " (the screen size changed during the search — the device was probably rotated — so the layout and"
                + " the scroll area moved; nothing is known about the end of the list; take a fresh snapshot and search again)"
        } else if result?.exhaustedWhileMoving == true, result?.scrollFrameOtherAxis != true {
            // 天井では「上げろ」と言わない(MCP の入口が断る)
            stopped = " (the content was still moving when the last swipe was used, so the end was not reached —"
                + (Double(limit) >= ArgumentBounds.swipeCountCeiling
                    ? " \(limit) swipes is the ceiling: scroll part of the way first, or search from nearer the target)"
                    : " raise maxSwipes (now \(limit)) to search further)")
        } else {
            stopped = ""
        }
        // **シート展開のヒント**: 半開ボトムシート内のリストは容器が動いても中身は動かず、
        // 「動かなくなった」だけでは利用者がシートの状態に気付けない(Google マップで実測)。
        // **全画面リストの末尾到達には出さない**(containerIsPartialHeight)。
        // **縦方向の探索のときだけ**(ボトムシートは縦の概念。`tap(scroll: .right)` 等の
        // 横方向探索にまで出すと、画面のどこかに無関係な縦シートがあるだけで誤誘導になる ——
        // `containerIsPartialHeight` は scrollContainer が解決できないと画面全体から
        // シート的な容器の有無だけを見て決めるため、探索方向を問わず true になり得た)
        let sheetHint = vertical && result?.stoppedUnmoving == true
            && result?.containerIsPartialHeight == true
            ? Self.halfOpenSheetHint
            : ""
        // `scrollFrame` を指定していれば全画面探索はそもそも起きない = 未指定のときだけ
        // 埋まる(ScrollSearchResult.directionMatchedScrollFrameCandidate の doc)。
        // 画面に探索方向へ動かせそうな容器が申告されているのに、全画面スワイプだけを繰り返して
        // 「シートを広げろ」「端に着いた」と的外れに言っていた場合の案内
        // **`scrollFrame:` を取るのは scrollTo だけ**(tap / exist の `scroll:` は取らず、書くと
        // 「has no scrollFrame: parameter」で落ちる)。それ以外は withScroll*(scrollFrame:) { } を勧める
        let takesScrollFrame = step.action == "scrollTo"
        // 貼ってそのまま書けるブロック名(`direction` は指の向き = スクロールの向きはその逆。FTScrollDirection.swipe と対)
        let withScrollBlock: String = switch direction {
        case .up: "withScrollDown"
        case .down: "withScrollUp"
        case .left: "withScrollRight"
        case .right: "withScrollLeft"
        }
        let scrollFrameHint = result?.directionMatchedScrollFrameCandidate.map {
            takesScrollFrame
                ? " A scroll area matching this direction is declared on screen (scrollFrame: \(ScenarioCodeGen.literal($0)))"
                    + " — consider passing scrollFrame: to search inside it instead of the whole screen."
                : " A scroll area matching this direction is declared on screen (scrollFrame: \(ScenarioCodeGen.literal($0)))"
                    + " — consider wrapping the step in \(withScrollBlock)(scrollFrame: \(ScenarioCodeGen.literal($0))) { }"
                    + " to search inside it instead of the whole screen."
        } ?? ""
        // **キーボードが主因の可能性を名指しする**: swipe の始点は画面全体の固定比率で作られるため、
        // ソフトキーボードの上で振ると始点がキー面に乗って何も動かない(キーボードは常にタッチを
        // 飲む)。**1度も動かなかった回にだけ出す**(`!contentEverMoved`)——
        // 末尾に着いた回はキーボードと無関係
        var keyboardHint = ""
        if result?.stoppedUnmoving == true, result?.contentEverMoved == false,
           let kb = result?.keyboardFrame {
            keyboardHint = ": the soft keyboard covers (\(Int(kb.x)),\(Int(kb.y))"
                + " \(Int(kb.width))x\(Int(kb.height))); pass scrollFrame or close the keyboard"
        }
        // 逆走査を撃った失敗だけ(数に入らない遅いドラッグが走り、画面が戻されていることを見せる)。
        // **「reached its end」「not reaching a scrolling area」を含めない**: 順方向の事実を言う別の分岐の語
        let sweepNote = result?.reverseSweepRan == true
            ? " (then a reverse sweep of up to \(Self.reverseSweepMaxSwipes) slow drags the opposite way"
              + " (not counted in the \(swipes) above) also found nothing, so the screen is left at the swept-back position)"
            : ""
        // 入れ子で外側の一覧が動いた失敗(動かなかった形は上の stopped が言う)。払いが届いたのは scrollFrame ではない
        let otherAxisNote = result?.scrollFrameOtherAxis == true && result?.stoppedUnmoving != true
            ? " (the scrollFrame container scrolls \(vertical ? "horizontally" : "vertically"), not \(vertical ? "vertically" : "horizontally"):"
              + " the swipes moved the enclosing scroll area, not the scrollFrame — search along its own axis with"
              + " \(step.action == "scrollTo" ? "direction" : "scroll"): \(vertical ? ".left / .right" : ".up / .down"))"
            : ""
        return "element not found after \(swipes) scroll(s)\(stopped)\(otherAxisNote)\(sweepNote): \(step.locatorSummary)"
            + sheetHint + keyboardHint + scrollFrameHint
    }

    /// 明示した scrollFrame(rect か解決できる locator)の枠。名指しが無い・解決できないは nil(= 木全体を比べる)。
    /// `scrollContainer` と違い注記(`pendingScrollFrameNote`)を積まない
    static func explicitScrollFrameRegion(_ step: FlowStep, in snapshot: SnapshotResponse) -> FTRect? {
        if let rect = step.scrollFrameRect { return rect }
        guard let locator = step.scrollFrame else { return nil }
        return LocatorResolver.match(locator, in: snapshot)?.frame
    }

    /// 探索が「動いたか」を比べる領域。名指しの scrollFrame → 無ければブリッジが払う画面中央の下にある申告済みのスクロール容器
    /// (軸に合う最小のもの = `scrollContainerElement`) → 無ければ形から採った容器(`overflowingContainer`)のうち画面中央を含むもの
    /// (中央を含まない容器は入れ子の横カルーセルなどで、払いの当たらない所の動きだけを見てしまう)。
    /// どれも無ければ nil = 木全体。容器の外の動き続ける表示(時計・ティッカー)を「動いた」と数えないための領域
    static func searchContentRegion(_ step: FlowStep, in snapshot: SnapshotResponse) -> FTRect? {
        if let explicit = explicitScrollFrameRegion(step, in: snapshot) { return explicit }
        if step.scrollFrame != nil { return nil }
        let finger = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
        let vertical = finger == .up || finger == .down
        if let declared = scrollContainerElement(step: step, in: snapshot, vertical: vertical) { return declared.frame }
        guard let shaped = overflowingContainer(in: snapshot),
              frame(shaped, containsX: snapshot.screen.centerX, y: snapshot.screen.centerY) else { return nil }
        return shaped
    }

    /// 2つの木が探索の比べる領域(`searchContentRegion`)の中で同じ内容か。ft_swipe の「慣性が収まったか」の判定が共有する
    public static func sameContentInSearchRegion(_ step: FlowStep, _ a: SnapshotResponse, _ b: SnapshotResponse) -> Bool {
        sameContent(elementsInside(searchContentRegion(step, in: a), a.elements),
                    elementsInside(searchContentRegion(step, in: b), b.elements))
    }

    /// 中心が `region` の中にある要素だけ(nil = 全部)
    static func elementsInside(_ region: FTRect?, _ elements: [ElementInfo]) -> [ElementInfo] {
        guard let region else { return elements }
        return elements.filter { frame(region, containsX: $0.frame.centerX, y: $0.frame.centerY) }
    }

    /// 探索の対象のアプリ(`sessionBundleID`)が前面に居ないとき、前面(または覆っている面)の呼び名を返す。居る・確かめられない
    /// (ドライバが答えない・照会が失敗)は nil = 従来どおり端の判定へ進む(嘘を足さない)。
    /// 前面を名指しできないドライバ(iOS)は `isAppForeground` だけで判断し、名前は "another app"。
    /// `tree` = 打ち切る時点の木。Android はシェード/ロック画面の下でも前面のアプリ名が下のアプリのままなので、
    /// 木が systemui のものなら木の種別で言う(費用ゼロ)。iOS の覆い(通知センター・スイッチャー等)は
    /// `systemUICovering` を1回聞く。`asksAppState: false` = 前面の名前・木・覆いだけで言う(/appstate の「前面ではない」は聞かない。
    /// 成功が正の経路(scrollToEdge)で、名前を言えない iOS の `false` を失敗に倒さないため)(打ち切りの1回だけ。毎手の照会ではない = OI-46)
    func frontAppIfSessionAppLeft(_ sessionBundleID: String?, tree: SnapshotResponse? = nil,
                                  asksAppState: Bool = true) async -> String? {
        guard let bundleID = sessionBundleID, !bundleID.isEmpty else { return nil }
        // 判定は ForegroundState.judge
        var facts = ForegroundFacts(launched: nil, sessionBundleID: bundleID)
        if let tree, let treeSession = tree.sessionBundleID, treeSession != bundleID,
           ForegroundState.systemDialogPackages.contains(treeSession) {
            facts.sessionBundleID = treeSession
            facts.tree = SystemUITreeKind.classify(sessionBundleID: treeSession, identifiers: tree.elements.map(\.identifier))
        }
        facts.front = await ForegroundState.frontProbe(driver)
        if asksAppState, facts.front.value == nil {
            facts.sessionInForeground = await ForegroundState.inForegroundProbe(driver, bundleID: bundleID)
        }
        facts.covering = await ForegroundState.coveringProbe(driver)
        switch ForegroundState.judge(facts) {
        case .otherApp(let name): return name ?? "another app"
        case .dialog(let package): return package == bundleID ? nil : package
        case .covered(let surface): return surface.displayName
        case .locked: return ForegroundState.lockScreenName
        default: return nil
        }
    }

    /// `frontAppIfSessionAppLeft` の答えに続ける対処。**前面がシステムのダイアログなら launch を勧めない**
    /// (launch はアプリを起こし直してダイアログを画面に残す = ループ)。覆い・ロック画面(「the …」)は閉じるのが先
    static func bringBackAdvice(front: String) -> String {
        if ForegroundState.systemDialogPackages.contains(front) {
            return "operate or dismiss that dialog first (launch restarts the app and leaves the dialog on screen), then search again"
        }
        if front.hasPrefix("the ") || front.hasPrefix("Control Center") || front.hasPrefix("a system surface") {
            return "dismiss it first (Android: back closes a shade, a locked screen needs unlocking; iOS: swipe up from the bottom edge"
                + " or press home), then search again"
        }
        return "bring the app back with launch and search again"
    }

    /// 失敗経路で「覆われた」と言う前に、アプリが前面を離れていた事実があれば添える。
    /// 緑の経路では呼ばない(読みを足さない)。前面を読めない・アプリのままなら空
    func leftForegroundSuffix(_ sessionBundleID: String?) async -> String {
        guard let front = await frontAppIfSessionAppLeft(sessionBundleID) else { return "" }
        return " (the app was not in the foreground when this failed — \(front) was in front, so the target was not"
            + " covered by the app's own UI: \(Self.bringBackAdvice(front: front)))"
    }

    /// `notExist(scroll:)` の裏返し: スクロール探索中に見つかってしまったら不在検証は失敗
    /// (executeAssertNotExists の scroll-search prelude が使う。scrollNotFoundMessage の対)
    static func scrollFoundMessage(_ step: FlowStep) -> String {
        "element found via scroll search: \(step.locatorSummary)"
    }

    /// 明示 scrollFrame が「解決できない」ことの判定。**scrollContainer には委ねない** ——
    /// scrollContainer は殺しスイッチ(`FT_SCROLL_TARGET=legacy`)のとき常に nil を返すため、
    /// それを fail-fast の根拠にすると legacy 指定時に「セレクタが実在するのに matched nothing」
    /// と誤判定する。殺しスイッチ有効時は判定自体をスキップし、legacy 挙動へ流す。
    /// runScrollSearch(scrollTo/exist/notExist 系)と scroll/scrollToEdge/flick の両方から呼ぶ
    static func scrollFrameUnresolved(_ step: FlowStep, in snapshot: SnapshotResponse) -> Bool {
        guard Self.coordinateScrollEnabled, let locator = step.scrollFrame else { return false }
        return LocatorResolver.match(locator, in: snapshot) == nil
    }

    /// 明示 scrollFrame が解決できないときの fail-fast 文言。呼び手ごとに動詞(action)を渡す
    /// (scrollTo/exist/notExist 系="search"・scroll/scrollToEdge="swipe"・flick="flick")。
    /// **`swipes > 0`(容器が解決していたのに送信中に消えた)なら文言を差し替える** ——
    /// スワイプ送信後にも「送られなかった」と言うのは嘘になるため
    static func scrollFrameFailFastMessage(_ step: FlowStep, action: String, swipes: Int) -> String {
        let sel = step.scrollFrame?.summary ?? "?"
        guard swipes > 0 else {
            let verb = action == "search" ? "the search was not run" : "the \(action) was not sent"
            return "scrollFrame \"\(sel)\" matched nothing on this screen, so \(verb) —"
                + " a whole-screen swipe could tap something under the finger."
                + " Fix the scrollFrame selector, or remove it to search the whole screen."
        }
        return "scrollFrame \"\(sel)\" disappeared from the tree after \(swipes) swipe(s),"
            + " so the search stopped."
    }

    /// スクロールヒント(WebView の画面外ノード・実座標付き)から「あと何 px 先か」を出す。
    ///
    /// **なぜ**: スクロール探索の支配項はスワイプ1回のジェスチャ時間(Android 実測 1.05s / 974px。
    /// スナップショットは 25ms)。距離が分かれば、固定幅スワイプ N 回を少数の長距離ドラッグに
    /// 置き換えられる(1500px を 0.44s)。ヒントは Android の WebView だけが供給する
    /// (Chromium が全ドキュメントをツリーに載せる。ネイティブのリストは画面外を載せないため、
    /// **ヒントが無いことは不在の根拠にならない** = 通常の探索ループの代替であって不在の即断には使わない)。
    ///
    /// 戻り値: 正 = 指を上へ(内容を下へ読み進める)動かす px。ヒント不一致・方向不一致・
    /// 水平方向・既に画面内なら nil(呼び手は通常のスワイプに落ちる)。
    /// 呼び手はスナップショットごとに再計算する(ドラッグの実移動はフリングで揺れるが、
    /// 毎回測り直す自己補正で収束する。較正は持たない)
    static func offscreenJump(step: FlowStep, snapshot: SnapshotResponse,
                              finger: FTSwipeDirection) -> Double? {
        guard finger == .up || finger == .down,
              let hints = snapshot.offscreen, !hints.isEmpty else { return nil }
        let pseudo = SnapshotResponse(sessionBundleID: nil, screen: snapshot.screen,
                                      elements: hints, truncatedCount: 0)
        guard let (hint, _) = LocatorResolver.resolve(step: step, in: pseudo, strictForAssert: true) else {
            return nil
        }
        let screen = snapshot.screen
        // 着地目標: 要素の上端を画面の 40% 位置へ(中央より上 = 下端の固定要素・タブに重ねない)
        let jump = hint.frame.y - (screen.y + screen.height * 0.4)
        // 方向が合っているときだけ(逆向きのヒントで往復しない。ドラッグ過走の戻しは
        // ここではなく通常ループの資格 = 見えたら resolve が拾う、に任せる)
        if finger == .up, jump > screen.height * 0.3 { return jump }
        if finger == .down, jump < -screen.height * 0.3 { return jump }
        return nil
    }

    /// scrollToEdge が端を確定してよいのは、見えている中身が最後に変わってからこの時間が経った後だけ
    /// (「不変」の判定とドライバの端申告の両方に掛ける)。根拠は RN の FlatList(in-app)の実測: 端へ飛んでから
    /// 窓の外に続きを描き足すまで 0.4〜0.7 秒(0.4 秒後の送りは余地が無く、0.7 秒後の送りは先へ進んだ)。
    /// 1.0 = 0.7 + 余裕。費用は速い経路(in-app / CDP)が本当の端に着いたときの最大 1.0 秒で、実スワイプ
    /// (XCUITest / Android)は1本で1秒近くかかるのでふつう払わない。一度も変わっていない(送る前から端)
    /// ときは待たない。尽きたとき(描き足しが 1.0 秒を超える)は途中で端と確定し、後段の exist が
    /// 「送った先に無い」で落ちる
    static let edgeClaimGraceAfterMove: Duration = .milliseconds(1000)
    /// 利用者の `waitSeconds:` の間、何も動かない探索が次の1本を送るまでの間隔(`edgeClaimGraceAfterMove` の半分)。
    /// 上限は `waitSeconds` 自身。尽きたら従来の「nothing moved at all」を言う(予算を使い切った事実が失敗文の所要時間に出る)
    static let unmovedBudgetPollInterval: Duration = .milliseconds(500)

    /// `scrollToEdge` が端と認めるまでに必要な「署名が不変だった周回数」。
    ///
    /// 既定は **2**。Android では次のスワイプがフリングの停止だけに消費されて1回空振りすることがあり、
    /// 1回で打ち切ると途中で止まる(実測: scrollToTop が row_22 付近で停止)。
    ///
    /// **ヒントを供給する画面(WebView)だけ 1 に下げる**。`offscreen` はその方向にまだ内容が
    /// あるかの**肯定的な証拠**で、`remainingJump == nil` = 「もう先が無い」。これがあるなら
    /// 署名の不変化を2回重ねる必要はない。
    /// 効くのは iOS xcuitest の WebView で、**端に着いた後に捨てのスワイプを2回撃っていた**
    /// (1スワイプ約2.5秒 = 実測 scrollToTop 中央値 12.1s の主成分。PT-8)。
    /// 供給の無い画面(ネイティブ・旧ブリッジ・inapp-boost モードの WebViewDelegatingDriver)は
    /// `offscreen` が nil なので 2 のまま
    static func unchangedRoundsForEdge(snapshot: SnapshotResponse,
                                       remainingJump: Double?) -> Int {
        guard remainingJump == nil, let hints = snapshot.offscreen, !hints.isEmpty else { return 2 }
        return 1
    }

    /// スクロールヒントの端(その方向にまだ続く実座標の限界)までの距離。scrollToEdge 用。
    /// 正 = 指を上へ。ヒントがその方向に無ければ nil(署名ループへ)
    static func offscreenEdgeJump(snapshot: SnapshotResponse,
                                  finger: FTSwipeDirection) -> Double? {
        guard finger == .up || finger == .down,
              let hints = snapshot.offscreen, !hints.isEmpty else { return nil }
        let screen = snapshot.screen
        // 閾値は小さくてよい(100px): 端スクロールは行き過ぎても端で止まる(クランプされる)ので
        // 過走が無害。scrollTo(offscreenJump)の 30% 閾値とは安全条件が違う
        switch finger {
        case .up:
            // 下端: いちばん下のヒント下端が画面下端に来るまでの残り
            guard let maxBottom = hints.map({ $0.frame.y + $0.frame.height }).max() else { return nil }
            let jump = maxBottom - (screen.y + screen.height)
            return jump > 100 ? jump : nil
        case .down:
            // 上端: いちばん上のヒント上端(負)が画面上端に来るまでの残り
            guard let minTop = hints.map({ $0.frame.y }).min() else { return nil }
            let jump = minTop - screen.y
            return jump < -100 ? jump : nil
        default:
            return nil
        }
    }

    /// 長距離ドラッグの1ジェスチャ分の始点・終点(純粋関数・単体テスト対象)。
    /// container(webView の可視矩形)内で、上下 15% のマージンを避けて縦線上を動かす。
    /// 1ジェスチャで賄えない距離は呼び手のループ(スナップショット→再計算)が刻む。
    ///
    /// **容器は画面と交差させる**(`ScrollGeometry.intersection` と同じ規則)。
    /// 交差を取らないと、画面からはみ出した容器で**画面外の座標を撃つ**ことになる
    /// (WebView が画面より高いときに起き得た。scrollFrame 側と規則を揃えた)
    static func dragGesture(jump: Double, container rawContainer: FTRect,
                            viewport: FTRect? = nil, vertical: Bool = true)
        -> (fromX: Double, fromY: Double, toX: Double, toY: Double)? {
        let container = viewport.flatMap { ScrollGeometry.intersection(rawContainer, $0) }
            ?? rawContainer
        let extent = vertical ? container.height : container.width
        let margin = extent * 0.15
        let usable = extent - margin * 2
        guard usable > 100 else { return nil }
        // 0.9 掛け: フリング分の過走を抑える(過走しても次周回の再計算で戻るが、往復は遅い)
        let distance = min(abs(jump) * 0.9, usable)
        guard distance > 50 else { return nil }
        if vertical {
            let x = container.x + container.width / 2
            if jump > 0 {   // 指を上へ
                let fromY = container.y + container.height - margin
                return (x, fromY, x, fromY - distance)
            }
            let fromY = container.y + margin
            return (x, fromY, x, fromY + distance)
        }
        // 横: y は容器の中心線。jump > 0 = 指を左へ(縦の「+ = 上」と同じ「進む向き」規約)
        let y = container.y + container.height / 2
        if jump > 0 {
            let fromX = container.x + container.width - margin
            return (fromX, y, fromX - distance, y)
        }
        let fromX = container.x + margin
        return (fromX, y, fromX + distance, y)
    }

    /// ヒント跳躍のドラッグ実行。ゆっくり終える(pressSeconds でフリングを抑えつつ、
    /// 距離に応じた duration)。失敗したら false(呼び手は通常のスワイプへ落ちる)
    func hintDrag(jump: Double, container: FTRect, viewport: FTRect,
                          phase: inout PhaseAccumulator) async -> Bool {
        guard let g = Self.dragGesture(jump: jump, container: container,
                                       viewport: viewport) else { return false }
        let clock = ContinuousClock()
        let start = clock.now
        let duration = min(max(abs(g.toY - g.fromY) / 2500, 0.3), 0.7)
        do {
            // **driver.drag を直に呼ばない**(in-app は 501。StepExecutor+Settle の dragWithFallback)
            try await dragWithFallback(fromX: g.fromX, fromY: g.fromY, toX: g.toX, toY: g.toY,
                                       pressSeconds: 0.08, durationSeconds: duration)
            phase.actionMs += Self.ms(clock.now - start)
            return true
        } catch {
            phase.actionMs += Self.ms(clock.now - start)
            return false   // drag 未対応ドライバ等 → このヒントは諦めて通常スワイプ
        }
    }

    /// **フリングを出さないドラッグ**。逆走査専用。hintDrag(0.3〜0.7s)は Android では
    /// まだ速く、189px のドラッグが慣性で 700px 走って**逆向きの飛び越し**になった
    /// (Emulator で観測)。指を離す直前の速度が閾値を下回るよう、
    /// **距離ぶんの時間を必ず取る**(reverseSweepDragSpeed px/s)
    /// `avoidingInputsIn` = 渡したら、始点が入力欄に乗るときにずらす(`dragStartAvoidingTextInputs`。縦だけ)
    func slowDrag(jump: Double, container: FTRect, vertical: Bool = true,
                  avoidingInputsIn elements: [ElementInfo]? = nil,
                  phase: inout PhaseAccumulator) async -> Bool {
        guard var g = Self.dragGesture(jump: jump, container: container,
                                       viewport: container, vertical: vertical) else { return false }
        if vertical, let elements {
            let distance = abs(g.toY - g.fromY)
            guard let fromY = TapTargetGeometry.dragStartAvoidingTextInputs(
                fromY: g.fromY, x: g.fromX, distance: distance, fingerUp: g.toY < g.fromY,
                area: container, elements: elements) else { return false }
            g = (g.fromX, fromY, g.toX, g.toY < g.fromY ? fromY - distance : fromY + distance)
        }
        let clock = ContinuousClock()
        let start = clock.now
        let distance = vertical ? abs(g.toY - g.fromY) : abs(g.toX - g.fromX)
        let duration = min(max(distance / Self.reverseSweepDragSpeed, 0.6), 3.0)
        defer { phase.actionMs += Self.ms(clock.now - start) }
        do {
            // **driver.drag を直に呼ばない**(in-app は 501。StepExecutor+Settle の dragWithFallback)
            try await dragWithFallback(fromX: g.fromX, fromY: g.fromY, toX: g.toX, toY: g.toY,
                                       pressSeconds: 0.15, durationSeconds: duration)
            slowDragsThisStep = (slowDragsThisStep ?? 0) + 1
            return true
        } catch {
            return false
        }
    }

    /// スナップショット中の webView コンテナ(ヒントのドラッグ領域)。無ければ nil
    static func webViewContainer(in snapshot: SnapshotResponse) -> FTRect? {
        snapshot.elements.first(where: { $0.type == "webView" })?.frame
    }

    /// 探索方向に合う、書けるセレクタを持つスクロール容器を木から1つ選ぶ
    /// (`scrollFrame` 未指定の失敗文で名指しするため。`ScrollSearchResult.
    /// directionMatchedScrollFrameCandidate` の doc)。**向きは容器自身の縦横比から推定する**——
    /// scrollable 申告に方向情報は無いため。横スワイプで探しているのに縦長の全画面リストを
    /// 勧めても意味が無い(逆も同じ)。名指しできない(id もラベルも無い)候補は除く
    static func directionMatchedScrollFrameCandidate(in snapshot: SnapshotResponse,
                                                     vertical: Bool) -> String? {
        ScrollFrameCandidates.candidates(in: snapshot).first { candidate in
            guard candidate.selector != nil else { return false }
            // **申告した軸が縦横比に勝つ**: 横向きの低い縦の一覧(2282x411)は縦横比では横の容器に見え、勧められずに終わっていた
            let actions = snapshot.elements.first { $0.ref == candidate.ref }?.scrollActions
            if declaresAxis(actions, vertical: vertical) { return true }
            if declaresOnlyOtherAxis(actions, vertical: vertical) { return false }
            return vertical ? candidate.visible.height >= candidate.visible.width
                            : candidate.visible.width > candidate.visible.height
        }?.selector
    }

    /// 明示 scrollFrame の容器が、探索の軸(`vertical`)と**違う軸にしか動かない**か。申告した向きがあればそれが全て、
    /// 無ければ中の子の並び(同じ段に横へ並ぶ = 横)で言う。**縦横比は使わない**(横向きの低い縦の一覧が横に見える)。
    /// 言い切れなければ false(従来の文言)
    static func scrollFrameRunsOtherAxis(step: FlowStep, in snapshot: SnapshotResponse, vertical: Bool) -> Bool {
        guard step.scrollFrame != nil || step.scrollFrameRect != nil,
              let container = scrollContainerElement(step: step, in: snapshot) else { return false }
        if let actions = container.scrollActions, declaresAxis(actions, vertical: true) || declaresAxis(actions, vertical: false) {
            return declaresOnlyOtherAxis(actions, vertical: vertical)
        }
        let f = container.frame
        let children = snapshot.elements.filter {
            $0.ref != container.ref && $0.frame.width > 0 && $0.frame.height > 0
                && $0.frame.x >= f.x - 1 && $0.frame.y >= f.y - 1
                && $0.frame.x + $0.frame.width <= f.x + f.width + 1 && $0.frame.y + $0.frame.height <= f.y + f.height + 1
        }
        // 3 つ未満では並びと言えない。起点の座標が 2 点以内に揃うのを「同じ段・同じ列」と数える
        guard children.count >= 3 else { return false }
        func spread(_ values: [Double]) -> Double { (values.max() ?? 0) - (values.min() ?? 0) }
        let xs = spread(children.map(\.frame.x)), ys = spread(children.map(\.frame.y))
        let alongX = ys <= 2 && xs > 2, alongY = xs <= 2 && ys > 2
        return vertical ? alongX : alongY
    }

    /// **スクロール探索の本体**。`scrollTo` コマンドと、`tap(scroll:)` / `exist(scroll:)` の
    /// 内蔵探索が共有する(同じ挙動を2箇所に書かない)。見つけたら静止させてから返すので、
    /// 呼び手はそのまま解決・操作してよい
    /// StepExecutor+Assert.swift の executeAssertExists(`exist(scroll:)`)からも呼ぶため internal。
    /// `recoverOnMiss` = 見つからずに端まで来たとき、**逆向きの細刻みで1往復だけ拾い直す**か。
    /// `notExist(scroll:)` の前奏だけは false(見つからないのが期待値なので、往復は丸損)
    func runScrollSearch(step: FlowStep, recoverOnMiss: Bool = true,
                         phase: inout PhaseAccumulator) async throws -> ScrollSearchResult {
        let clock = ContinuousClock()
        let searchStart = clock.now
        let direction = FTSwipeDirection(rawValue: step.direction ?? "") ?? .up
        // 負値だと 0...(-1) が ClosedRange 生成で trap(クラッシュ)するため 0 で下限クランプ
        let maxSwipes = max(0, step.maxSwipes ?? tunables.defaultMaxSwipes)
        var viaXCUITest = false
        // この探索の動きが慣性を残したか = 見つけた後に空打ちを撃つ根拠(settleAfterFind)。ドラッグは常に残しうる側に数える
        var leftInertia = false
        var hintJumps = 0
        var settleCapped = false
        // 自己補正の材料(直前の周回のツリー)。**較正値は持たず毎周測り直す**
        var previousSnapshot: SnapshotResponse?
        // 撃ったスワイプ数と、**振っても木が1文字も変わらなかった**連続回数。
        // 端に着いた後も上限まで振り続けるのは丸損なので、2周続けて変化が無ければ打ち切る
        // (1周で切らないのは、遅れて描画される行を「動かなかった」と誤断しないため)
        var swipes = 0
        var unmovedRounds = 0
        // 最後に中身が動いた時刻。打ち切りの猶予(edgeClaimGraceAfterMove)の起点
        var lastMoveAt: ContinuousClock.Instant?
        // 打ち切りの理由文を分けるためだけの記録(ScrollSearchResult.contentEverMoved 参照)
        var contentEverMoved = false
        // 最後の周回の読みで直前の1本が動かしたか(弾切れの文言だけが見る)
        var lastSwipeMoved = true
        // 明示 scrollFrame の容器が探索の軸と違う軸にしか動かないと最初の木から言えるか(入れ子で払いが外側へ伝わる形)。
        // 動いたのは外側の一覧なので、逆走査(容器の推測は外側になる)を撃たず、失敗文でこの事実を言う
        var frameOtherAxis = false
        var truncatedDuringSearch = 0
        // スクロールした容器(中身が入れ替わった領域)。逆走査の刻みの基準
        var scrolledContainer: FTRect?
        // 横の探索の前に外側の縦の容器を送った回数(上限 2。送るたびに枠の位置が変わるので毎周測り直す)
        var bringIntoViewDrags = 0
        // 半開きシートを広げるドラッグを撃ったか(1 探索に 1 回。sheetExpandDrag の doc)
        var sheetExpandTried = false
        // 進む先の縁に付いた要素を見つけて同じ向きへ送り直したか(1 探索に 1 回。下の touchesLeadingEdge の分岐)
        var leadingEdgeNudged = false
        // 見切れの寄せ(下の isClippedByViewport 分岐)を撃った直後の周回か・寄せを撃っても木が変わらなかった連続回数。
        // 容器の外(キーボードの下・固定バー)にある対象は、寄せを何本撃っても可視域へ入らず maxSwipes まで空振りしていた
        var justSentClipRecovery = false
        var clipRecoveryUnmoved = 0
        // 探索を始めた時点で木が名乗っていたアプリ。Android は木の持ち主が前面と一緒に替わるので、
        // 打ち切るときの「前面は探索の対象のままか」を現在の木ではなくこちらで引く(frontAppIfSessionAppLeft)
        var searchBundleID: String?
        // 動いたかの比較(端・弾切れの判定)。**容器の中だけ**を比べる(領域は searchContentRegion: 名指し → 申告された容器 → 形から採った容器) ——
        // 容器の外の動き続ける表示(時計・カウンタ)を「動いた」と数えると端を検知できず、動かなかった探索で撃たない
        // はずの逆走査まで走って一覧が先頭へ戻された。領域が採れない画面だけ木全体
        let searchSignature: (SnapshotResponse) -> String = { snapshot in
            Self.contentSignature(Self.elementsInside(Self.searchContentRegion(step, in: snapshot), snapshot.elements))
        }
        for attempt in 0...maxSwipes {
            // **1周目だけは静止を待ってから撮る**。直前の操作がプログラム的な
            // アニメーションスクロール(「先頭へ」等)だと、ブリッジの整定はすり抜けることがあり
            // (アニメが始まる前に「変化なし」と判定される)、動く前のツリーで解決すると
            // **古い座標をタップして別の要素が選ばれる**(CMP で実測。
            // ステップは成功のまま = 黙って誤った結果)。2周目以降はスワイプ後の
            // settleAfterScroll / settledSignature が既に待っているので素取得でよい
            var snapshot: SnapshotResponse
            if attempt == 0 {
                snapshot = try await settledSignature(phase: &phase).snapshot
                // **直前の type のキーボードを、探索が判断する前に待つ**(ロケータ解決の段より先に探索が走るため)。
                // 待たないと、上がる前のキーボード(画面の外の申告)の木で「見えている」と判断して送らず、その後に上がった
                // キーボードの下へ対象が入る(E2EX-iOS xcuitest 入力の種類 S0040: 日本語キーボードは /type の後 約 1.3 秒で上がり、
                // select(#txt_bottom_echo, scroll: .down) が送らずに止まって可視性検証で赤。この Mac で 5/5)
                snapshot = try await consumePendingTypeKeyboardCheck(snapshot, phase: &phase)
                // hideKeyboard の後も同じ(閉じかけのキーボードの木で判断すると、要らない送りや早すぎる停止になる)
                snapshot = try await consumePendingHideKeyboardWait(snapshot, phase: &phase)
                searchBundleID = snapshot.sessionBundleID
            } else {
                let start = clock.now
                // **スワイプ直後は必ずキャッシュを捨てて撮る**(Android のみ実費。iOS は素通し)。
                // ブリッジの整定(a11y の静穏待ち)を通っても、**Compose の a11y ツリーは
                // 数十 ms 遅れて公開される** —— 応答時点の素の snapshot が**スワイプ前の位置**を
                // 返す瞬間があり(実測: 4回中2回。素=row_01 / refresh=1=row_06)、
                // 古いツリーで探索を続けると「動かなかった」と誤認する・見つけた要素が直後の
                // 解決で消える(`cannot resolve the locator` として現れる)。
                // 検証系の期限切れ直前の1回とは別で、ここは**毎周払う**必要がある
                snapshot = try await freshSnapshot(.afterOwnMove)
                phase.snapshotMs += Self.ms(clock.now - start)
            }
            try await dismissInterruption(in: &snapshot, phase: &phase)
            // **キーボードの実効矩形は周回ごとに引き直す**(整定待ち中に閉じることがある)。
            // hintDrag/slowDrag の viewport クリップと、末尾の keyboardFrame 注記の両方で使う
            let effectiveKeyboard = KeyboardOcclusion.resolve(reported: snapshot.keyboardFrame,
                                                              in: snapshot.elements, screen: snapshot.screen).frame
            // **周回ごとに記録する**(最終木では消えている情報。ScrollSearchResult の宣言参照)
            truncatedDuringSearch = max(truncatedDuringSearch, snapshot.truncatedCount)
            if attempt == 0 {
                frameOtherAxis = Self.scrollFrameRunsOtherAxis(step: step, in: snapshot,
                                                                vertical: direction == .up || direction == .down)
            }
            if let previousSnapshot {
                scrolledContainer = Self.changedContentContainer(before: previousSnapshot,
                                                                 after: snapshot)
                    ?? Self.movedContentContainer(before: previousSnapshot, after: snapshot,
                                                  vertical: direction == .up || direction == .down)
                    ?? scrolledContainer
            }
            if justSentClipRecovery, let previousSnapshot {
                clipRecoveryUnmoved = Self.contentSignature(previousSnapshot.elements)
                    == Self.contentSignature(snapshot.elements) ? clipRecoveryUnmoved + 1 : 0
            }
            justSentClipRecovery = false
            // **1回の移動量が容器を超えると要素を飛び越す**(スクロール探索は行き過ぎた要素を
            // 拾い直さない)。実測して超えていたら次の刻みを詰める。
            //
            // **基準は画面ではなく容器**: 画面の高さを基準にすると、容器は定義上それより小さいので
            // **ほぼ発火しない** —— PT-3.18(f) の実測では SwiftUI は 1 スワイプ 681pt に対し
            // 画面基準の閾値 0.8×874=699pt で素通りする一方、リストの可視高は 492pt =
            // **1.38 倍の超過**(いちばん取りこぼす SUT で無効になる)。
            //
            // **効くのは `scrollFrame` を書いた経路だけ**。刻みを縮める唯一の口は `spanScale` →
            // `scrollPath` で、あちらは領域未指定なら nil を返してブリッジ既定に任せるため。
            // 既定経路の飛び越しをホスト側で塞ぐには座標スワイプを常用するしかなく、それは
            // 2度撤回済み(PT-3.19)。**ここを既定経路へ広げないこと**
            let vertical = direction == .up || direction == .down
            if let previousSnapshot,
               let travel = Self.measuredTravel(before: previousSnapshot, after: snapshot,
                                                vertical: vertical) {
                let container = scrollContainer(step: step, in: snapshot, vertical: vertical)
                    .flatMap { ScrollGeometry.intersection($0, snapshot.screen) } ?? snapshot.screen
                let extent = vertical ? container.height : container.width
                if travel > extent * Self.travelCeilingRatio {
                    spanScale = max(Self.minSpanScale, spanScale * Self.spanShrinkFactor)
                }
            }
            // スクロール探索でも type+index フォールバックは誤検知のもとなので使わない
            if let (element, fallback) = LocatorResolver.resolve(step: step, in: snapshot, strictForAssert: true) {
                // **見つけただけでは足りない**: 画面の縁で見切れている要素は、フレームワークに
                // よっては frame がクランプされて**タップが外れる**(Compose iOS の既知の上流制約)。
                // まだ送れるなら、完全に見えるまでもう1回スワイプする。
                // 1回の移動量が小さいほど「見えた瞬間 = 見切れ位置」で止まるので、
                // 領域指定(scrollFrame)や刻みの細かい設定ほどここに掛かる
                // (実測: CMP で #row_40 が y=829/高さ56 = 下端 885 > 画面 874 で見つかり、
                // タップが別の行に取られた。全画面スワイプでは y=720 で見つかっていた)
                // 領域が指定されていないときは**報告された木から clip 元の祖先**を採る。
                // これが無いと viewport が画面全体になり、容器の外に並ぶ ghost 要素を
                // 「見えている」と判定して探索がそこで止まる(実測: #row_30 が
                // label=nil・y=783 = 容器 230..692 の外で見つかり、タップが飲まれた)
                let containerViewport = (scrollContainer(step: step, in: snapshot,
                                                vertical: direction == .up || direction == .down)
                                ?? ContainerGeometry.clippingContainer(of: element, in: snapshot.elements,
                                                          inferring: step.containerInference ?? true))
                    .flatMap { ScrollGeometry.intersection($0, snapshot.screen) } ?? snapshot.screen
                // **キーボードの下は見えていない**: 差し引かないと、打った後にキーボードの下へ残った echo を
                // 「見つけた」で止まり、可視性検証が描かれていないと赤にした(E2EX-iOS 入力画面 S0040・XCUITest)
                let viewport = ScrollGeometry.intersection(
                    containerViewport, ScrollGeometry.viewport(snapshot.screen, excludingKeyboard: effectiveKeyboard))
                    ?? containerViewport
                // **in-app の自前描画(Compose / Flutter)の送りは path の長さに関係なく a11y の scroll = 1ページ**なので、
                // 見切れを戻す1本が逆側へ飛び越して往復し、予算を使い切った(E2EY-CMP の反転チャット: 容器の外の
                // #msg_40 を8本で拾えず)。この経路では戻しを必ず距離どおりのドラッグで撃つ(下の slowDrag)。
                // 縁にぴったり(浮動小数の差)は見切れと数えない(`TapTargetGeometry.clipTolerance`)。
                // 中心が中なら撃つ、にはしない —— 見切れた行の中心を撃つと別の行に当たる(Compose iOS の実測・上の doc)。
                // SwiftUI は含めない(下の +28% は SwiftUI の実測)
                let pagesPerSwipe = typeDriver != nil
                    && AppUIFrameworkQuery.hostsOwnTouches(element, app: uiFramework) == true
                if attempt < maxSwipes,
                   clipRecoveryUnmoved < Self.unmovedRoundsToStopSearch,
                   Self.isClippedByViewport(element, screen: viewport) {
                    // **寄せる前にも fail-fast を通す**(未検出側と同じ判定)。ここを飛ばすと
                    // 解決できない明示 scrollFrame のまま viewport が画面全体へ落ち、寄せの1本が
                    // 文書化した「1本も振らない」を素通りして全画面スワイプになる
                    if Self.scrollFrameUnresolved(step, in: snapshot) {
                        return ScrollSearchResult(found: false, fallback: nil, viaXCUITest: viaXCUITest,
                                                  hintJumps: hintJumps, swipes: swipes,
                                                  scrollFrameMissing: true,
                                                  maxTruncatedDuringSearch: truncatedDuringSearch)
                    }
                    // **行き過ぎた側なら逆へ送る**(recoveryDirection 参照)。探索方向のまま
                    // 送り続けると、既に通り過ぎた要素は遠ざかるだけで永久に可視域へ戻らない
                    var recovery = step
                    let back = Self.recoveryDirection(for: element, container: viewport,
                                                      searching: direction)
                    recovery.direction = back.rawValue
                    let path = scrollPath(step: recovery, intent: .search, in: snapshot)
                    // **path が無い(= 全幅フリングになる)既定経路だけ**、必要距離の遅いドラッグで
                    // 寄せる(clipRecoveryJump 参照。フリングは逆側へ再飛び越しして往復振動する)。
                    // scrollFrame あり = path は元々容器基準の短い送りなので置き換えない
                    // (置き換えると SwiftUI で +28% の実退行。92s/72s の A/B で確定)。
                    // ジャンプ量 40pt 未満は嘘 frame(クランプ)の兆候なので通常のスワイプへ
                    // 1ページの払いよりは、小さな量を広げて寄せるほうが近い(dragGesture は 50 以下を撃たない)
                    if path == nil || pagesPerSwipe,
                       let raw = Self.clipRecoveryJump(for: element, viewport: viewport, finger: back),
                       case let jump = pagesPerSwipe ? (raw < 0 ? -1 : 1) * max(abs(raw), 60) : raw,
                       abs(jump) >= 40,
                       // **キーボードを避けて掴む**: slowDrag は渡した container をそのまま
                       // 自分の viewport にも使う(始点・終点の両方に効く)ので、ここで
                       // 事前にキーボード帯を切り落としておく(ScrollGeometry.viewport 参照)
                       await slowDrag(jump: jump,
                                      container: ScrollGeometry.viewport(viewport,
                                                                         excludingKeyboard: effectiveKeyboard),
                                      vertical: back == .up || back == .down, phase: &phase) {
                        // 寄せの1本も**撃った数と比較材料に載せる**(未検出側と同じ)。載せないと
                        // swipes が 0 のまま報告され、「2周不変で打ち切り」と弾切れ後の逆走査が
                        // 寄せの周回では一切効かない
                        swipes += 1
                        leftInertia = true
                        previousSnapshot = snapshot
                        justSentClipRecovery = true
                        continue
                    }
                    let finger = FTSwipeDirection(rawValue: recovery.direction ?? "") ?? direction
                    let swipedViaXCUITest = try await swipeWithFallback(finger, intent: .search, path: path,
                                                                        phase: &phase)
                    if swipedViaXCUITest { viaXCUITest = true }
                    if !swipeLeavesNoInertia(swipedViaXCUITest: swipedViaXCUITest) { leftInertia = true }
                    swipes += 1
                    previousSnapshot = snapshot
                    justSentClipRecovery = true
                    continue
                }
                // **進む先の縁に付いている = 枠が見えている部分へ切り詰められている**ことがある(Android の Flutter は
                // 画面の外にはみ出した要素の枠を見えている幅へ詰めて出すので、上の見切れの判定で分からない。実測: E2EY-Flutter の
                // #card_0_14 が右端に 18px だけ出た所で見つかったとし、その中心 = 右端の戻るの帯を撃って飲まれた。並列で 5/5)。
                // 同じ向きへ1回だけ、**容器の半分の距離を慣性の出ない遅いドラッグで**送り直す(縁から出始めた要素の先頭は中央までしか
                // 動かない = 飛び越さない)。探索の払いで送ると慣性で反対側の縁の外まで流れ、以後は遠ざかる向きに送り続けて見つからなかった
                // (E2EY-RN の XCUITest と Android の横向きで実測)。ドラッグが撃てなければ送らずに従来どおり見つかったとする。
                // in-app の 1 ページ送り(pagesPerSwipe)は除く(1本で1ページ動くので、半分の距離の寄せにならない)
                // **見えている厚みが指で押せる大きさ未満のときだけ**(`leadingEdgeNudgeMinVisiblePt`)。Android はどのフレームワークでも
                // 見切れた行の枠を見えている部分へ詰めるので、縁に付いただけで送ると探索のたびに遅いドラッグ(最大 3 秒)を払う。
                // 押せる大きさが見えていれば人もそのまま押す(RN の XCUITest の 140pt のカードは縁に付いていても押せる)
                let alongVertical = direction == .up || direction == .down
                if attempt < maxSwipes, !leadingEdgeNudged, !pagesPerSwipe,
                   ScrollGeometry.touchesLeadingEdge(element.frame, viewport: viewport, finger: direction),
                   (alongVertical ? element.frame.height : element.frame.width)
                       < Self.leadingEdgeNudgeMinVisiblePt * driver.pointScale {
                    leadingEdgeNudged = true
                    let extent = alongVertical ? viewport.height : viewport.width
                    let jump = (direction == .up || direction == .left ? 1.0 : -1.0) * extent * Self.leadingEdgeNudgeRatio
                    if await slowDrag(jump: jump,
                                      container: ScrollGeometry.viewport(viewport, excludingKeyboard: effectiveKeyboard),
                                      vertical: alongVertical, phase: &phase) {
                        leftInertia = true
                        swipes += 1
                        previousSnapshot = snapshot
                        continue
                    }
                }
                // **木に居ること ≠ 画面に居ること**: 中心が**画面**の外なら「見つかった」に
                // しない(下の未検出経路へ合流)。**効くのは弾切れの周回だけ** —— それ以外は上の
                // isClippedByViewport が先に寄せに行く。
                // **isClippedByViewport と同じサイズ免除が要る**(offscreenScrollGateAdvisory 参照):
                // ビューポートより大きい/ゼロサイズの要素は isClippedByViewport が false を返し
                // 続けるので、免除しないとゲートだけが弾切れ前から found を拒否し、探索方向へ
                // 進むたび遠ざかる(縦3000pt の要素で確認)。
                // **基準は viewport(容器)ではなく screen**: 容器の外だが画面には映っている
                // ghost は、掴み直し + `RefGuard` の警告つきタップという既存の設計で扱う
                // (ここで failed にすると、その警告が拒否へ格上げされて
                // `testTapAfterSearchNotesWhenTheGhostPersists` の経路ごと消える)。
                // 見切れ(中心は画面内)も同じ理由で found のまま —— タップは通る。
                // 判定は MCP の ⚠️offscreen と共有(TapTargetGeometry.offscreenScrollGateAdvisory)
                if TapTargetGeometry.offscreenScrollGateAdvisory(for: element, screen: snapshot.screen) == nil {
                    // **スワイプしたなら静止を待つ**(空打ち→静止待ちの順。settleAfterFind 参照)。
                    // スワイプしていない周回(attempt == 0)は静止しているので追加コストを払わない
                    if attempt > 0 {
                        settleCapped = try await settleAfterFind(step: step, element: element,
                                                                 snapshot: snapshot, afterInertialMove: leftInertia,
                                                                 phase: &phase)
                    }
                    // **成功時も swipes を載せる**: 失敗文にしか使わなかった頃は既定の 0 で
                    // 害が無かったが、MCP の ft_scroll_to が所要時間の内訳へ出すようになり、
                    // 「何本振って辿り着いたか」が常に 0 と報告されるようになった
                    return ScrollSearchResult(found: true, fallback: fallback, viaXCUITest: viaXCUITest,
                                              hintJumps: hintJumps, settleCapped: settleCapped,
                                              swipes: swipes,
                                              maxTruncatedDuringSearch: truncatedDuringSearch,
                                              element: element)
                }
            }
            // **横の探索で枠がほとんど窓の外なら、先に外側の縦の容器を送って枠を窓へ入れる**
            // (見えている帯が低いと横の払いが画面の縁に乗る。`ScrollGeometry.bringIntoView`)。
            // 探索の払いを1本も撃っていない間だけ・上限 2 回。外側が無ければ従来どおり探索する
            if !vertical, bringIntoViewDrags < 2, swipes == bringIntoViewDrags,
               step.scrollFrame != nil || step.scrollFrameRect != nil,
               let frame = scrollContainer(step: step, in: snapshot, vertical: false),
               let reach = ScrollGeometry.bringIntoView(
                   frame: frame,
                   screen: ScrollGeometry.viewport(snapshot.screen, excludingKeyboard: effectiveKeyboard),
                   elements: snapshot.elements),
               await slowDrag(jump: reach.jump, container: reach.outer, vertical: true, phase: &phase) {
                bringIntoViewDrags += 1
                leftInertia = true
                swipes += 1
                previousSnapshot = snapshot
                if pendingScrollFrameNote == nil {
                    pendingScrollFrameNote = "the scrollFrame was mostly off-screen, so the enclosing"
                        + " scroll area was moved first to bring it into view"
                }
                continue
            }
            // **最後の周回は送らないが、直前の1本が動かしたかは比べる**(読みはもう撮ってある = 費用ゼロ)。
            // 比べないと maxSwipes: 1 で1本が動いて対象を通り過ぎた探索を「1度も動かなかった」と読み、弾切れの逆走査を撃たない
            if attempt == maxSwipes, let earlier = previousSnapshot {
                lastSwipeMoved = searchSignature(earlier) != searchSignature(snapshot)
                if lastSwipeMoved {
                    contentEverMoved = true
                    previousSnapshot = snapshot
                }
            }
            if attempt < maxSwipes {
                // **明示 scrollFrame が解決できないなら、ここで打ち切る(1本も振らない)**。
                // 空振りしたまま全画面スワイプへ黙って退化すると、カード上のボタン等
                // 無関係な要素を発火させ得る(Apple マップの実害: 申告した
                // #MUScrollableStackView が次の瞬間ツリーから落ち、退化したスワイプが
                // カードの「計画」ボタンを叩いて画面遷移した)。**探索中に容器が消えた場合も同型**
                // なので、初回だけでなく毎周チェックする。
                // **scrollContainer ではなく Self.scrollFrameUnresolved で判定する**
                // (scrollContainer は殺しスイッチ時に常に nil を返すため、それをそのまま使うと
                // legacy 指定時に「セレクタが実在するのに matched nothing」と誤検知する)
                if Self.scrollFrameUnresolved(step, in: snapshot) {
                    var missing = ScrollSearchResult(found: false, fallback: nil, viaXCUITest: viaXCUITest,
                                                     hintJumps: hintJumps, swipes: swipes,
                                                     scrollFrameMissing: true,
                                                     maxTruncatedDuringSearch: truncatedDuringSearch)
                    // 容器が消えた理由が「前面を奪われた(消灯・シェード・別のアプリ)」なら、それを言う(払いを送った後だけ)
                    if swipes > 0 { missing.appLeftForeground = await frontAppIfSessionAppLeft(searchBundleID, tree: snapshot) }
                    return missing
                }
                // **探索の途中で画面の大きさが変わった(端末が回った)なら、端とは言わず止める**:
                // 木の座標系が替わると容器・始点の前提が崩れ、動かないのは端ではなく払いが届かないため
                if let earlier = previousSnapshot, earlier.screen != snapshot.screen {
                    var turned = ScrollSearchResult(found: false, fallback: nil, viaXCUITest: viaXCUITest,
                                                    hintJumps: hintJumps, swipes: swipes,
                                                    maxTruncatedDuringSearch: truncatedDuringSearch)
                    turned.screenResized = true
                    return turned
                }
                if let earlier = previousSnapshot,
                   searchSignature(earlier)
                       == searchSignature(snapshot) {
                    unmovedRounds += 1
                    // **最後に動いてから `edgeClaimGraceAfterMove` 経つまでは打ち切らず、残りを待って
                    // もう1本送る**(scrollToEdge と同じ猶予)。末尾に着いてから続きを読み込む一覧は、
                    // 読み込むまで「動かない」に見える(実測: SwiftUI の無限スクロールが loaded=40 で
                    // 打ち切られた。読み込みは末尾到達の 0.8 秒後)。待った後の周回がまた動かなければ打ち切る
                    if unmovedRounds >= Self.unmovedRoundsToStopSearch, let lastMoveAt,
                       clock.now - lastMoveAt < Self.edgeClaimGraceAfterMove {
                        let waitStart = clock.now
                        try await Task.sleep(for: Self.edgeClaimGraceAfterMove - (clock.now - lastMoveAt))
                        phase.waitMs += Self.ms(clock.now - waitStart)
                        unmovedRounds = Self.unmovedRoundsToStopSearch - 1
                    }
                    // **利用者が `waitSeconds:` を書いたのに何も動かないままなら、その予算の間は端と確定しない**
                    // (読み込み中の骨組みの一覧は数秒後に伸びる。1.5 秒で「何も動かない」と断ると予算を使い切らずに赤になった)。
                    // 書かれていなければ従来どおり(既定の待ちで毎回の失敗探索を遅くしない)。動いた後の停止は端なので対象外
                    if unmovedRounds >= Self.unmovedRoundsToStopSearch, !contentEverMoved, let budget = step.timeout,
                       clock.now - searchStart < .seconds(budget) {
                        let waitStart = clock.now
                        try await Task.sleep(for: Self.unmovedBudgetPollInterval)
                        phase.waitMs += Self.ms(clock.now - waitStart)
                        unmovedRounds = Self.unmovedRoundsToStopSearch - 1
                    }
                    if unmovedRounds >= Self.unmovedRoundsToStopSearch {
                        // **打ち切る前に整定まで待って確かめる**(Flutter/Android で
                        // 誤発火): a11y ツリーは遅れて公開されるので、**動いている最中でも
                        // 2周続けて同じ木**が返ることがある。`settledSignature` は
                        // キャッシュを捨てて連続2回一致まで待つので、遅れと停止を区別できる。
                        // 費用は打ち切る局面の1回だけ(正常系には掛からない)
                        let confirmed = try await settledSignature(phase: &phase)
                        if searchSignature(confirmed.snapshot)
                            != searchSignature(snapshot) {
                            snapshot = confirmed.snapshot
                            previousSnapshot = snapshot
                            unmovedRounds = 0
                            contentEverMoved = true
                            continue
                        }
                        // **前面を奪われていたなら、端とは言わず、展開も逆走査も撃たない**(別のアプリの上へ払い続けない)。
                        // 木が変わらない = 端、は自アプリが前面に居る間だけ成り立つ。確かめるのは打ち切る局面の1回だけ
                        if let front = await frontAppIfSessionAppLeft(searchBundleID ?? snapshot.sessionBundleID, tree: snapshot) {
                            var left = ScrollSearchResult(found: false, fallback: nil, viaXCUITest: viaXCUITest,
                                                          hintJumps: hintJumps, swipes: swipes,
                                                          maxTruncatedDuringSearch: truncatedDuringSearch)
                            left.appLeftForeground = front
                            return left
                        }
                        // シート展開ヒントは**対象の容器がボトムシートの幾何に合う**ときだけ
                        // (全画面リストの末尾到達・シートの無い画面で毎回誤って出すのを防ぐゲート。
                        // [F7b] 「画面の大半を占めない」だけでは、
                        // 下端が画面下端から離れた固定高リストやシートの無いホーム画面の容器にも
                        // 中〜広い高さ比のものがあり誤って鳴る。判定は `SheetGeometry` に一本化)。
                        // **scrollFrame 未指定でも判定する**: 半開きシートの中で
                        // 止まる形は指定の有無に関係なく起きるのに、指定したときにしかヒントが
                        // 出ていなかった —— 実測(Apple マップの経路手順)では、未指定の1回目が
                        // 「動かなくなった」としか言わず、同じ画面で scrollFrame を渡した2回目に
                        // だけ「シートを広げろ」が出て、そこで初めて解けた
                        let containerIsPartialHeight = scrollContainer(
                            step: step, in: snapshot, vertical: vertical)
                            .map { SheetGeometry.looksLikeBottomSheet(frame: $0, screen: snapshot.screen) }
                            ?? SheetGeometry.declaredSheetExists(in: snapshot)
                        // **半開きシートの中で1度も動かなかったら、1回だけシートを広げて探し直す**(sheetExpandDrag の doc)
                        // 容器は scrollFrame で指した物だけ(scrollContainer は未指定なら nil・キーボードが出ていれば画面全体 =
                        // シートの幾何に合わない)= 利用者が指していない画面は動かさない
                        let bottomGestureBand = isAndroid ? (await driver.backGestureEdgeWidths())?.bottom ?? 0 : 0
                        if !sheetExpandTried, !contentEverMoved, containerIsPartialHeight, direction == .up,
                           !defersPartialSheetRecovery,
                           let frame = scrollContainer(step: step, in: confirmed.snapshot, vertical: true)
                               .flatMap({ ScrollGeometry.intersection($0, confirmed.snapshot.screen) }),
                           let drag = Self.sheetExpandDrag(container: frame, screen: confirmed.snapshot.screen,
                                                              bottomGestureBand: bottomGestureBand) {
                            sheetExpandTried = true
                            try await dragWithFallback(fromX: drag.x, fromY: drag.fromY, toX: drag.x, toY: drag.toY,
                                                       pressSeconds: FlowStep.defaultDragPressSeconds,
                                                       durationSeconds: Self.sheetExpandDragSeconds)
                            swipes += 1
                            let expanded = try await settledSignature(phase: &phase).snapshot
                            if let grown = scrollContainer(step: step, in: expanded, vertical: true),
                               grown.height > frame.height + 1 {
                                if pendingScrollFrameNote == nil {
                                    pendingScrollFrameNote = "the list sat in a partially open sheet and did not move,"
                                        + " so the sheet was expanded by a drag inside the scrollFrame first"
                                }
                                unmovedRounds = 0
                                previousSnapshot = expanded
                                continue
                            }
                        }
                        // 打ち切り確定時点(confirmed)で引き直す —— ループ先頭の effectiveKeyboard は
                        // この settledSignature 呼び出しより前の木の情報なので使い回さない
                        let stoppedKeyboard = KeyboardOcclusion.resolve(reported: confirmed.snapshot.keyboardFrame,
                            in: confirmed.snapshot.elements, screen: confirmed.snapshot.screen).frame
                        var result = ScrollSearchResult(found: false, fallback: nil,
                                                        viaXCUITest: viaXCUITest,
                                                        hintJumps: hintJumps,
                                                        swipes: swipes, stoppedUnmoving: true,
                                                        contentEverMoved: contentEverMoved,
                                                        containerIsPartialHeight: containerIsPartialHeight,
                                                        maxTruncatedDuringSearch: truncatedDuringSearch,
                                                        keyboardFrame: stoppedKeyboard)
                        result.scrollFrameOtherAxis = Self.scrollFrameRunsOtherAxis(
                            step: step, in: confirmed.snapshot, vertical: vertical)
                        // 未指定の全画面探索が的外れな案内(シート展開・端到達)を出す前に、
                        // 探索方向に合う宣言済みの容器を名指しできないか確かめる
                        if step.scrollFrame == nil {
                            result.directionMatchedScrollFrameCandidate =
                                Self.directionMatchedScrollFrameCandidate(in: confirmed.snapshot,
                                                                          vertical: vertical)
                        }
                        // **順方向で1度も動かなかったら逆走査しない**: 逆走査は飛び越しの救済で、動いていなければ
                        // 何も通り過ぎていない。撃つと指定と逆の向きを探す別の機能になり、`scrollTo(direction: .up)` が
                        // 先頭から下の要素を見つけて成功する(「上にある」の確認にならない)
                        guard contentEverMoved, !frameOtherAxis, recoverOnMiss, step.containerInference ?? true,
                              // 半開きシートで呼び手が展開・再試行するなら、逆走査はそちらの
                              // 再試行(全画面高)に譲る(defersPartialSheetRecovery の宣言参照)
                              !(defersPartialSheetRecovery && containerIsPartialHeight),
                              let container = (scrolledContainer
                                               ?? Self.overflowingContainer(in: snapshot))
                                  .flatMap({ ScrollGeometry.intersection($0, snapshot.screen) })
                        else { return result }
                        // **端に着いたのに見つからない = 途中で飛び越した可能性**。
                        // 既定経路(scrollFrame 未指定)は刻みがブリッジ任せで縮められないので、
                        // ここでだけ推測した容器で細刻みの逆走査を掛ける
                        // (通常の送りには触らない = 2度撤回した「暗黙の座標化」にならない)
                        let recoveredBySweep = try await reverseSweep(step: step, container: container,
                                                                      searching: direction, phase: &phase)
                        // 撃てた本数で決める(最初の1本が撃てずに諦めた回に「逆走査した」と言わない)
                        result.reverseSweepRan = reverseSweepDragsSent > 0
                        if let recovered = recoveredBySweep {
                            result.found = true
                            result.fallback = recovered
                            result.reverseSweeps += 1
                            // 推測した容器に**申告済みの容器**が重なっていればその名前を出す。
                            // 重ならなければ nil のまま = 注記は総称に留める(推測した矩形を
                            // 座標で名乗っても `scrollFrame:` には書けない)
                            result.suggestedScrollFrame = ScrollFrameCandidates.selector(
                                matching: container, in: snapshot)
                        }
                        return result
                    }
                } else {
                    // **比較が成立した回だけ**「動いた」と数える(1周目は previousSnapshot が
                    // 無いので、ここへ来ても何とも比べていない)
                    if let earlier = previousSnapshot {
                        contentEverMoved = true
                        lastMoveAt = clock.now
                    }
                    unmovedRounds = 0
                }
                // ヒント跳躍: 距離が分かるときは固定幅スワイプでなく長距離ドラッグで寄せる。
                // ドラッグ後は静止を待たず次周回のスナップショット(25ms)で測り直す(自己補正)
                if let jump = Self.offscreenJump(step: step, snapshot: snapshot, finger: direction),
                   let container = Self.webViewContainer(in: snapshot),
                   // **キーボードを避けて掴む**(ScrollGeometry.viewport 参照。無ければ screen のまま)
                   await hintDrag(jump: jump, container: container,
                                  viewport: ScrollGeometry.viewport(snapshot.screen,
                                                                    excludingKeyboard: effectiveKeyboard),
                                  phase: &phase) {
                    hintJumps += 1
                    leftInertia = true
                    swipes += 1
                    previousSnapshot = snapshot
                    continue
                }
                // **この探索がまだ1度も動かせておらず、直前の1本も何も動かさなかったときだけ**離す瞬間に
                // 速度を残す(FTSwipeIntent.searchFling)。一度でも動いた後は掛けない —— 木の公開の遅れで
                // 「動かなかった」に見える周回があり、そこで慣性を足すと対象を飛び越す
                let intent: FTSwipeIntent = !contentEverMoved && unmovedRounds > 0 ? .searchFling : .search
                let swipedViaXCUITest = try await swipeWithFallback(direction, intent: intent,
                                                                    path: scrollPath(step: step, intent: intent,
                                                                                     in: snapshot),
                                                                    phase: &phase)
                if swipedViaXCUITest { viaXCUITest = true }
                if !swipeLeavesNoInertia(swipedViaXCUITest: swipedViaXCUITest) { leftInertia = true }
                swipes += 1
                previousSnapshot = snapshot
            }
        }
        // **弾切れでも逆走査を1回だけ試す**(実測: 端のバウンスで内容署名が毎周
        // 揺れ、「2周連続不変」の端判定に到達しないまま maxSwipes を使い切る形が RN の
        // 横カルーセルで 2/10 残った。既に通り過ぎている公算が高い局面で、失敗経路限定なので
        // 正常系のコストはゼロ。ゲートは stoppedUnmoving 側の逆走査と同じ)
        var reverseSweepRan = false
        // **「動いた」の根拠が木全体の署名だけのときは撃たない**: 領域が採れない画面(searchContentRegion が nil)で、位置の動いた/
        // 入れ替わった容器(scrolledContainer)を1度も観測していないなら、動いたのは容器の外の動き続ける表示(時計・ティッカー)かもしれず、
        // 動いていない一覧を先頭側へ引き戻す(順方向で動かなかった探索は逆走査しない、という決定の裏口になる)
        let movedByEvidence = contentEverMoved
            && (scrolledContainer != nil || previousSnapshot.flatMap { Self.searchContentRegion(step, in: $0) } != nil)
        // 順方向で1度も動かなかったら撃たない(端で打ち切った側の guard と同じ理由)
        if movedByEvidence, !frameOtherAxis, recoverOnMiss, step.containerInference ?? true,
           let latest = previousSnapshot,
           let container = (scrolledContainer ?? Self.overflowingContainer(in: latest))
               .flatMap({ ScrollGeometry.intersection($0, latest.screen) }) {
            let recoveredBySweep = try await reverseSweep(step: step, container: container,
                                                          searching: direction, phase: &phase)
            reverseSweepRan = reverseSweepDragsSent > 0
            if let recovered = recoveredBySweep {
                var result = ScrollSearchResult(found: true, fallback: recovered,
                                                viaXCUITest: viaXCUITest,
                                                hintJumps: hintJumps, swipes: swipes,
                                                maxTruncatedDuringSearch: truncatedDuringSearch)
                result.reverseSweeps = 1
                result.suggestedScrollFrame = ScrollFrameCandidates.selector(matching: container,
                                                                             in: latest)
                return result
            }
        }
        var exhausted = ScrollSearchResult(found: false, fallback: nil, viaXCUITest: viaXCUITest,
                                           hintJumps: hintJumps, swipes: swipes,
                                           reverseSweepRan: reverseSweepRan,
                                           maxTruncatedDuringSearch: truncatedDuringSearch)
        exhausted.scrollFrameOtherAxis = frameOtherAxis
        // 最後の払いで動いたときだけ(途中で動いて末尾で止まった探索に「端に着いていない」と言わない)
        exhausted.exhaustedWhileMoving = movedByEvidence && lastSwipeMoved
        if step.scrollFrame == nil, let latest = previousSnapshot {
            exhausted.directionMatchedScrollFrameCandidate =
                Self.directionMatchedScrollFrameCandidate(in: latest,
                                                          vertical: direction == .up || direction == .down)
        }
        return exhausted
    }
}
