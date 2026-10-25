// 座標で撃った操作(タップ・長押し・ダブルタップ)を、DSL のセレクタの行へ写せるかの判定。
// 呼び手はライブ操作の操作記録(Sources/fleetest/LiveOperationDSL.swift)と MCP の下書き(MCPServer+Draft.swift)。
// 同じ点が両方で同じ行になるよう判定はここ1箇所に置く(文言は呼び手の DraftNotes)。
//
// DSL の `tap(sel)` は要素の**中心**を押すので、押した点とはずれる。ずれても結果が同じになる要素だけを写す:
// 点を含む**操作可能な型**(`BridgeSnapshotThinning.operableTypes`)のうち**いちばん小さい**もの。
// 容器・マップ・キャンバス(操作可能な型でない)は中心を押すと別の物に当たるので写さない(座標の行のまま)。

import Foundation

public enum PointTarget {

    /// 操作可能な型のうち、**押した位置で結果が変わる**もの(中心を押すと別の値になる)。写さない
    static let positionSensitiveTypes: Set<String> = ["slider"]

    /// 点 (x, y) を中心で押しても同じ結果になる要素。無ければ nil(座標の行のまま)。
    /// 点は木の座標系(iOS pt / Android px)。枠の端ちょうどは含む
    public static func element(atX x: Double, y: Double, in elements: [ElementInfo]) -> ElementInfo? {
        elements
            .filter { BridgeSnapshotThinning.operableTypes.contains($0.type)
                && !positionSensitiveTypes.contains($0.type)
                && $0.frame.width > 0 && $0.frame.height > 0
                && x >= $0.frame.x && x <= $0.frame.x + $0.frame.width
                && y >= $0.frame.y && y <= $0.frame.y + $0.frame.height }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// 点に写る要素の書けるセレクタ(`SelectorNaming` の格付けつき)。写る要素が無い・書けるセレクタが無ければ nil。
    /// **いちばん小さい操作可能な要素が書けなければ、より大きい要素へ繰り上げない**(大きい要素の中心は押した点から遠い)
    public static func writableSelector(atX x: Double, y: Double,
                                        in snapshot: SnapshotResponse) -> (selector: String, durability: Durability)? {
        guard let element = element(atX: x, y: y, in: snapshot.elements) else { return nil }
        return SelectorNaming(snapshot).graded(for: element, in: snapshot)
    }
}
