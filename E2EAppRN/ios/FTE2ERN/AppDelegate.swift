import UIKit
import React
import React_RCTAppDelegate
import ReactAppDependencyProvider

// iOS 27 SDK は UIScene ライフサイクル未採用のアプリを起動時に落とす
// (NoSceneLifecycleAdoption の EXC_BREAKPOINT)。RN 0.86 のテンプレートは
// AppDelegate 直 window なので、window の生成と startReactNative を
// SceneDelegate 側へ移してある。Info.plist の UIApplicationSceneManifest と対。
@main
class AppDelegate: UIResponder, UIApplicationDelegate {
  var reactNativeDelegate: ReactNativeDelegate?
  var reactNativeFactory: RCTReactNativeFactory?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    let delegate = ReactNativeDelegate()
    let factory = RCTReactNativeFactory(delegate: delegate)
    delegate.dependencyProvider = RCTAppDependencyProvider()

    reactNativeDelegate = delegate
    reactNativeFactory = factory
    RenderProbe.startIfRequested()

    return true
  }
}

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }
    guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }

    let window = UIWindow(windowScene: windowScene)
    // cold launch 経由のディープリンク(launchApp(url:))。UIScene 採用アプリでは
    // didFinishLaunchingWithOptions の launchOptions に URL が乗らず、ここの
    // connectionOptions.urlContexts に来る。RCTLinkingManager.getInitialURL() が読む
    // UIApplicationLaunchOptionsURLKey へ詰め替えて渡す(契約 E2EAppCMP/docs/ui-contract.md §ディープリンク)。
    var launchOptions: [AnyHashable: Any] = [:]
    if let url = connectionOptions.urlContexts.first?.url {
      launchOptions[UIApplication.LaunchOptionsKey.url] = url
    }
    appDelegate.reactNativeFactory?.startReactNative(
      withModuleName: "FTE2ERN",
      in: window,
      launchOptions: launchOptions
    )
    self.window = window
  }

  // warm 経由(openURL: プロセス起動済みへの配送)。RCTLinkingManager が NSNotification を post し、
  // JS の Linking 'url' イベントへ配送される。
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    guard let url = URLContexts.first?.url else { return }
    RCTLinkingManager.application(UIApplication.shared, open: url, options: [:])
  }
}

class ReactNativeDelegate: RCTDefaultReactNativeFactoryDelegate {
  override func sourceURL(for bridge: RCTBridge) -> URL? {
    self.bundleURL()
  }

  override func bundleURL() -> URL? {
#if DEBUG
    RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: "index")
#else
    Bundle.main.url(forResource: "main", withExtension: "jsbundle")
#endif
  }
}

// 計測用の描画プローブ(E2EAppIOS/Sources/Util/RenderProbe.swift と同じ本体。pbxproj を触らないためここに置く)
/// 計測用の描画プローブ(起動環境に FT_RENDER_PROBE=1 があるときだけ動く。`simctl launch` なら SIMCTL_CHILD_FT_RENDER_PROBE=1)。
/// 毎フレーム(CADisplayLink・.common = スクロール追従中も回る)キーウィンドウの presentation レイヤー木の署名を取り、
/// 変わったフレームの時刻を NSTemporaryDirectory()/render-probe.log へ1行ずつ追記する(`<CACurrentMediaTime> <レイヤー数>`)。
/// CACurrentMediaTime は mach_absolute_time 基準 = Simulator でもホストの CLOCK_UPTIME_RAW と同じ時計。
/// 署名に入れるもの: 位置・大きさ(スクロールビューは bounds.origin = contentOffset)・不透明度・非表示・変換・描画内容の同一性
/// (描き直すと contents のオブジェクトが替わる)。ここで見えるのはアプリがコミットした状態で、画面に出るのは次の vsync(+約 16ms)。
final class RenderProbe: NSObject {
    static let shared = RenderProbe()
    private var link: CADisplayLink?
    private var last: Int?
    private var handle: FileHandle?

    static func startIfRequested() {
        guard ProcessInfo.processInfo.environment["FT_RENDER_PROBE"] == "1" else { return }
        DispatchQueue.main.async { shared.start() }
    }

    private func start() {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("render-probe.log")
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { !$0.isHidden }
        guard !windows.isEmpty else { return }
        var hasher = Hasher()
        var count = 0
        for window in windows { visit(window.layer, &hasher, &count) }
        let signature = hasher.finalize()
        guard signature != last else { return }
        last = signature
        let line = String(format: "%.6f %d\n", CACurrentMediaTime(), count)
        handle?.write(line.data(using: .utf8)!)
    }

    private func visit(_ model: CALayer, _ hasher: inout Hasher, _ count: inout Int) {
        // スクロールインジケータは止まった後もフェードで約 1 秒変わり続ける(内容の描画ではない)ので数えない
        if let view = model.delegate as? UIView, NSStringFromClass(type(of: view)).contains("ScrollIndicator") { return }
        let layer = model.presentation() ?? model
        count += 1
        hasher.combine(layer.position.x); hasher.combine(layer.position.y)
        hasher.combine(layer.bounds.origin.x); hasher.combine(layer.bounds.origin.y)
        hasher.combine(layer.bounds.size.width); hasher.combine(layer.bounds.size.height)
        hasher.combine(layer.opacity); hasher.combine(layer.isHidden)
        let t = layer.transform
        hasher.combine(t.m11); hasher.combine(t.m22); hasher.combine(t.m41); hasher.combine(t.m42)
        if let contents = model.contents { hasher.combine(ObjectIdentifier(contents as AnyObject)) }
        for sub in model.sublayers ?? [] { visit(sub, &hasher, &count) }
    }
}
