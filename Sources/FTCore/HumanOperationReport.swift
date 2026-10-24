// シナリオ中に人がライブ操作で触った事実を、Markdown レポート(reports/scenario-*.md。子が書く)の末尾へ親が足す。
// 結果 JSON の `humanOperations` と同じ内容(`HumanOperationLedger`)。後から直す前例は `ResponseReportPatch`。

import Foundation

public enum HumanOperationReport {
    public static let heading = "## Human operations"

    /// 節の本文。時刻はローカル時刻(`HH:mm:ss.SSS`)で、失敗した操作は `✗` を付ける。
    /// 時刻が読めない行は載せない(推測で時刻を作らない)。載せる行が無ければ nil
    static func section(_ operations: [HumanOperationRecord], timeZone: TimeZone = .current) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss.SSS"
        let lines = operations.compactMap { operation -> String? in
            guard let date = operation.date else { return nil }
            return "- \(formatter.string(from: date)) \(operation.ok ? "" : "✗ ")\(operation.label)"
        }
        guard !lines.isEmpty else { return nil }
        return ([heading, ""] + lines).joined(separator: "\n") + "\n"
    }

    /// 末尾へ節を足したレポートの本文。足すものが無い・既に節がある、のときは nil(呼び手は書き直さない)
    public static func appending(markdown: String, operations: [HumanOperationRecord],
                                 timeZone: TimeZone = .current) -> String? {
        guard !markdown.contains(heading + "\n"), let section = section(operations, timeZone: timeZone) else {
            return nil
        }
        let separator = markdown.isEmpty ? "" : (markdown.hasSuffix("\n") ? "\n" : "\n\n")
        return markdown + separator + section
    }

    /// `reportPath`(絶対パスか、パッケージルート相対)のレポートへ足す。失敗の理由か nil(足す物が無いときも nil)
    public static func patch(reportPath: String?, packageRoot: URL?,
                             operations: [HumanOperationRecord]) -> String? {
        guard let reportPath, !operations.isEmpty else { return nil }
        let url = reportPath.hasPrefix("/")
            ? URL(fileURLWithPath: reportPath) : packageRoot?.appendingPathComponent(reportPath)
        guard let url else { return "report path \(reportPath) could not be resolved" }
        guard let markdown = try? String(contentsOf: url, encoding: .utf8) else {
            return "report \(url.path) could not be read"
        }
        guard let updated = appending(markdown: markdown, operations: operations) else { return nil }
        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return "report \(url.path) could not be written: \(error.localizedDescription)"
        }
    }
}
