// replace の消去の後に、消した欄を木から引き直す判定(DSL の StepExecutor.relocateAfterClear と MCP の ft_type が共有する)。
// 判定は実行器に置かない(CLAUDE.md「判定の関数を StepExecutor の static に置かない」)

public enum ClearedFieldRelocation {
    /// 同じ identifier の入力欄を引き直す。型が同じものを先に、無ければ入力欄どうし(Flutter の textField ⇄ secureTextField は
    /// 焦点で型が変わる)。どちらも1つに決まらなければ nil(別の欄に打たない)
    public static func byIdentifier(_ element: ElementInfo, id: String, in elements: [ElementInfo]) -> ElementInfo? {
        func only(_ matches: [ElementInfo]) -> ElementInfo? { matches.count == 1 ? matches[0] : nil }
        let sameId = elements.filter { $0.identifier == id }
        if let same = only(sameId.filter { $0.type == element.type }) { return same }
        guard TypeReadback.isTextInput(element) else { return nil }
        return only(sameId.filter { TypeReadback.isTextInput($0) })
    }

    /// 消去の後の木で、消した欄と**同じ欄**を引き直す(nil = 撃たない)。DSL(`StepExecutor.relocateAfterClear`)と MCP(ft_type)が
    /// 同じ順で引く: ①空でない identifier(`byIdentifier`)②`locate`(DSL はロケータの解決結果。型が同じときだけ採る ——
    /// ラベル・値で指したロケータは、欄を空にすると現れるヒントの文字に当たりうる。MCP は ref 指定なので nil)
    /// ③型と枠が同じ要素が1つ ④型と空でない placeholder / ラベルが同じ要素が1つ(id の無い欄がキーボードで動いた形 = アラートの入力欄)
    /// ⑤焦点のある同じ型の要素が1つ
    public static func relocate(_ element: ElementInfo, in elements: [ElementInfo],
                                locate: (() -> ElementInfo?)? = nil) -> ElementInfo? {
        func only(_ matches: [ElementInfo]) -> ElementInfo? { matches.count == 1 ? matches[0] : nil }
        if let id = element.identifier, !id.isEmpty { return byIdentifier(element, id: id, in: elements) }
        if let found = locate?(), found.type == element.type { return found }
        if let same = only(elements.filter { $0.type == element.type && $0.frame == element.frame }) { return same }
        if let hint = [element.placeholder, element.label].compactMap({ $0 }).first(where: { !$0.isEmpty }),
           let same = only(elements.filter { $0.type == element.type && ($0.placeholder == hint || $0.label == hint) }) {
            return same
        }
        return only(elements.filter { $0.type == element.type && $0.focused == true })
    }
}
