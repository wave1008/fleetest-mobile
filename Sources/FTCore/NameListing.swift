// 1行の注記に名前を並べるときの上限と書式(重なったシナリオの指定・推移のクラスの中身が共有する)

public enum NameListing {
    /// 並べる名前の上限(件)。根拠: 1行の注記に収まって読み切れる数。超えた分は ", ..." で省き、総数は呼び手の文面が別に言う
    public static let limit = 5

    public static func joined(_ names: [String]) -> String {
        names.prefix(limit).joined(separator: ", ") + (names.count > limit ? ", ..." : "")
    }
}
