// 「セッションのアプリは前面か」の判定を1箇所に置く(純粋関数)。
// 入力は呼び手が読んだ事実だけ(`ForegroundFacts`)。**読んでいないもの・読めなかったものは `Probe` の
// `.notAnswerable` / `.failed` で区別して渡す**(「答えない」を既定値へ畳まない)。
// 文言は持たない: 呼び手(ft_status・snapshot の注記・batch・DSL の探索)がそれぞれの語り口で組む。
// **Follower(LiveSessionFollower)は目的が別なので寄せない**: あちらは「次にどのアプリへ向けるか」を決める役で、
// 覆いを見つけたら activate を撃たない・前面アプリの探索まで含む。判定の問いが違う。

import Foundation

/// 照会の結果。`.notAnswerable` = 聞けない(その構成には口が無い・旧ブリッジ)/ `.failed` = 聞いたが失敗
public enum Probe<T: Sendable>: Sendable {
    case value(T)
    case notAnswerable
    case failed

    public var value: T? {
        if case .value(let v) = self { return v }
        return nil
    }

    /// `call` が nil を返したら notAnswerable・投げたら failed。呼び手の `try?` で畳む前に使う
    public static func of(_ call: () async throws -> T?) async -> Probe<T> {
        do {
            if let v = try await call() { return .value(v) }
            return .notAnswerable
        } catch {
            return .failed
        }
    }
}

extension Probe: Equatable where T: Equatable {}

/// アプリを覆っている面
public enum CoveringSurface: Equatable, Sendable {
    /// 通知センター(iOS のカバーシート。ロック画面も同じ窓)
    case coverSheet
    case controlCenter
    case appSwitcher
    /// Android の通知シェード・クイック設定
    case shade
    case other(String)

    /// `BridgeAPI.systemUICoveringMarkers` の目印から面を引く。
    /// **窓の目印は前方一致**: ランナーは接尾辞付き(`SBSwitcherWindow:Main`)で返す(BridgeRouter の前方一致と同じ)
    public static func from(marker: String?) -> CoveringSurface {
        switch marker {
        case let m? where m.hasPrefix("SBCoverSheetWindow"): return .coverSheet
        case let m? where m.hasPrefix("SBSwitcherWindow"): return .appSwitcher
        case let m? where m.hasPrefix("cc-"): return .controlCenter
        case let m?: return .other(m)
        case nil: return .other("unknown")
        }
    }
}

extension CoveringSurface {
    /// 面の呼び名(ft_status・snapshot の注記・DSL の探索の打ち切りが共有する。文の組み立ては呼び手ごと)
    public var displayName: String {
        switch self {
        case .coverSheet: return "the notification centre (or the lock screen)"
        case .controlCenter: return "Control Center"
        case .appSwitcher: return "the app switcher"
        case .shade: return "the notification shade or quick settings"
        case .other(let marker): return "a system surface (\(marker))"
        }
    }
}

/// 木が名乗る面(Android の `com.android.systemui` の木の中身)
public enum SystemUITreeKind: Equatable, Sendable {
    case app
    case lockScreen
    case notificationShade
    /// システム UI の木だが、シェードともロック画面とも分けられない
    case systemUIOther

    static let systemUIPackage = "com.android.systemui"

    /// 解除画面(PIN・パスワード・パターン・SIM)の本体の要素 ID(AOSP の KeyguardPINView 等)
    public static let keyguardBouncerIDMarkers = ["keyguard_pin_view", "keyguard_password_view", "keyguard_pattern_view",
                                                  "keyguard_sim_pin_view", "keyguard_sim_puk_view"]

    /// 通知シェード・クイック設定の木か(systemui の要素 ID で見る)
    public static func isNotificationShade(sessionBundleID: String?, identifiers: [String?]) -> Bool {
        guard sessionBundleID == systemUIPackage else { return false }
        return identifiers.contains { raw in
            let id = (raw ?? "").lowercased()
            return id.contains("notification_panel") || id.contains("notification_stack") || id.contains("expanded_qs")
                || id.contains("quick_settings") || id.contains("qs_panel")
        }
    }

    /// 消灯中の常時表示(AOD)・ロック画面の木か。`systemui` は通知シェードも同じ ID で名乗るので、
    /// キーガード/時計の要素 ID があるときだけ言う
    public static func isLockScreenOrAlwaysOn(sessionBundleID: String?, identifiers: [String?]) -> Bool {
        guard sessionBundleID == systemUIPackage else { return false }
        let ids = identifiers.map { ($0 ?? "").lowercased() }
        // 解除画面の本体があれば、クイック設定の要素が同じ木に居てもロック画面(実機のロック画面の木は
        // quick_settings_container を常に持つ)。横向きのシェードはこの本体を持たない
        if ids.contains(where: { id in keyguardBouncerIDMarkers.contains { id.contains($0) } }) { return true }
        // クイック設定のパネルがあれば点灯中のシェード(横向きの split shade は keyguard_message_area_container を持つ)
        if ids.contains(where: { $0.contains("expanded_qs") || $0.contains("quick_settings") || $0.contains("qs_panel") }) {
            return false
        }
        return ids.contains { id in
            id.contains("keyguard") || id.contains("animatable_clock_view") || id.contains("lockscreen")
        }
    }

    /// 木の種別。ロック画面を先に見る(上の2つの関係と同じ順)
    public static func classify(sessionBundleID: String?, identifiers: [String?]) -> SystemUITreeKind {
        if isLockScreenOrAlwaysOn(sessionBundleID: sessionBundleID, identifiers: identifiers) { return .lockScreen }
        if isNotificationShade(sessionBundleID: sessionBundleID, identifiers: identifiers) { return .notificationShade }
        return sessionBundleID == systemUIPackage ? .systemUIOther : .app
    }
}

public enum ForegroundState {
    public static let springboard = "com.apple.springboard"
    /// ロック画面の呼び名(`CoveringSurface.displayName` と同じ「the …」の形。DSL の探索の打ち切りが前面の名前の代わりに使う)
    public static let lockScreenName = "the lock screen"

    /// システムダイアログのパッケージ/バンドル ID。これらへの切り替わりは「別アプリに迷い込んだ」ではなく
    /// 「対象アプリの上にシステム UI が出ている」(権限ダイアログを放置して ft_launch し直すループが実害だった)
    public static let systemDialogPackages: Set<String> = [
        "com.google.android.permissioncontroller", "com.android.permissioncontroller",
        "com.android.packageinstaller", "com.google.android.packageinstaller",
        "com.android.systemui",
    ]

    /// 事実から前面の状態を言う。順序(上が優先):
    /// 1. セッションが SpringBoard → home
    /// 2. セッションがシステム UI のパッケージ → 木で locked / covered(.shade) / dialog
    /// 3. セッションが起動したアプリと違う → toolStopped(ツール自身が止めた)/ processGone / otherApp
    /// 4. 覆いの照会(iOS)・シェードのフォーカス(Android)→ covered。**前面アプリ名より先**
    ///    (Android のシェード下では前面アプリ名が下のアプリのまま、iOS の覆い下では /appstate が前面と答える)
    /// 5. 前面アプリ名 → inFront / dialog / otherApp
    /// 6. 前面か否かの真偽だけ → inFront / processGone / otherApp(name: nil)
    /// 7. どれも答えなければ unknown
    public static func judge(_ f: ForegroundFacts) -> ForegroundVerdict {
        if let session = f.sessionBundleID {
            if session == springboard { return .home }
            if systemDialogPackages.contains(session) {
                switch f.tree {
                case .lockScreen: return .locked
                case .notificationShade: return .covered(.shade)
                default: return .dialog(package: session)
                }
            }
            if let launched = f.launched, session != launched {
                if let by = f.stoppedByTool { return .toolStopped(by: by) }
                if f.processRunning.value == false { return .processGone }
                return .otherApp(name: session)
            }
        }
        guard let reference = f.launched ?? f.sessionBundleID else { return .unknown(.notAnswerable) }
        if case .value(let surface?) = f.covering { return .covered(surface) }
        if f.shadeHoldsInputFocus.value == true { return .covered(.shade) }
        if let front = f.front.value {
            if front == reference { return .inFront }
            if systemDialogPackages.contains(front) { return .dialog(package: front) }
            return .otherApp(name: front)
        }
        if let inFront = f.sessionInForeground.value {
            if inFront { return .inFront }
            return f.processRunning.value == false ? .processGone : .otherApp(name: nil)
        }
        let failed = [f.front.isFailed, f.sessionInForeground.isFailed, f.covering.isFailed].contains(true)
        return .unknown(failed ? .failed : .notAnswerable)
    }
}

/// ドライバへの照会を `Probe` に写す口(MCP と StepExecutor が共有。照会の組み合わせは呼び手が費用で選ぶ)
extension ForegroundState {
    public static func frontProbe(_ driver: AppDriver) async -> Probe<String> {
        await Probe.of { try await driver.foregroundAppID() }
    }

    public static func inForegroundProbe(_ driver: AppDriver, bundleID: String) async -> Probe<Bool> {
        await Probe.of { try await driver.isAppForeground(bundleID: bundleID) }
    }

    /// SpringBoard の覆い(iOS XCUITest だけが答える)。`.value(nil)` = 聞いて覆いは無かった
    public static func coveringProbe(_ driver: AppDriver) async -> Probe<CoveringSurface?> {
        do {
            guard let answer = try await driver.systemUICovering() else { return .notAnswerable }
            return .value(answer.covering ? CoveringSurface.from(marker: answer.marker) : nil)
        } catch {
            return .failed
        }
    }
}

extension Probe {
    var isFailed: Bool { if case .failed = self { return true } else { return false } }
}

/// `ForegroundState.judge` の入力。**読んでいない欄は `.notAnswerable` のまま渡す**(既定値 = 「聞いていない」)
public struct ForegroundFacts: Sendable {
    /// このセッションが ft_launch / launch したアプリ
    public var launched: String?
    /// ブリッジが答えたセッションのアプリ(木の sessionBundleID)
    public var sessionBundleID: String?
    /// 読んだ木の種別(木を読んでいなければ nil)
    public var tree: SystemUITreeKind?
    /// 前面のアプリ名(Android。iOS は答えない)
    public var front: Probe<String>
    /// セッションのアプリが前面かの真偽(`/appstate`)
    public var sessionInForeground: Probe<Bool>
    /// SpringBoard の覆いの照会(iOS XCUITest)。`.value(nil)` = 聞いて覆いは無かった
    public var covering: Probe<CoveringSurface?>
    /// 入力フォーカスを通知シェードが持っているか(Android の dumpsys)
    public var shadeHoldsInputFocus: Probe<Bool>
    /// 起動したアプリのプロセスが居るか(Android のみ答えられる)
    public var processRunning: Probe<Bool>
    /// このツール自身がアプリを止めた操作の名前
    public var stoppedByTool: String?

    public init(launched: String? = nil, sessionBundleID: String? = nil, tree: SystemUITreeKind? = nil,
                front: Probe<String> = .notAnswerable, sessionInForeground: Probe<Bool> = .notAnswerable,
                covering: Probe<CoveringSurface?> = .notAnswerable,
                shadeHoldsInputFocus: Probe<Bool> = .notAnswerable,
                processRunning: Probe<Bool> = .notAnswerable, stoppedByTool: String? = nil) {
        self.launched = launched
        self.sessionBundleID = sessionBundleID
        self.tree = tree
        self.front = front
        self.sessionInForeground = sessionInForeground
        self.covering = covering
        self.shadeHoldsInputFocus = shadeHoldsInputFocus
        self.processRunning = processRunning
        self.stoppedByTool = stoppedByTool
    }
}

public enum ForegroundUnknownReason: Equatable, Sendable {
    /// 聞ける口が無い・何も聞いていない
    case notAnswerable
    /// 聞いたが失敗した
    case failed
}

public enum ForegroundVerdict: Equatable, Sendable {
    case inFront
    case covered(CoveringSurface)
    case locked
    case dialog(package: String)
    /// 別のアプリが前面(name が nil = 前面ではないと分かるだけで名前は言えない。iOS)
    case otherApp(name: String?)
    case processGone
    case toolStopped(by: String)
    case home
    case unknown(ForegroundUnknownReason)
}
