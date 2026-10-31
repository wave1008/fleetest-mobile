// `Duration` の数値への変換はここだけ。ブリッジの入力の `BridgeDTO.swift` に置かない(版上げが要る)。
// 型の中に置く: FTCore は FTDSL の `@_exported` で受け手のシナリオへ公開されるので、素の関数は受け手の名前空間へ漏れる。

public enum DurationConversion {
    /// 整数ミリ秒(切り捨て。1ms = 1e15 attoseconds)
    public static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }

    public static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
