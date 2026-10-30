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
}
