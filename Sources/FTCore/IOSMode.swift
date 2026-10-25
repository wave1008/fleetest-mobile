// iOS のモード(実行プロファイルの `iosMode` / `devices[].mode`。ブリッジの種類とは別の語彙)。
// inapp-boost = XCUITest ブリッジに in-app ブリッジを足したハイブリッド構成。in-app ブリッジで撃てる操作は
// そちらで速く撃ち、撃てない操作は XCUITest ブリッジで撃つ /
// xcuitest = XCUITest ブリッジだけ。in-app ブリッジ単独の構成は選べない

public enum IOSMode {
    public static let inappBoost = "inapp-boost"
    public static let xcuitest = "xcuitest"
    public static let all: Set<String> = [inappBoost, xcuitest]

    /// モードの主ポートに居るブリッジの種類(/status の `bridge` の値)。モード名とブリッジ名は別の語彙なので
    /// モードの値をブリッジの比較へそのまま渡さない。nil / 未知の値は nil(= 呼び手の既定)
    public static func primaryBridge(forMode mode: String?) -> String? {
        switch mode {
        case inappBoost: return "inapp"
        case xcuitest: return "xcuitest"
        default: return nil
        }
    }
}
