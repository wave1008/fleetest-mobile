// ScenarioSelection.swift
// `fleetest run <id>...` / MCP `ft_run_scenario`/`ft_dry_run` が共有するクラス名展開ロジック。
// @Deleted(論理削除)/ @Draft(実装中)は全件実行・クラス名展開から除外(完全一致の明示指定のみ
// 実行可。実装しながら個別に回す運用のため)。

import Foundation

public enum ScenarioSelection {
    /// **クラス名の指定がそのシナリオを含むか**(`Class` は `Class.method` を全部含む)。`run --scenario` の展開・
    /// `results --scenario` の照合・trend のクラス名の名指しがこの1か所を使う(別々に持つと同じ指定で選ぶ集合が割れる)
    public static func isMember(_ scenarioID: String, ofClass selector: String) -> Bool {
        scenarioID.hasPrefix(selector + ".")
    }

    /// 指定(完全な ID かクラス名)がそのシナリオを選ぶか
    public static func selects(_ selector: String, scenarioID: String) -> Bool {
        scenarioID == selector || isMember(scenarioID, ofClass: selector)
    }

    /// `scenariosDir` は「見つからない」を `_disabled`(コンパイル対象外)在住と見分けるための
    /// 追加情報。省略した呼び出し元(profile/fleet 経由)は `notFound`(単純な文)のまま
    public static func resolve(_ ids: [String], from all: [ScenarioInfo],
                               scenariosDir: URL? = nil) throws -> [ScenarioInfo] {
        try resolveReportingCollapsed(ids, from: all, scenariosDir: scenariosDir).selected
    }

    /// `resolve` と同じ解決に加え、重なって1回に畳んだ ID(初出順)を返す。**黙って標本を減らさない**ために呼び手
    /// (`fleetest run` / `api run`・フリート・機械分担の入口)が `collapsedNotice` で1行言う。照合規則を別に写さない(ここで弾いた ID をそのまま返す)
    public static func resolveReportingCollapsed(_ ids: [String], from all: [ScenarioInfo],
                                                 scenariosDir: URL? = nil) throws
        -> (selected: [ScenarioInfo], collapsed: [String]) {
        guard !ids.isEmpty else { return (all.filter { !$0.deleted && !$0.draft }, []) }
        // 重なる指定(同じ ID の二重・クラス名とそのメソッド)は初出の位置に1回だけ入れる —— 数えて2回回すと
        // 集計が水増しされ、並列では同じシナリオが2台で同時に走りうる
        var result: [ScenarioInfo] = []
        var seen = Set<String>()
        var collapsed: [String] = []
        func append(_ infos: [ScenarioInfo]) {
            for info in infos {
                if seen.insert(info.id).inserted { result.append(info) }
                else if !collapsed.contains(info.id) { collapsed.append(info.id) }
            }
        }
        for id in ids {
            if let exact = all.first(where: { $0.id == id }) {
                append([exact])
                continue
            }
            let classMatches = all.filter { isMember($0.id, ofClass: id) && !$0.deleted && !$0.draft }
            guard !classMatches.isEmpty else {
                if all.contains(where: { isMember($0.id, ofClass: id) }) {
                    let members = all.filter { isMember($0.id, ofClass: id) }
                    throw ScenarioSelectionError.allDeletedOrDraft(
                        id: id, allDeleted: members.allSatisfy(\.deleted),
                        anyDeleted: members.contains(where: \.deleted))
                }
                if let scenariosDir {
                    throw ScenarioSelectionError.notFoundInScenariosDir(
                        id: id, available: all.map(\.id), scenariosDir: scenariosDir)
                }
                throw ScenarioSelectionError.notFound(id: id, available: all.map(\.id))
            }
            append(classMatches)
        }
        return (result, collapsed)
    }

    /// `resolveReportingCollapsed` の `collapsed` を知らせる1行(無ければ nil)。繰り返して回したいなら同じ指定を並べるのではなく
    /// run を回し直す
    public static func collapsedNotice(_ collapsed: [String]) -> String? {
        guard !collapsed.isEmpty else { return nil }
        return "→ \(collapsed.count) scenario(s) were named more than once and run only once: "
            + NameListing.joined(collapsed)
            + " (to repeat a scenario, run it again rather than naming it twice)"
    }
}

public enum ScenarioSelectionError: Error, LocalizedError, CustomStringConvertible {
    case allDeletedOrDraft(id: String, allDeleted: Bool, anyDeleted: Bool)
    case notFoundInScenariosDir(id: String, available: [String], scenariosDir: URL)
    case notFound(id: String, available: [String])

    public var errorDescription: String? {
        switch self {
        case .allDeletedOrDraft(let id, let allDeleted, let anyDeleted):
            // 削除が1本も無いのに「削除」と言わない(全部 draft のクラスの名指し)
            let reason = allDeleted
                ? "is deleted (@Deleted)"
                : anyDeleted ? "is deleted (@Deleted) or a draft (@Draft)" : "is a draft (@Draft)"
            return "every scenario of \(id) \(reason)"
                + " (an exact Class.method reference still runs it)"
        case .notFoundInScenariosDir(let id, let available, let scenariosDir):
            return ScenarioFolders.notFoundMessage(id: id, available: available, scenariosDir: scenariosDir)
        case .notFound(let id, let available):
            return "scenario not found: \(id) (available: \(available.joined(separator: ", ")))"
        }
    }

    public var description: String { errorDescription ?? "" }
}
