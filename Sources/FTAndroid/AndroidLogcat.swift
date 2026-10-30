// adb logcat の取得(ft_logs の Android 側材料)。AndroidDriver.adb(_:) と同じ ADB パス解決
// (AndroidDriver.findADB())を使う — 別解決を持つとどちらかだけが adb を見失う事故になる。
// 常に -d(ダンプして即終了)を付け、ストリームで固まらないようにする。

import FTCore
import Foundation

public enum AndroidLogcat {

    public struct Output: Equatable {
        public let lines: [String]
        /// packageName を渡したのに絞り込めなかった(プロセスが既に居ない)= 他アプリの行が混ざる
        public let scopedToPackage: Bool
        /// `-t` の絞り込みを端末の時間帯で組めなかった(ホストの時間帯で代用した)ときの注記。
        /// nil = 端末の時間帯で組めた、または絞り込み自体を使っていない
        public let cutoffNote: String?

        public init(lines: [String], scopedToPackage: Bool, cutoffNote: String? = nil) {
            self.lines = lines
            self.scopedToPackage = scopedToPackage
            self.cutoffNote = cutoffNote
        }
    }

    /// 直近のログ行。crashOnly なら crash バッファのみ、そうでなければ main+crash。
    /// packageName を渡すと pidof で対象プロセスの pid を引き `--pid` で絞る。
    /// **pidof が空を返すのはアプリが落ちて居なくなった正常ケース**(この道具の本命)。
    /// そのときテキスト一致へ落とすのは crash バッファでは有害 —— `FATAL EXCEPTION` と
    /// スタックトレースの行はパッケージ名を含まず、名指しで残るのは `Process:` の1行だけなので、
    /// **原因そのものを捨てる**。crash バッファは短いので絞らずに返し、混在は呼び出し側が明示する
    public static func recent(serial: String?, packageName: String?, crashOnly: Bool,
                              sinceSeconds: Int, maxLines: Int) throws -> Output {
        let adbPath = try AndroidDriver.findADB()
        // **logcat は宛先が居ないと「waiting for device」で戻らない**(-d でも。実測: 居ない serial で
        // 10s の打ち切りまで固まり、打ち切りの文言は「居ない」と言わない)。一覧が引けないときは不明 = 従来どおり進む
        // **一覧の全行(offline / unauthorized も)で照らす** —— state=device だけの connectedSerials で照らすと、
        // 載っている端末を「adb devices does not list it」と事実と違う言い方で断じる(AndroidTargetResolution と同じ規律)
        if let reason = notConnectedReason(serial: serial,
                                           connected: (try? AndroidDeviceCatalog.listedSerialStates()).map { Array($0.keys) }) {
            throw NotConnected(reason: reason)
        }

        // **crash バッファは現在の pid で絞らない**: 落ちたアプリを起動し直すと pid が変わり、`--pid` は前のプロセスの
        // クラッシュ行を全部捨てる(窓の中にあるのに「無い」と読める)。crash バッファは `crashScoped` が
        // 「パッケージ名を名乗る行のプロセス」の行だけを残す
        let hasPackage = !(packageName ?? "").isEmpty
        let scopesCrashBuffer = crashOnly && hasPackage
        // all: true も crash バッファの前のプロセスの行を落とさない(main は現在の pid・crash は crashScoped で別々に読んで束ねる)
        let readsCrashSeparately = !crashOnly && hasPackage
        let pid = scopesCrashBuffer ? nil : packageName.flatMap { resolvePID(adbPath: adbPath, serial: serial, packageName: $0) }

        var timeArgs: [String] = []
        var cutoffNote: String?
        if sinceSeconds > 0 {
            // `-t` は**端末のローカル時刻**で解釈される。ホストの時間帯で組むと、端末と時間帯が
            // 違うだけで(実機の海外設定・UTC のエミュレータ)数時間ぶん取りこぼす/余分に含む
            let offset = deviceUTCOffsetSeconds(adbPath: adbPath, serial: serial)
            if offset == nil {
                cutoffNote = "the device time zone could not be read (adb shell date +%z), so the"
                    + " \(sinceSeconds)s window was computed in the host time zone"
                    + " (\(TimeZone.current.identifier)) — it may be off by the zone difference"
            }
            timeArgs = ["-t", logcatTimeArgument(
                secondsAgo: sinceSeconds, now: Date(),
                deviceUTCOffsetSeconds: offset ?? TimeZone.current.secondsFromGMT())]
        }

        // 数秒でも固まると ft_logs の「ブリッジ抜きで診断する」目的そのものが崩れるため timeout を必ず付ける
        func dump(buffers: [String], pid: String?) throws -> String {
            var args = [adbPath]
            if let serial { args += ["-s", serial] }
            args += ["logcat", "-d"]
            for buffer in buffers { args += ["-b", buffer] }
            args += timeArgs
            if let pid { args += ["--pid", pid] }
            let result = try Shell.run(args, timeout: 10)
            guard result.status == 0 else {
                throw DriverError.badResponse(status: Int(result.status),
                    body: "adb logcat failed (is exactly one device connected, or was -s given?): \(result.tail)")
            }
            return result.output
        }

        // pid が引けていれば --pid が既に絞っている。引けなかったときのテキスト一致は
        // main バッファでだけ使う(crash バッファでやるとスタックトレースを捨てる。上のコメント参照)
        let textFilterPackage = (pid == nil && !crashOnly) ? packageName : nil
        if readsCrashSeparately, let packageName {
            let mainLines = filter(rawOutput: try dump(buffers: ["main"], pid: pid), packageName: textFilterPackage, maxLines: 0)
            let crashLines = filter(rawOutput: crashScoped(rawOutput: try dump(buffers: ["crash"], pid: nil),
                                                           packageName: packageName), packageName: nil, maxLines: 0)
            let merged = mergedByTimestamp(mainLines, crashLines)
            return Output(lines: maxLines > 0 && merged.count > maxLines ? Array(merged.suffix(maxLines)) : merged,
                          scopedToPackage: true, cutoffNote: cutoffNote)
        }
        var raw = try dump(buffers: crashOnly ? ["crash"] : ["main", "crash"], pid: pid)
        if scopesCrashBuffer, let packageName { raw = crashScoped(rawOutput: raw, packageName: packageName) }
        return Output(
            lines: filter(rawOutput: raw, packageName: textFilterPackage, maxLines: maxLines),
            scopedToPackage: packageName == nil || pid != nil || textFilterPackage != nil || scopesCrashBuffer,
            cutoffNote: cutoffNote)
    }

    /// 2本の logcat 行(各々は時刻順)を行頭の時刻(`MM-dd HH:mm:ss.SSS`、threadtime 書式の先頭 18 文字)で束ねる。
    /// 時刻の読めない行(`--------- beginning of` 等)は前の行の後ろに付く。同時刻は a → b の順(安定)
    static func mergedByTimestamp(_ a: [String], _ b: [String]) -> [String] {
        func stamp(_ line: String) -> String? {
            let head = line.prefix(18)
            guard head.count == 18, head.dropFirst(2).first == "-", head.dropFirst(5).first == " " else { return nil }
            return String(head)
        }
        var out: [String] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if j >= b.count { out.append(a[i]); i += 1; continue }
            if i >= a.count { out.append(b[j]); j += 1; continue }
            let ta = stamp(a[i]), tb = stamp(b[j])
            if let ta, let tb, tb < ta { out.append(b[j]); j += 1 } else { out.append(a[i]); i += 1 }
        }
        return out
    }

    public struct NotConnected: LocalizedError, Equatable {
        public let reason: String
        public var errorDescription: String? { reason }
    }

    /// 宛先が `adb devices` に居ないときの文言。`connected` が nil(一覧が引けない)は不明なので nil を返す
    static func notConnectedReason(serial: String?, connected: [String]?) -> String? {
        guard let connected else { return nil }
        if let serial {
            return connected.contains(serial) ? nil
                : "serial \(serial) is not connected (adb devices does not list it)"
        }
        return connected.isEmpty ? "no Android device is connected (adb devices lists none)" : nil
    }

    /// 端末の UTC オフセット(秒)を `adb shell date +%z` で1回だけ引く。失敗/読めない書式は nil
    /// (呼び出し側がホストの時間帯へ落とし、その旨を注記する)
    private static func deviceUTCOffsetSeconds(adbPath: String, serial: String?) -> Int? {
        var args = [adbPath]
        if let serial { args += ["-s", serial] }
        args += ["shell", "date", "+%z"]
        guard let result = try? Shell.run(args, timeout: 5), result.status == 0 else { return nil }
        return utcOffsetSeconds(fromDateZ: result.output)
    }

    /// `date +%z` の出力(`+0900` / `-0500`。末尾の改行・空白は無視)→ 秒。書式外は nil
    static func utcOffsetSeconds(fromDateZ output: String) -> Int? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count == 5, let sign = text.first, sign == "+" || sign == "-",
              text.dropFirst().allSatisfy(\.isNumber),
              let hours = Int(text.dropFirst().prefix(2)), let minutes = Int(text.suffix(2)),
              hours <= 23, minutes <= 59 else { return nil }
        let magnitude = hours * 3600 + minutes * 60
        return sign == "-" ? -magnitude : magnitude
    }

    /// crash バッファの生テキストから、パッケージ名を名乗る行(`Process: <pkg>, PID: n` / `>>> <pkg> <<<`)を出した
    /// プロセスの行だけを残す。**logcat の行頭(threadtime 書式)の pid 列で照らす** —— スタックトレースの行は
    /// パッケージ名を含まないので、名前の一致だけで絞ると原因そのものを捨てる。pid 列を読めない行は残さない。
    /// パッケージ名の一致は前後が識別子文字でないものに限る(`com.x` が `com.x.flutter` を拾わない)
    static func crashScoped(rawOutput: String, packageName: String) -> String {
        let lines = rawOutput.split(separator: "\n", omittingEmptySubsequences: true)
        func pidColumn(_ line: Substring) -> Substring? {
            let columns = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard columns.count >= 3, columns[2].allSatisfy(\.isNumber) else { return nil }
            return columns[2]
        }
        func names(_ line: Substring) -> Bool {
            var rest = line[...]
            while let range = rest.range(of: packageName) {
                let before = range.lowerBound > line.startIndex ? line[line.index(before: range.lowerBound)] : " "
                let after = range.upperBound < line.endIndex ? line[range.upperBound] : " "
                func isIdentifier(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "." }
                if !isIdentifier(before) && !isIdentifier(after) { return true }
                rest = line[range.upperBound...]
            }
            return false
        }
        let pids = Set(lines.compactMap { names($0) ? pidColumn($0).map(String.init) : nil })
        return lines.filter { line in pidColumn(line).map { pids.contains(String($0)) } ?? false }
            .joined(separator: "\n")
    }

    /// 生の logcat テキストを行へ分解し、package で絞り(部分一致)、末尾 maxLines へ切り詰める。
    /// maxLines <= 0 は「切り詰めない」。
    static func filter(rawOutput: String, packageName: String?, maxLines: Int) -> [String] {
        var lines = rawOutput.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if let packageName, !packageName.isEmpty {
            lines = lines.filter { $0.contains(packageName) }
        }
        guard maxLines > 0, lines.count > maxLines else { return lines }
        return Array(lines.suffix(maxLines))
    }

    /// `adb shell pidof <pkg>` で pid を引く。複数返る(同名プロセス)場合は先頭のみ使う。
    /// 空/失敗はどちらも nil(呼び出し側がテキスト一致へフォールバックする)
    private static func resolvePID(adbPath: String, serial: String?, packageName: String) -> String? {
        guard AndroidPackageName.isShellSafe(packageName) else { return nil }
        var args = [adbPath]
        if let serial { args += ["-s", serial] }
        args += ["shell", "pidof", packageName]
        guard let result = try? Shell.run(args, timeout: 5), result.status == 0 else { return nil }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(separator: " ").first.map(String.init)
    }

    /// logcat `-t` の時刻絞り込み書式("yyyy-MM-dd HH:mm:ss.SSS")。**端末のローカル時刻**で組む
    /// (deviceUTCOffsetSeconds = 端末の UTC オフセット秒。ホストの時間帯ではない)。
    /// **年を落とさない** —— 年なし("MM-dd …")は logcat が「今年」と読むので、年をまたぐ窓
    /// (1月初旬の「直近数日」)の起点が今年の12月 = 未来になり、クラッシュがあっても 0 行で返る。
    /// 起点は 1970 年より前へ出さない(巨大な secondsAgo で年が負になると logcat が読めない)。
    /// 時計そのもののずれは残るが致命ではない(末尾 maxLines への切り詰めで上限は掛かる。
    /// エミュレータはホストと時刻同期・実機も NTP 同期が通常)
    static func logcatTimeArgument(secondsAgo: Int, now: Date, deviceUTCOffsetSeconds: Int) -> String {
        let cutoff = now.addingTimeInterval(-min(Double(secondsAgo), now.timeIntervalSince1970))
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.timeZone = TimeZone(secondsFromGMT: deviceUTCOffsetSeconds) ?? TimeZone(identifier: "UTC")!
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: cutoff)
    }
}
