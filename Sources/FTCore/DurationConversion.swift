// `Duration` の数値への変換(どちらも1箇所。ブリッジの入力の `BridgeDTO.swift` に置かない = 版上げが要る)。

/// 整数ミリ秒(切り捨て。1ms = 1e15 attoseconds)
public func continuousClockMilliseconds(_ duration: Duration) -> Int {
    let (seconds, attoseconds) = duration.components
    return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
}

public func durationSeconds(_ duration: Duration) -> Double {
    let (seconds, attoseconds) = duration.components
    return Double(seconds) + Double(attoseconds) / 1e18
}
