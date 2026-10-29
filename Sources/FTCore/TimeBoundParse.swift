// TimeBoundParse.swift
// "--since"/"--until" のような時刻境界オプションの文字列を Date へ変換する唯一の実装。
// fleetest results / fleetest api results(RunResultsQuery.parseSince)と
// fleetest api host-metrics-summary が共有する(呼び出し元を増やすときもここへ集約すること)。

import Foundation

public enum TimeBoundParse {

    /// 受理する3形: "YYYY-MM-DD"(**UTC 0時**。表の時刻はローカルなので、日本時間では 09:00 に当たる)/ "<num>[smhd]"(小数可・0以下は拒否・now から遡る相対期間)/
    /// "@<epoch>"(GNU `date -d @<epoch>` に倣い "@" 接頭辞必須・小数可)。**裸の数値は拒否**——
    /// epoch として読むと "30d" の打ち間違いの "30" が epoch 30(≈1970年 = 実質全期間)として
    /// 黙って通ってしまう。どれにも一致しなければ nil(呼び出し側でエラーにすること)
    public static func parse(_ raw: String, now: Date = Date()) -> Date? {
        let parsed = parseAbsoluteDate(raw) ?? parseRelativeDuration(raw, now: now) ?? parseEpoch(raw)
        guard let parsed, parsed >= earliestSupported, parsed <= latestSupported else { return nil }
        return parsed
    }

    /// 受理する範囲(0001-01-01T00:00:00Z 〜 9999-12-31T23:59:59Z)。根拠: 結果の月ディレクトリ名・窓の鍵は
    /// 年を `%04d` で文字列化して辞書順に比べるので、紀元前(era 0 の year は正の値)や5桁の年は
    /// 比較が反転し、窓が空(または全月を落とす)になって「No matching runs」で終わる。範囲外は
    /// 黙って空にせず不正な値として断る(呼び手が rejection の文言を返す)
    static let earliestSupported = Date(timeIntervalSince1970: -62_135_596_800)
    static let latestSupported = Date(timeIntervalSince1970: 253_402_300_799)

    /// parse(_:now:) が nil を返したときに呼び手が投げる文言を組む。オプション名だけ渡せば済むように
    /// ここへ集約する(「判定は1箇所・文言は呼び手ごと」の規律だが、同じ文法を2通りに説明しないため
    /// 文言のテンプレート自体は共有する)
    /// 書式は正しいが範囲の外の値(`999999d`・`@1e15` 等)は、書式の誤りと言わずに範囲を名指しする
    public static func rejection(option: String, raw: String, now: Date = Date()) -> String {
        if parseAbsoluteDate(raw) ?? parseRelativeDuration(raw, now: now) ?? parseEpoch(raw) != nil {
            return "\(option) is outside the supported range (years 0001 to 9999 UTC): \(raw)"
        }
        return "\(option) must be a duration (e.g. 90s/30m/2h/30d), a date (YYYY-MM-DD, UTC midnight) or an epoch (@1757280000): \(raw)"
    }

    private static func parseAbsoluteDate(_ raw: String) -> Date? {
        guard raw.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        // **先発グレゴリオ暦で自分で数える**(days_from_civil)。Foundation の formatter(DateFormatter・ISO8601DateFormatter とも)は
        // 1582 年より前をユリウス暦で数えるので、範囲の下限 0001-01-01 が下限より前の時刻になり、受理すると書いた日付を断っていた
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let (year, month, day) = (parts[0], parts[1], parts[2])
        let isLeap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let daysInMonth = [31, isLeap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...12).contains(month), (1...daysInMonth[month - 1]).contains(day) else { return nil }
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let daysSinceEpoch = era * 146_097 + dayOfEra - 719_468
        return Date(timeIntervalSince1970: Double(daysSinceEpoch) * 86_400)
    }

    private static func parseRelativeDuration(_ raw: String, now: Date) -> Date? {
        guard raw.range(of: #"^[0-9]+(?:\.[0-9]+)?[smhd]$"#, options: .regularExpression) != nil,
              let unitChar = raw.last, let amount = Double(raw.dropLast()), amount > 0 else { return nil }
        let unitSeconds: TimeInterval
        switch unitChar {
        case "s": unitSeconds = 1
        case "m": unitSeconds = 60
        case "h": unitSeconds = 3600
        case "d": unitSeconds = 86400
        default: return nil  // 正規表現で [smhd] に限定済みのため到達しない
        }
        return now.addingTimeInterval(-amount * unitSeconds)
    }

    /// "@" 接頭辞必須。裸の数値を epoch と読まない理由は parse(_:now:) の doc 参照。
    /// **isFinite を通す** —— `Double("nan")` / `Double("inf")` は成功するので、外すと
    /// 比較が常に false になる Date が下流へ流れて窓の絞り込みが黙って効かなくなる
    private static func parseEpoch(_ raw: String) -> Date? {
        guard raw.hasPrefix("@"), let epoch = Double(raw.dropFirst()), epoch.isFinite else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }
}
