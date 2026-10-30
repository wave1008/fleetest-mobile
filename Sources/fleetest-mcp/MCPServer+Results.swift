// MCPServer+Results.swift
// ft_results: `fleetest results <list|summary|flaky|trend|devices|slow|insights|log>` と同じ出力(JSON は無い)。
// **集計は FTCore.RunResultsQuery・整形は FTCore.ResultsRendering / ResultsLogReport の1箇所**
// (CLI と共有。ここで表や文言を作り直さない)。**CLI は Codex 等のシェルのサンドボックス内で動かない**ので
// 結果の履歴は MCP からも引けるようにしてある。

import Foundation
import FTCore

/// 入口で検査した ft_results の引数(Sendable なので走査をプールの外へ出せる)
struct MCPResultsRequest: Sendable, Equatable {
    static let queries = ["list", "summary", "flaky", "trend", "devices", "slow", "insights", "log"]

    var query: String
    var since: String
    var scenario: String?
    var runID: String?
    var limit: Int?
    var minRuns: Int?

    /// 引数名 → それを読む query。**読まれない query に渡されたら断る**(黙って効かない形を作らない)
    private static let appliesTo: [(argument: String, queries: Set<String>)] = [
        ("scenario", ["summary", "trend", "log"]),
        ("runId", ["log"]),
        ("limit", ["list", "slow"]),
        ("minRuns", ["flaky"]),
    ]

    static func parse(_ args: [String: Any]) throws -> MCPResultsRequest {
        let query = try MCPServer.requiredStringArgument(args, "query")
        guard queries.contains(query) else {
            throw MCPError("query must be one of: \(queries.joined(separator: ", ")) (got \(query))")
        }
        for (argument, accepted) in appliesTo where args[argument] != nil && !accepted.contains(query) {
            throw MCPError("\(argument) does not apply to query \(query) — it is read by: "
                + queries.filter(accepted.contains).joined(separator: ", "))
        }
        if query == "log", args["since"] != nil {
            throw MCPError("since does not apply to query log — pass runId (default latest)")
        }
        let scenario = try MCPServer.stringArgument(args, "scenario")
        if let scenario, scenario.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MCPError("scenario must not be empty")
        }
        if query == "trend", scenario == nil {
            throw MCPError("scenario is required for query trend")
        }
        return MCPResultsRequest(
            query: query,
            since: try MCPServer.stringArgument(args, "since") ?? ResultsRendering.defaultSince,
            scenario: scenario,
            runID: try MCPServer.stringArgument(args, "runId"),
            limit: try MCPServer.intArgument(args, "limit"),
            minRuns: try MCPServer.intArgument(args, "minRuns"))
    }

    /// CLI(`fleetest results <query>`)と同じ文面。**デバイス・ブリッジに触らない**。
    /// `memo` はサーバが持つ完了 run の解読結果(2回目以降は新しい run だけを読む)。中身は縮小記録なので
    /// trend だけは元ファイルを読み直す(`RunResultsStore.fullRecords`)
    /// パックの鍵(`RunRecordPack` の executableKey)。**起動時に1回だけ決める**(main が最初に触る) —— 呼ぶたびに
    /// ディスクの実行ファイルを stat すると、ビルドで差し替わった後も動き続ける古いプロセスが、新しいビルドの鍵で
    /// 古い型の記録を書き、新しいプロセスがそれを有効と読んで欄を黙って落とす(鍵がそもそも防ぐはずの形)
    static let packExecutableKey = ResultsOutputCache.executableFingerprint(executable: ExecutablePath.current)

    func render(project: TestProject, memo: RunRecordMemo? = nil, now: Date = Date()) throws -> String {
        let resultsDir = RunResultsStore.resultsDir(projectRoot: project.rootURL)
        if query == "log" {
            let sections: [ResultsLogReport.Section]
            do {
                sections = try ResultsLogReport.build(
                    resultsDir: resultsDir, projectName: project.name, requestedRunID: runID ?? "latest",
                    scenario: scenario, raw: false)
            } catch let error as ResultsLogError {
                throw MCPError(error.message)
            }
            return ResultsLogReport.text(sections)
        }
        guard let sinceDate = RunResultsQuery.parseSince(since, referenceDate: now) else {
            throw MCPError(TimeBoundParse.rejection(option: "since", raw: since, now: now))
        }
        // summary / flaky / slow は CLI の `results` と同じく窓(since)の全 run を集計する。拡張のダッシュボードと
        // `api results` はシナリオごとの直近 recentScenarioRunsWindow 本だけなので、数字が食い違ったときに理由が読めるよう言う
        let windowNote = "\n(computed over every run since \(since); the extension's dashboard counts only each scenario's"
            + " last \(RunResultsQuery.recentScenarioRunsWindow) runs, so its numbers can differ)"
        // **サーバで初めて引く回もディスクのパックを読む**(無いと起動のたびに 90 日ぶんの全ファイルを解読し直す。
        // E2E-CMP の約 8.4 万ファイルで 1 回目 8.3 秒・2 回目以降はプロセス内の控え(memo)で 3.8 秒)。置き場所は CLI と分ける
        let packCacheDir = RunRecordPack.cacheDir(stateDir: project.stateDir, program: .mcp)
        let packExecutableKey = Self.packExecutableKey
        func scannedEntries() -> [RunResultsStore.ScannedRecord] {
            RunResultsStore.scanRunsAndRecords(resultsDir: resultsDir, since: sinceDate, packCacheDir: packCacheDir,
                                               executableKey: packExecutableKey, memo: memo).entries
        }
        switch query {
        case "list":
            let runs = RunResultsStore.scanRuns(resultsDir: resultsDir, since: sinceDate)
            return ResultsRendering.list(
                RunResultsQuery.recentRuns(runs, limit: limit ?? ResultsRendering.defaultListLimit))
        case "summary":
            let records = scannedEntries().map(\.record)
            // 照合は CLI の `results summary --scenario` と同じ(クラス名で全メソッド = ScenarioSelection.selects)
            let filtered = scenario.map { id in
                records.filter { ScenarioSelection.selects(id, scenarioID: $0.scenarioID) }
            } ?? records
            let rows = RunResultsQuery.scenarioSummary(filtered, recentRuns: .max)
            // 注記は数字の行があるときだけ(「該当なし」に数字の食い違いの話を付けない = 注記の予算)
            return ResultsRendering.summary(rows) + (rows.isEmpty ? "" : windowNote)
        case "flaky":
            let records = scannedEntries().map(\.record)
            let minRuns = minRuns ?? ResultsRendering.defaultMinRuns
            let rows = RunResultsQuery.flakyScenarios(records, minRuns: minRuns, recentRuns: .max)
            return ResultsRendering.flaky(rows, minRuns: minRuns, minRunsOption: "minRuns")
                + (rows.isEmpty ? "" : windowNote)
        case "trend":
            let id = scenario ?? ""
            let entries = scannedEntries()
            let records = RunResultsStore.fullRecords(entries: entries, scenarioID: id)
            let rows = RunResultsQuery.trend(records, scenarioID: id)
            // クラス名は「履歴なし」と見分けが付かないので名指しして断る(CLI の `results trend` と同じ判定)
            if rows.isEmpty, let listing = RunResultsQuery.trendClassMemberListing(
                selector: id, scenarioIDs: entries.map(\.record.scenarioID)) {
                throw MCPError("scenario \(id) is a class name; trend takes one scenario ID (Class.method): " + listing)
            }
            return ResultsRendering.trend(rows, scenario: id)
        case "devices":
            let records = scannedEntries().map(\.record)
            return ResultsRendering.devices(RunResultsQuery.deviceSummary(records))
        case "slow":
            let records = scannedEntries().map(\.record)
            let rows = RunResultsQuery.slowTests(records, limit: limit ?? ResultsRendering.defaultSlowLimit, recentRuns: .max)
            return ResultsRendering.slow(rows) + (rows.isEmpty ? "" : windowNote)
        case "insights":
            let scanned = RunResultsStore.scanRunsAndRecords(resultsDir: resultsDir, since: sinceDate,
                                                             packCacheDir: packCacheDir,
                                                             executableKey: packExecutableKey, memo: memo)
            let records = scanned.entries.map(\.record)
            let runs = scanned.runs
            // ソース走査だけ(ビルドしない)。走査できなければ空集合 = 供給なし扱い
            let defined = Set(ScenarioFolders.classFileMap(scenariosDir: project.scenariosDir).keys)
            return ResultsRendering.insights(
                RunResultsQuery.insights(records: records, runs: runs, definedClasses: defined), runCount: runs.count)
        default:
            throw MCPError("query must be one of: \(Self.queries.joined(separator: ", ")) (got \(query))")
        }
    }
}

extension MCPServer {
    func ftResults(_ args: [String: Any]) async throws -> [[String: Any]] {
        let request = try MCPResultsRequest.parse(args)
        let project = try ScenarioHost.project(named: args["project"] as? String)
        // 90 日窓の走査は重い。協調スレッドプールにディスク走査を載せない(他の ft_* と同居している)
        let memo = resultsMemo
        let output = try await Task.detached(priority: .utility) {
            try request.render(project: project, memo: memo)
        }.value
        return text(output)
    }
}
