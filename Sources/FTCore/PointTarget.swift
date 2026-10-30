// 座標で撃った操作(タップ・長押し・ダブルタップ)を、DSL のセレクタの行へ写す判定。
// 呼び手はライブ操作の操作記録(Sources/fleetest/LiveOperationDSL.swift)と MCP の下書き(MCPServer+Draft.swift)。
// 同じ点が両方で同じ行になるよう判定はここ1箇所に置く(文言は呼び手の DraftNotes)。
//
// DSL の `tap(sel)` は要素の**中心**を押すので、押した点とはずれる。写す先は2段:
//  1. 点を含む**操作可能な型**(`BridgeSnapshotThinning.operableTypes`)のうちいちばん小さいもの —— ずれても結果は同じ
//     (`pressesThePoint == true`)。これが在るのに書けるセレクタが無ければ、より大きい要素へは繰り上げない(座標の行)
//  2. 1 が無ければ、点を含むいちばん小さい要素(型を問わない。地図・キャンバス等)—— 中心を押すと結果が変わり得るので、
//     呼び手は押した点を但し書きに残す(`pressesThePoint == false`)。**画面全体を覆う要素・押した位置で結果が変わる型は除く**。
//     **中心を押してもその要素自身に当たるときだけ**(中心に、より小さい要素が在れば座標の行 = 余白を押した容器の行が
//     中央のボタンを押す形にしない)。**安定したセレクタが書けるときだけ**(索引形・相対形なら座標の行)

import Foundation

public enum PointTarget {

    /// 操作可能な型のうち、**押した位置で結果が変わる**もの(中心を押すと別の値になる)。どちらの段にも採らない
    static let positionSensitiveTypes: Set<String> = ["slider"]

    public struct Target: Equatable {
        public let selector: String
        public let durability: Durability
        /// 要素の中心を押しても押した点と同じ結果になる(操作可能な型)か
        public let pressesThePoint: Bool
    }

    /// 点 (x, y) を中心で押しても同じ結果になる要素(1 段目)。無ければ nil。
    /// 点は木の座標系(iOS pt / Android px)。枠の端ちょうどは含む
    public static func element(atX x: Double, y: Double, in elements: [ElementInfo]) -> ElementInfo? {
        smallest(atX: x, y: y, in: elements.filter {
            BridgeSnapshotThinning.operableTypes.contains($0.type) && !positionSensitiveTypes.contains($0.type)
        })
    }

    /// 点に写る要素の書けるセレクタ(`SelectorNaming` の格付けつき)。写る要素が無い・書けるセレクタが無ければ nil
    /// `notDrawn` = 木に枠だけ残っていて、そこには描かれていない要素の ref(スクロール容器の外の残像。判定は呼び手 = MCP の `ghostRefs`)。
    /// 点に写る要素がそれなら**書かない**(nil = 座標の行): セレクタの行は送り戻して別の物を押す
    public static func writableSelector(atX x: Double, y: Double, in snapshot: SnapshotResponse,
                                        notDrawn: Set<Int> = []) -> Target? {
        let naming = SelectorNaming(snapshot)
        if let operable = element(atX: x, y: y, in: snapshot.elements) {
            if notDrawn.contains(operable.ref) { return nil }
            return naming.graded(for: operable, in: snapshot)
                .map { Target(selector: $0.selector, durability: $0.durability, pressesThePoint: true) }
        }
        guard let area = smallest(atX: x, y: y, in: snapshot.elements.filter {
            !TapTargetGeometry.contains($0.frame, snapshot.screen) && !positionSensitiveTypes.contains($0.type)
        }), !notDrawn.contains(area.ref) else { return nil }
        // 中心に別の(より小さい)要素が在れば、セレクタの行はそちらを押す(Android の `#nav_host_fragment` の余白 等)
        let centre = (x: area.frame.x + area.frame.width / 2, y: area.frame.y + area.frame.height / 2)
        guard smallest(atX: centre.x, y: centre.y, in: snapshot.elements)?.ref == area.ref else { return nil }
        // 2 段目は**安定したセレクタ(一意な #id・ラベル)が書けるときだけ**写す —— 中心を押すとずれ得る弱さに
        // 索引形・相対形の壊れやすさまで重なると座標の行より悪い(実測: Apple マップで `#Maps.Application >> .other[22]`)
        guard let graded = naming.graded(for: area, in: snapshot), graded.durability == .stable else { return nil }
        return Target(selector: graded.selector, durability: graded.durability, pressesThePoint: false)
    }

    private static func smallest(atX x: Double, y: Double, in elements: [ElementInfo]) -> ElementInfo? {
        elements
            .filter { $0.frame.width > 0 && $0.frame.height > 0
                && x >= $0.frame.x && x <= $0.frame.x + $0.frame.width
                && y >= $0.frame.y && y <= $0.frame.y + $0.frame.height }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }
}
