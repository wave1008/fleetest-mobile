// 操作の記録から作る DSL の行(MCP の ft_draft_scenario・ライブ操作の操作記録)の行末に残す但し書き。
// 文言は呼び手ごとに複製せずここに置く(片方だけ変えると、同じ操作の行が MCP とライブ操作で違う注意書きになる)。

import Foundation

public enum DraftNotes {
    /// 座標で撃った手の但し書き。セレクタへ置き換える前提の行だと伝える
    public static let coordinates = "coordinates — replace with a selector before keeping this;"
        + " a layout change makes it hit something else"

    /// 押した点がセレクタの形で押す要素の中心と結果が違い得る(地図・キャンバス等。`PointTarget.Target.pressesThePoint`)
    /// ことの但し書き。座標は木の座標系(iOS pt / Android px)を 0.1 に丸めて書く
    public static func pressedPoint(x: Double, y: Double) -> String {
        "pressed at (\(FTSeconds.format((x * 10).rounded() / 10)), \(FTSeconds.format((y * 10).rounded() / 10)));"
            + " the selector form presses the centre of the element"
    }

    /// 但し書きを1行にまとめる(無ければ nil)
    public static func joined(_ notes: String?...) -> String? {
        let present = notes.compactMap { $0 }.filter { !$0.isEmpty }
        return present.isEmpty ? nil : present.joined(separator: "; ")
    }

    /// セレクタの耐久性に応じた但し書き。安定なセレクタには**付けない** ——
    /// 全行にコメントが付くと読み飛ばされ、本当に危ない行が埋もれる
    public static func selectorDurability(_ durability: Durability) -> String? {
        switch durability {
        case .stable: return nil
        case .indexed: return "index-based selector — breaks if the number of same-type siblings changes"
        case .relative: return "relative selector — breaks if the layout around it changes"
        }
    }
}
