// シミュレータの backboardd(画面の合成)を起こし直す。**OS を動かしたまま全面の黒だけを戻す**(実測 2/2: 全面黒の iPhone が 61KB → 3.5MB の
// ホーム画面へ。別アプリの前面化と SpringBoard の起こし直しでは戻らなかった)。前面のアプリとブリッジも落ちるので、呼び手はブリッジを止めてから撃ち、
// 戻った後に張り直す。戻らなければ呼び手は shutdown → boot へ進む

import Foundation

public enum SimulatorDisplayServer {

    /// 撃つコマンド(テストが形を固定する)。`system/` は非推奨の警告を出すが動く(exit 0。実測)
    public static func command(udid: String) -> [String] {
        ["xcrun", "simctl", "spawn", udid, "launchctl", "kickstart", "-k", "system/com.apple.backboardd"]
    }

    /// 絵が戻るのを待つ上限(秒。実時間。撮影の待ちも含む)。**根拠**: 撃ってから絵が戻るまで実測 12〜16 秒(2 台)の約 2 倍。
    /// **尽きたときの発話**: 戻らなかったと呼び手へ返す(呼び手は再起動へ進み、その旨をログに出す)
    public static let drawingWaitSeconds: Double = 30
    /// 撮り直しの間隔(秒)。simctl の撮影 1 回が約 1.7 秒なので、その 2 倍弱あける
    public static let pollSeconds: Double = 3

    /// 全面が黒い(白い)絵か。上下の帯だけが残る絵も含む(ホームインジケータで `isUniformBlank` を割る形)
    public static func isBlankFrame(_ frame: Data) -> Bool {
        BlankFrameDetector.uniformBlankness(pngData: frame) != false || BlankFrameDetector.isUnjudgeable(pngData: frame)
    }

    /// 起こし直して絵が戻るまで待つ。true = 戻った。
    /// **撃つ前の絵が全面一様のときだけ撃つ**(実測があるのはこの形だけ。止まった絵では「一様でない」が戻った証拠にならない)。
    /// `capture` の引数は使ってよい秒数(期限を超えて塞がらない)。nil = 撮れなかった(戻ったとは言わない)
    public static func restartAndWaitForDrawing(
        run: () -> Bool,
        capture: (Double) async -> Data?,
        sleep: (Double) async -> Void,
        now: () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) async -> Bool {
        guard let before = await capture(drawingWaitSeconds), isBlankFrame(before), run() else { return false }
        let deadline = now() + drawingWaitSeconds
        while now() < deadline {
            await sleep(Swift.min(pollSeconds, deadline - now()))
            let remaining = deadline - now()
            guard remaining > 0 else { return false }
            if let frame = await capture(remaining), !isBlankFrame(frame) { return true }
        }
        return false
    }
}
