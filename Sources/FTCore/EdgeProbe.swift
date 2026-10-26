// scrollToEdge の「端の確かめ」を引っ張りにしない短いドラッグ(純粋関数)。呼び口は StepExecutor+DirectActions.swift の
// executeDirectScrollToEdge の1箇所。使うのは**ドライバも容器も端を申告しない構成の iOS の上端(scrollToTop)だけ**
// (XCUITest と、in-app の Compose / Flutter の送り)。上端だけなのは、副作用(引っ張って更新)があるのが上端だけで、
// 横のページャ・下端で続きを読む一覧では短いドラッグが元の位置へ戻る/読み込みを起こさず、途中を端と誤る余地を作るから ——
// 端は「木が2回続けて変わらない」でしか分からず、確かめの全力の送りが上端で引っ張って更新を走らせていた
// (E2EX-CMP の引っ張って更新: 上端に着いた送りでは走らず、着いた後の送り1本ごとに更新が1回走る = 実測)

import Foundation

public enum EdgeProbe {

    /// 確かめのドラッグの距離[pt]。**タッチの遊び(iOS 約 10pt・Compose 8dp・Flutter 18)より大きく** = 端でなければ
    /// 中身が動いて署名(座標を含む)が変わり、**引っ張って更新の閾値の最小(Flutter の RefreshIndicator 約 40)より小さい**
    /// = 端で撃っても更新を始めない
    public static let distance: Double = 30
    /// 所要[秒]。30pt/秒 = 慣性が起きる最低速度(Compose 50dp/秒)より遅い = 離した後に流れない
    public static let durationSeconds: Double = 1.0

    /// 送りの前後の木から、`region` の中の中身が軸の向きに動いた量[pt・絶対値]。
    /// 両方の木に1つずつしかない `#id` の要素の差の**最大**(固定の見出しなど動かない要素は 0 で混ざるので中央値にしない)。
    /// 共通の要素が全部動いていないのに新しい要素が現れた = 共通に残ったのは動かない要素だけ(中身は画面1枚以上動いた)
    /// → nil。共通の要素が無い → nil(測れない = 呼び手は確かめを全力の送りのままにする)
    public static func contentDisplacement(before: [ElementInfo], after: [ElementInfo],
                                           region: FTRect?, vertical: Bool) -> Double? {
        let old = unique(before, in: region), new = unique(after, in: region)
        let common = Set(old.keys).intersection(new.keys)
        guard !common.isEmpty else { return nil }
        let moved = common.map { id -> Double in
            let a = old[id]!.frame, b = new[id]!.frame
            return vertical ? abs(b.y - a.y) : abs(b.x - a.x)
        }.max() ?? 0
        if moved == 0, !Set(new.keys).subtracting(old.keys).isEmpty { return nil }
        return moved
    }

    /// 送りの後、動いた中身の先頭(指の向きの側の縁)が**動かなかった枠の縁にぴったり揃った**か = 端に着いた印。
    /// 最初の1本で端に着いた送り(短い一覧)は比べる基準が無いので、こちらで読む(E2EX-CMP の引っ張って更新:
    /// `#row_refresh_00` の上端 = 動かない `#box_refresh` の上端)。動かなかった枠 = 前後で同じ位置の `#id` の要素で、
    /// 先頭の要素の中心を含む最小のもの。揃わない作り(内側の余白)では false = 今までどおり
    public static func flushAgainstStaticFrame(before: [ElementInfo], after: [ElementInfo],
                                               region: FTRect?, finger: FTSwipeDirection) -> Bool {
        let old = unique(before, in: region), new = unique(after, in: region)
        let isStatic = { (id: String) -> Bool in old[id].map { $0.frame == new[id]!.frame } ?? false }
        let moving = new.filter { !isStatic($0.key) }.map(\.value)
        guard !moving.isEmpty else { return false }
        let lead: ElementInfo
        switch finger {
        case .down: lead = moving.min { $0.frame.y < $1.frame.y }!
        case .up: lead = moving.max { $0.frame.y + $0.frame.height < $1.frame.y + $1.frame.height }!
        case .right: lead = moving.min { $0.frame.x < $1.frame.x }!
        case .left: lead = moving.max { $0.frame.x + $0.frame.width < $1.frame.x + $1.frame.width }!
        }
        let frames = new.filter { isStatic($0.key) }.map(\.value.frame)
            .filter { StepExecutor.frame($0, containsX: lead.frame.centerX, y: lead.frame.centerY) }
        guard let viewport = frames.min(by: { $0.width * $0.height < $1.width * $1.height }) else { return false }
        // **先頭が枠いっぱいなら読まない**: 1ページずつ吸着する一覧(縦のフィード)はどのページでも縁に揃い、短いドラッグは
        // 離すと同じページへ戻る(木が変わらない)= 途中を端と確定してしまう
        let along = (finger == .down || finger == .up)
        if (along ? lead.frame.height : lead.frame.width) >= (along ? viewport.height : viewport.width) - 1 { return false }
        // 揃いの許容[pt]: 座標の丸め(XCUITest の枠は 1/3pt 刻み)を吸う
        let tolerance = 1.0
        switch finger {
        case .down: return abs(lead.frame.y - viewport.y) <= tolerance
        case .up: return abs((lead.frame.y + lead.frame.height) - (viewport.y + viewport.height)) <= tolerance
        case .right: return abs(lead.frame.x - viewport.x) <= tolerance
        case .left: return abs((lead.frame.x + lead.frame.width) - (viewport.x + viewport.width)) <= tolerance
        }
    }

    /// `region` の中で1つずつしかない `#id` の要素
    private static func unique(_ elements: [ElementInfo], in region: FTRect?) -> [String: ElementInfo] {
        var counts: [String: Int] = [:]
        for element in elements { if let id = element.identifier, !id.isEmpty { counts[id, default: 0] += 1 } }
        var out: [String: ElementInfo] = [:]
        for element in elements {
            guard let id = element.identifier, counts[id] == 1 else { continue }
            if let region, !StepExecutor.frame(region, containsX: element.frame.centerX, y: element.frame.centerY) { continue }
            out[id] = element
        }
        return out
    }

    /// 全力の送りが途中で端に当たったか: 中身の動きが基準に届かない。基準は指の移動量(端でなければ慣性で指の移動量より
    /// 多く動く)か、同じ払い方の1本前の送りが動かした量(同じ一覧を同じ払い方で送れば同じだけ動く)。
    /// 外れても害は時間だけ(確かめのドラッグで中身が動けば署名が変わり、全力の送りへ戻る)
    public static func stoppedShort(displacement: Double, fingerTravel: Double) -> Bool {
        fingerTravel > 0 && displacement < fingerTravel
    }

    /// 送りの前後で動いた(= スクロールしている中身の)`#id`。前後の木に1つずつあって枠が変わったもの + 後にだけ現れたもの
    public static func movedIDs(before: [ElementInfo], after: [ElementInfo], region: FTRect?) -> Set<String> {
        let old = unique(before, in: region), new = unique(after, in: region)
        return Set(new.filter { id, element in old[id].map { $0.frame != element.frame } ?? true }.keys)
    }

    /// 確かめのドラッグの経路: 容器の中の点から指の向きへ `distance`。
    /// **①動いた中身(`moved` の `#id` の要素)の中心から始める** —— スクロールしている中身の上で始めたドラッグは、タッチの
    /// 遊びを超えた時点でスクロールが取り、行のタップは取り消される(UIKit の表・SwiftUI・Compose・Flutter・RN)。
    /// **②動いていない押せる型の要素(`KeyboardDismissPoint.unsafeTypes`。一覧に重なった浮動ボタン・CMP の画面全体の
    /// scrollView の中の一覧の外のボタン)には始点も終点も置かない** —— そこで始めた短いドラッグは要素の外へ出ず、タップとして
    /// 受け取られうる(取り消せない側)。①が無ければ容器の中央から外へ格子で②を満たす点を探し、無ければ nil(呼び手は確かめを
    /// 全力の送りのままにする)。型の出ない押せる仕掛け(CMP の行は `other`)は②で避けられない
    public static func path(in container: FTRect, finger: FTSwipeDirection, avoiding elements: [ElementInfo],
                            moved: Set<String>) -> FTSwipePath? {
        let (dx, dy): (Double, Double) = switch finger {
        case .up: (0, -distance)
        case .down: (0, distance)
        case .left: (-distance, 0)
        case .right: (distance, 0)
        }
        let isMoved = { (e: ElementInfo) in e.identifier.map(moved.contains) ?? false }
        let unsafe = elements.filter { KeyboardDismissPoint.unsafeTypes.contains($0.type) && !isMoved($0) }.map(\.frame)
        func clear(_ x: Double, _ y: Double) -> Bool {
            StepExecutor.frame(container, containsX: x, y: y)
                && !unsafe.contains { StepExecutor.frame($0, containsX: x, y: y) }
        }
        let anchors = elements.filter(isMoved).sorted {
            hypot($0.frame.centerX - container.centerX, $0.frame.centerY - container.centerY)
                < hypot($1.frame.centerX - container.centerX, $1.frame.centerY - container.centerY)
        }
        for anchor in anchors {
            let x = anchor.frame.centerX, y = anchor.frame.centerY
            if clear(x, y), clear(x + dx, y + dy) { return FTSwipePath(fromX: x, fromY: y, toX: x + dx, toY: y + dy) }
        }
        // 格子の目 = 容器の短い辺の 1/gridSteps(画面の大きさに比例させる。固定の pt を置かない)
        let step = min(container.width, container.height) / Double(gridSteps)
        guard step > 0 else { return nil }
        for ring in 0...gridSteps {
            for (ox, oy) in ringOffsets(ring) {
                let x = container.centerX + Double(ox) * step, y = container.centerY + Double(oy) * step
                if clear(x, y), clear(x + dx, y + dy) { return FTSwipePath(fromX: x, fromY: y, toX: x + dx, toY: y + dy) }
            }
        }
        return nil
    }

    /// 始点を探す格子の目の数(容器の短い辺の何分の1か。`KeyboardDismissPoint.gridColumns` と同じ考え方)
    static let gridSteps = 24

    /// 中央から `ring` 目ぶん離れた格子の点(ring 0 = 中央)
    private static func ringOffsets(_ ring: Int) -> [(Int, Int)] {
        guard ring > 0 else { return [(0, 0)] }
        var out: [(Int, Int)] = []
        for ox in -ring...ring { out.append((ox, -ring)); out.append((ox, ring)) }
        for oy in (-ring + 1)..<ring { out.append((-ring, oy)); out.append((ring, oy)) }
        return out
    }
}
