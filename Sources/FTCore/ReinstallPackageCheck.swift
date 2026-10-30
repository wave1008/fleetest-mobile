// 実機の入れ直し(clearAppData の uninstall + install)に使うパッケージが「その端末へ入れられ、消すアプリのものか」の判定。
// **消す前に断るための判定**(uninstall の後では戻せない)。MCP の ft_clear_app_data と DSL の clearAppData が共有する
// (CLAUDE.md「判定は MCP と DSL で共有する」)。**文言は呼び手が持つ**(MCP は packagePath:、DSL は appPathPhysical を案内する)。

import Foundation

public enum ReinstallPackageCheck: Equatable, Sendable {
    case ok
    /// Simulator 用ビルド(iphonesimulator SDK)。実機へは `0xe8008014 invalid signature` で入らない
    case simulatorBuild
    /// 消そうとしているアプリと別の bundle ID のパッケージ
    case differentApp(packageBundleID: String)
    /// Info.plist が読めない・bundle ID が無い(消してよいと言えない)
    case unreadable

    /// Info.plist だけから決める純粋関数。**Simulator 用かを bundle ID より先に見る**(どちらでも消さないが、
    /// 入れ直せない原因のほうが根本)。読めた plist が iphoneos と iphonesimulator のどちらも名乗らなければ素通し
    /// (bundle ID の検査は残る)
    public static func judge(infoPlist: [String: Any]?, expectedBundleID: String) -> ReinstallPackageCheck {
        guard let infoPlist else { return .unreadable }
        if isSimulatorBuild(infoPlist: infoPlist) { return .simulatorBuild }
        guard let packageBundleID = infoPlist["CFBundleIdentifier"] as? String, !packageBundleID.isEmpty
        else { return .unreadable }
        return packageBundleID == expectedBundleID ? .ok : .differentApp(packageBundleID: packageBundleID)
    }

    /// `DTPlatformName` が iphonesimulator、または `CFBundleSupportedPlatforms` が iPhoneSimulator だけを名乗る
    public static func isSimulatorBuild(infoPlist: [String: Any]) -> Bool {
        if let name = infoPlist["DTPlatformName"] as? String,
           name.caseInsensitiveCompare("iphonesimulator") == .orderedSame { return true }
        guard let platforms = infoPlist["CFBundleSupportedPlatforms"] as? [String], !platforms.isEmpty
        else { return false }
        let isSimulator = platforms.contains { $0.caseInsensitiveCompare("iPhoneSimulator") == .orderedSame }
        return isSimulator && AppBundleInspector.isDeviceBuild(supportedPlatforms: platforms) == false
    }

    /// この判定で uninstall を止めるか。**読めないときだけ入れ直し元の出所で分かれる**: 呼び手が名指ししたパッケージ
    /// (MCP の `packagePath:`)は申告を信じて通す / 記録から引いたもの(MCP の控え・DSL のプロファイルの
    /// appPathPhysical)は確かめられないので止める。Simulator 用・別アプリは出所に関わらず止める
    public func blocksUninstall(packageNamedByCaller: Bool) -> Bool {
        switch self {
        case .ok: return false
        case .simulatorBuild, .differentApp: return true
        case .unreadable: return !packageNamedByCaller
        }
    }

    /// パスが「パッケージの形」か(.ipa のファイル / Info.plist を持つ .app のフォルダ)。**呼び手が名指ししたパスでも、
    /// この形でなければ消す前に断る** —— フォルダや Info.plist を渡すと devicectl が後から断り、uninstall 済みの
    /// アプリが端末から消えたまま終わる。`unreadable` の「申告を信じる」は、形が正しいのに読めない場合だけ
    public static func looksLikePackage(path: String, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        switch (path as NSString).pathExtension.lowercased() {
        case "ipa": return !isDirectory.boolValue
        case "app":
            return isDirectory.boolValue
                && fileManager.fileExists(atPath: (path as NSString).appendingPathComponent("Info.plist"))
        default: return false
        }
    }

    /// `looksLikePackage` を通った名指しのパスに、**入れられる中身が無い**ときの理由(あれば nil でない)。
    /// .ipa は zip の署名(`PK\u{3}\u{4}`)・.app は Info.plist の `CFBundleExecutable` が指す実行ファイルを見る。
    /// 形だけ整った偽物は devicectl が uninstall の後で断り、アプリが端末から消えたまま終わる。
    /// **読めた中身の正しさ(署名・bundle ID)は見ない** —— 見るのは「パッケージとして空か」だけ
    public static func emptyPackageReason(path: String, fileManager: FileManager = .default) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "ipa":
            guard let handle = FileHandle(forReadingAtPath: path) else { return "the .ipa cannot be opened" }
            defer { try? handle.close() }
            let head = (try? handle.read(upToCount: 4)) ?? Data()
            return head == Data([0x50, 0x4B, 0x03, 0x04]) ? nil : "the .ipa is not a zip archive"
        case "app":
            let plistPath = (path as NSString).appendingPathComponent("Info.plist")
            guard let data = fileManager.contents(atPath: plistPath),
                  let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
            else { return "its Info.plist cannot be read" }
            guard let executable = plist["CFBundleExecutable"] as? String, !executable.isEmpty
            else { return "its Info.plist has no CFBundleExecutable" }
            return fileManager.fileExists(atPath: (path as NSString).appendingPathComponent(executable))
                ? nil : "the executable \(executable) is missing from the .app"
        default:
            return nil
        }
    }

    /// パスのパッケージを読んで判定する(.app / .ipa)。**.ipa は unzip を同期で撃つ**(大きいと数秒) =
    /// async の呼び手は `inspectOffPool` を使う
    public static func inspect(path: String, expectedBundleID: String) -> ReinstallPackageCheck {
        judge(infoPlist: AppPackageReader.open(path: path)?.infoPlist, expectedBundleID: expectedBundleID)
    }

    /// `inspect` を協調スレッドプールの外で撃つ(同期の外部コマンドでプールを塞がない。MCP の規律と同じ)
    public static func inspectOffPool(path: String, expectedBundleID: String) async -> ReinstallPackageCheck {
        await BlockingWork.offPool(name: "fleetest-package-inspect") { inspect(path: path, expectedBundleID: expectedBundleID) }
    }

    /// パッケージ(.app / .ipa)の bundle ID。読めなければ nil。協調スレッドプールの外で読む
    public static func bundleIDOffPool(path: String) async -> String? {
        await BlockingWork.offPool(name: "fleetest-package-inspect") {
            AppPackageReader.open(path: path)?.infoPlist?["CFBundleIdentifier"] as? String
        }
    }

    /// パスのパッケージが Simulator 用ビルドか(読めなければ false)。協調スレッドプールの外で読む
    public static func isSimulatorBuildOffPool(path: String) async -> Bool {
        await BlockingWork.offPool(name: "fleetest-package-inspect") {
            AppPackageReader.open(path: path)?.infoPlist.map(isSimulatorBuild) ?? false
        }
    }
}

/// `install(packagePath:)` を撃つ前の存在確認(DSL の installApp と MCP の ft_install が共有)。
/// `~` は展開する。**相対パスの扱いは呼び手が決める**(DSL はシナリオ実行の cwd から解決してきた・MCP はスキーマが絶対パスを要求)
public enum InstallPackagePath {
    public static func expanded(_ raw: String) -> String { (raw as NSString).expandingTildeInPath }

    public static func exists(_ raw: String, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        fileExists(expanded(raw))
    }
}
