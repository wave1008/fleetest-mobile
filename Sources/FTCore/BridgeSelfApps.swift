// fleetest 自身のブリッジ(Android の ftbridge instrumentation・iOS の XCUITest ランナー)のパッケージ / bundle ID か。
// **起動・終了・データ消去の対象にしてはいけない**: Android は `am force-stop <pkg>` / `pm clear` が自分(ブリッジ)を殺し、
// iOS は XCUIApplication でランナー自身を起動して自滅する。ホスト側(MCP・DSL)が撃つ前に断る。ft_list_apps の一覧からも外す。
// 同期相手: Android = AndroidDriver.bridgePackage(FTAndroid。FTCore から参照できないので写し)・
// iOS = Runner のプロジェクトの `<prefix>.ftrunner` / `.ftrunner.uitests`(+ XCTest が付ける `.xctrunner`)。

import Foundation

public enum BridgeSelfApps {
    public static let androidBridgePackage = "com.example.ftbridge"

    public static func isBridgeItself(_ id: String) -> Bool {
        if id == androidBridgePackage || id.hasPrefix(androidBridgePackage + ".") { return true }
        // **fleetest のランナーの ID だけ**(末尾 `.xctrunner` を一律に当てると、利用者自身の UI テストのランナーまで巻き込む)。
        // XCTest が `.xctrunner` を付けるのは UI テストのターゲット(`.ftrunner.uitests`)だけ
        return runnerSuffixes.contains { id.hasSuffix($0) }
    }

    static let runnerSuffixes = [".ftrunner", ".ftrunner.uitests", ".ftrunner.uitests.xctrunner"]
}
