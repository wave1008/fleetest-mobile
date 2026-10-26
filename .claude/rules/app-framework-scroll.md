---
paths:
  - "Sources/FTCore/AccessibilityClassHint*.swift"
  - "Sources/FTCore/AccessibilityClassHint.swift"
  - "Sources/FTCore/AndroidPackageInspector.swift"
  - "Sources/FTCore/AppFrameworkLedger.swift"
  - "Sources/FTCore/AppUIFramework*.swift"
  - "Sources/FTCore/AppUIFrameworkQuery.swift"
  - "Sources/FTCore/BridgeDTO.swift"
  - "Sources/FTCore/ContainerGeometry.swift"
  - "Sources/FTCore/StepExecutor*.swift"
  - "Sources/FTCore/UIFrameworkMarkers*.swift"
  - "Sources/FTCore/UIFrameworkMarkers.swift"
  - "Tests/FTBridgeClientTests/AppUIFrameworkQueryWiringTests.swift"
  - "Tests/FTCoreTests/AccessibilityClassHintTests.swift"
  - "Tests/FTCoreTests/AndroidPackageInspectorTests.swift"
  - "Tests/FTCoreTests/AppUIFrameworkQueryTests.swift"
  - "Tests/FTCoreTests/ElementInfoCodingTests.swift"
---

# UI フレームワーク判定・容器推定・スクロールの端 の規律

CLAUDE.md から移した規則(本文は移設前と同一)。この領域のファイルを Read したときに自動で読み込まれる。

- **空打ち(スクロール探索の終端)を撃つかは、アプリの UI フレームワーク(`AppUIFrameworkQuery`)→
  掴んだ要素のクラス名の順で決める**(後者は `ElementInfo.axClass` =
  XCUITest ランナーが XCTest の**非公開**属性 5004 から載せる。Compose / Flutter の要素は
  `UIAccessibilityElement`、RN は `UIView`、SwiftUI は `NSObject`。`AccessibilityClassHint`)。
  どれも無ければ撃たない(打って外れると行が押される = 取り消せない側)。**木の形・型の名前から
  フレームワークを推定しない**(実アプリの 10/22 画面が Compose と同形・RN は Flutter と同形。
  docs/verification/)。③は非公開属性なので `Tests/Fixtures/AXClass/` の等号テストで Xcode の版の
  変化を検出し、取れなければ nil = 撃たない側へ縮退する
  **探索の動きが慣性を残さなかったとき(Flutter の in-app の送りだけ = `swipeLeavesNoInertia`)は撃たない** —— 空打ち自身が
  慣性を作り、流れている間 Flutter は操作を塞ぐ(FD-2.2)。送りを足す経路は `leftInertia` / `ghostLeftInertia` を立てる
  同じ理由で**整定の 2pt のしきい値(`restsWithinThreshold`)を Flutter には使わない**(這いの最中のタップは届かない = Android と同じ扱い)
- **アプリの UI フレームワークは `FTCore.AppUIFrameworkQuery` だけで決める**(語彙 `AppUIFramework` =
  iOS: compose / flutter / reactNative / swiftUI / uikit、Android: compose / flutter / reactNative / androidView)。
  順は**静的(.app / .ipa / .apk の目印 → iOS シミュレータに入っているバンドル → 台帳 `AppFrameworkLedger`)→
  動的(in-app ブリッジの自己申告)→ `.unknown`**。**iOS の目印の規則は `UIFrameworkMarkers` の1ファイルを
  ホストと in-app ブリッジが共有する**(build.sh の SWIFT_SOURCES と BridgeSourceSet に入っている =
  触ったらブリッジの版を上げる。別々に持っていた頃はホストだけ SkikoUIView を見るようになり答えが割れた)。
  Android は `AndroidPackageInspector`(ブリッジは申告しない)。守る規律5つ:
  **①不明を既定値で埋めない**(呼び手が安全側を選ぶ)/ **②パッケージは宣言した bundle ID(パッケージ名)が
  対象と一致するときだけ使う**(プロファイルのアプリとシナリオの対象アプリは別になりうる)/
  **③自己申告は `bridgeReport(_:about:)` を通し、対象アプリ自身の申告のときだけ使う**・
  台帳にもプロセス内の控えにも入れない(`AppUIFrameworkQueryWiringTests` が `StatusResponse.uiFramework` の
  直読みをソース走査で落とす)/ **④目印・順序を変えたら規則の版(`rulesVersion`)を上げる**(台帳は版の違う
  控えを使わない)/ **⑤台帳と控えは OS で分ける**(CMP は iOS の bundle ID と Android のパッケージ名が同じ)。
  **呼び手は「自前描画か」(`isSelfRendered`)で分岐する** —— 個別の値(`== .uikit` 等)で分けると語彙を
  足した日に黙って外れる(RN / SwiftUI を uikit から分けたとき、in-app の木の正規化はそれらにも掛け続ける必要があった)。
  Android の compose は「Compose を含む」であって全画面が Compose とは限らない(View/XML に混ぜた E2EAppAndroid もこちら)
- **容器推定(`ContainerGeometry.clippingContainer`)は scrollable 申告の祖先を優先する**。
  この関数はタップの座標補正・ghost 判定・MCP にも効くので、触ったら 5 SUT のフル E2E
  **+ `--ios-xcuitest`**。**フルスイートは iOS を in-app で回すので、これだけでは守れない** ——
  現にこの規則の導入(`8a416bc0`)が xcuitest 限定の退行を入れ、フル E2E 緑のまま通った
  (**5日後の `931897d6` で修正済み** —— 申告の祖先へ倒すのは「深さ由来の候補が要素を収められない」
  ときだけ。経緯と壊れ方は MN-4.5.1)
  **座標ドラッグは `StepExecutor.dragWithFallback` だけから撃つ**(in-app の drag は自前描画だけ受け、UIKit/SwiftUI は 501。
  `driver.drag` を直に呼ぶと inapp-boost モードで黙って不発になる)
- **端送りは「最後に動いてから `edgeClaimGraceAfterMove`(1.0 秒)」経つまで端と確定しない**(窓の外に描き足す
  RN の FlatList で途中止まりした)。**ドライバの `atEdge: false`(= 確かに動かした)は事実を知っている経路だけが返す**
  (in-app の contentOffset・Android の CDP)。**AX の scroll の受理は含めない** —— Compose は端でも受理し、含めた版は
  端送りが毎回 maxSwipes まで回った(緑のまま)→ MN-36
- **端を申告しない iOS の構成の上端(scrollToTop)の確かめは、送りが本物の指(XCUITest で撃った送り)だったときだけ短いドラッグ(`FTCore.EdgeProbe`。30pt・1 秒)**
  (inapp-boost モードの in-app の送り = Compose / Flutter のアクセシビリティの scroll は端で撃っても引っ張りにならず、本物のドラッグに替えると逆に更新が走った): 全力の送りの後、中身の先頭が
  動かない枠の縁へ揃った・基準(指の移動量か1本前の送り)より動かなかったら切り替える。確かめの全力の送りは上端で引っ張って更新に
  化けていた(E2EX-CMP: 上端に着いた送りでは走らず、着いた後の1本ごとに1回)。**端の確定は署名の不変のまま**(短いドラッグで動けば戻る)。
  **iOS だけ** —— 距離は pt の値で、Android の木は px(30px は Flutter のタッチの遊びに届かず、端でなくても動かない = 早すぎる端の確定)。
  Android へ広げるなら密度で換算すること。**上端だけ** —— 横のページャ・縦に吸着する一覧は短いドラッグを離すと元へ戻り(木が変わらない)、
  途中を端と確定する(誤った緑)。下端・横へ広げるならその形の証人(E2EX-CMP のページャ S0010)で両方向に測ってから。
  始点は直前の送りで中身と一緒に(軸の向きに同じ量だけ)動いた行の上(スクロールが引き取る = タップにならない)。動かない押せる要素・
  後から現れた要素・別の動き方をした要素(隠れるバーのボタン)の上には置かない(短いドラッグは要素の外へ出ないのでタップに化けうる)
