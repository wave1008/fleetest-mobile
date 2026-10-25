# 設計: アプリ操作ブリッジ

| 種別 | 範囲 | 読む場面 | 扱わないこと |
|---|---|---|---|
| 正典 | iOS / Android のブリッジ(常駐・エンドポイント・スナップショットの圧縮・座標系・整定)と Emulator の gRPC 制御(DS-4・16) | ブリッジの挙動・エンドポイントを変える前 | WebView / ブラウザの中身(→ [webview.md](webview.md)) |

ブリッジのエンドポイント表は `BridgeDocRouteSyncTests` が実態と照合する。

## DS-4 アプリ操作ブリッジ(自作)設計

WebDriverAgent と同じ原理を最小構成で自作する(iOS)。Android にも同じプロトコルで
話す常駐ブリッジを実装しており(DS-4.5)、`AppDriver` の実装が両OSで揃っている。

### DS-4.1 常駐のしくみ

- `FleetestRunnerUITests` に終わらないテスト `testRunBridgeServer()` を 1 本だけ置く。
  テスト内で HTTP サーバを起動し、`RunLoop.current.run()` で常駐。
- 起動手順(CLI が内部で実行):
  1. `xcodebuild build-for-testing -project Runner/FleetestRunner.xcodeproj
     -scheme FleetestRunner -destination 'platform=iOS Simulator,name=iPhone 17'`
  2. `xcodebuild test-without-building -xctestrun <derived>.xctestrun ...`
     (環境変数 `FT_PORT=8123` をテスト環境に渡す)
- シミュレータはホストとネットワークスタックを共有するため、テスト内で
  `127.0.0.1:8123` に listen すればホストの `localhost:8123` から直接届く。
  ポート番号は CLI が空きポートを選んで環境変数で注入する。
- **無通信 TTL(2026-07-30)**: 最終リクエストから `FT_BRIDGE_TTL` 秒(既定 7200・`0` で無効)
  無通信のブリッジは自主終了する(iOS/Android 共通。忘れられたゾンビのデバイス占有防止)。
  心拍は**全リクエスト**(/status 含む)なので、モニターのポーリングが続く限り失効しない。
  既定値の定義は `BridgeAPI.bridgeTTLSecondsDefault`(Java 側と `AndroidBridgeVersionSyncTests`
  が同期を検出)。in-app ブリッジは対象外(対象アプリと運命を共にする。ゾンビ対策は
  provision の reclaim 側)。自主終了はホスト側の pid ファイルを消せないため、provision が
  採番前に死んだランナーの pid ファイルを回収する(`BridgeLauncher.sweepStalePidFiles`。
  残すと `assignPort` が使用中とみなし採番がドリフトする)。
- **実機の自動ロックは端末側で切る(2026-09-05 ユーザー決定)**。実機は run の待ちの最中に
  自動ロックされ、以後の launch が `denied by SBMainWorkspace ... reason: Locked` で拒否されて
  run ごと死ぬ。**ツールは起こさない** —— **設定 → 画面表示と明るさ → 自動ロック → なし**に
  しておくのが実機を使う前提。
  **かつてはランナーが 25 秒ごとに `press(.home)` を撃っていた(版 81〜88)が、廃止した**:
  合成した入力は実機では本物の HID で、無害だという前提が OS の版で反転する
  (iOS 26.5.2 では SpringBoard に届かず、26.6 では届いて**対象アプリが run の途中で
  ホーム画面へ落ちた**)。端末の画面設定は端末の持ち主が決めるものなので、ツールが
  入力を合成して覆すのをやめた。
  ホストから自動ロック設定を書き換える手段は無い(`devicectl device settings` は
  appearance/audio/biometrics/voiceover だけ)ので、**設定するのは人**。
  ロックされたまま起動しようとした場合は `IOSPhysicalDeviceLock` と
  `IOSDeviceTransport.blockingCondition` が名指しで止める。
  処理中(`inFlight > 0`)は撃たない(accept スレッドと XCUITest を同時に叩かないため)
- **容器推定は scrollable 申告の祖先を優先する(2026-08-23)**: `ContainerGeometry.clippingContainer` は
  「同じ深さの子を2つ以上持つ直近の祖先」を容器とみなす規則(Compose iOS は xcuitest で scrollable を
  申告できないための近似)だが、申告のある木ではそれが**カード**を容器に選ぶ(カルーセル > カード >
  ラベル+バッジ)。クリップするのはカードではなくスクロール容器なので、祖先の連鎖に
  `scrollable == true` があれば最も近いそれを正とする(`nearestScrollableAncestor`)。申告の無い木は
  従来どおり。見切れ判定・回復ドラッグ・タップの座標補正・ghost 判定・MCP の RefGuard が同じ関数を
  使うので、変えるときは 5 SUT のフル E2E で退行を見る(受け手の最小再現: 横カルーセルの右縁で
  見切れた項目への `exist(scroll: .right)` がカードを viewport にして送れず not-found になっていた)。
  **同じ最小再現で見つかった第2の穴**: 見切れ回復の `slowDrag` とヒント跳躍の `hintDrag` が
  `driver.drag` を直に呼んでいて、in-app ブリッジは drag を実装しない(501)ので失敗扱い → 全画面
  スワイプに落ちていた = **利用者の既定の inapp モードでは見切れ回復のドラッグが一度も出ていなかった**
  (当時の MCP は inapp モードで `HybridFallbackDriver` が drag を転送していたので `ft_scroll_to` は同じ画面で通った。
  run と MCP で結果が割れたらドライバ合成の差を疑う)。座標ドラッグは
  `StepExecutor.dragWithFallback` が唯一の入口(501 → typeDriver へ latch。空打ち emptyDrag と同じ規律)
- **起動前にポートの LISTEN 実体を確かめる(2026-08-23)**: `scanRunningBridges` は /status 応答で
  稼働中を数えるが、in-app ブリッジは注入先アプリが背面だと TCP は受け付けて HTTP に答えない
  = ポートを掴んだまま「空き」に見える(全シミュレータはホストの loopback を共有するので
  ポートはデバイスを跨いで一意)。`executeBridge` は記録の有無に関わらず `PortHolder.stopIfOwnedBridge`
  で占有者を確かめ、自分たちの資産(シミュレータ内アプリ・残骸ランナー・iproxy)なら止め、
  無関係なら in-app は撃たずに `portInUse` で名指しして落とす。旧ブリッジの停止手段は
  `StaleBridgeStop.decide`(.inapp 記録 → simctl terminate / .pid → ランナー停止 / 記録無し →
  PortHolder)。`.inapp` の記録は ready 待ちの**前**に書く(中断で記録の無い残骸を作らない)。
  切り分けは docs/verification/triage.md「never joined」の節
- **登録の無いシステムアラートも黙らない(2026-08-23)**: `SystemUIGate` の毎ステップ判定は
  `iosAlertHandler` の登録がある間だけ(費用を登録した人だけが払う。0ec9b245)。登録漏れは
  人為ミスとして起こり続けるので、**launch 系の直後の最初の触る操作**と**ステップの失敗時**に
  限って1回 `GET /systemalert` を聞き、前面にあれば注記 `system-alert-present` と文言(題名・
  ボタン)を残す。止めない・閉じない(新しい検知は警告から。閉じるのはシナリオの責務)。
  失敗文言に題名が出るので、時間切れの仕分けが「アラートだった」で即決まる。**MCP も同じ形**
  (2026-08-31): `ft_launch` / `ft_open_url` / `ft_install` / `ft_clear_app_data` の直後の**最初の
  `ft_snapshot` で1回**(出ていたら閉じるまで木を返す応答ごとに確かめ続ける)、**ref の操作(ft_tap / ft_type / ft_clear_input / ft_long_press / ft_batch の1手目)
  では毎回聞き、前面にあれば断る**。**アラートが前面にある間はアプリの木を出さない**(ユーザー決定 2026-10-11。
  背面の木は押せない要素の一覧で、読み手はそこから次の手を探す。木から決まる注記も出さない)。**アプリ内の alert**
  (木の中の `alert`。描かれているものだけ = 枠が0・画面外は閉じた後の残り)は、その部分木だけを返す。判定は
  `FTCore.AlertTreeScope` の1箇所で、MCP の木を返す口(`snapshotBody` と `ft_scroll_to`)と DSL の失敗レポートの
  要素一覧(`FTRuntime.handleFailure` = システムアラートの下では一覧ごと伏せ、レポートが伏せた理由を1行言う)が共有する(題名・ボタンを名指しして SpringBoard へ attach する手順を出す。
  SpringBoard に attach 中は断らない)。**MCP だけ警告でなく拒否**なのは、どちらのブリッジでも操作が
  届くため —— in-app はアラートを残したまま背面のアプリが反応し、XCUITest は XCTest の割り込み処理が
  アラートのボタンを押して権限を黙って変えていた(拒否側とは限らず「許可」も押し、遮られた操作を撃ち直した。2026-10-03 にランナーへ `InterruptionGuard` を置いて既定のハンドラを止めた = **遮られた操作は 422 で返り、アラートは押されない**。MCP の事前拒否は、7 秒待たずに題名とボタンを名指しする口として残す)。座標の操作は断らない(XCUITest では
  アラートそのものに当たる)。判定は `SystemUIGate` の1箇所
- **失敗時の証跡の絵は画面全体を撮る(2026-09-20)**: in-app の `/screenshot` はアプリ自身の window を
  描き直すだけで、SpringBoard のアラートは写らない。inapp モードは `fallbackDriver`(XCUITest =
  `XCUIScreen`)で撮り、撮れなければ主ドライバへ落ちる(`FTRuntime.handleFailure`。白フレームの
  撮り直しも同じ撮り方)。DSL の `screenshot` も同じ撮り方(2026-10-20)。
- **画像判定の絵は覆いがあると分かっているときだけ画面全体を撮る(2026-10-20)**: テキストの可視性検証・
  findImage / existImage / imageIs・分類器(checkIsON / checkIsOFF)は、inapp モードでは in-app の絵を使い、**判定に使った木がキーボードを
  申告しているとき**と**そのフェーズの照会(`GET /systemalert`。フェーズごとに1回・触る操作の照会の答えも使う)で
  アラートが前面にあったとき**だけ `fallbackDriver` で撮る(`FTCore.JudgmentCapture` /
  `StepExecutor.judgmentScreenshot`)。screenLooksLike / screenIs の FM は1回で数秒かかるので常に画面全体。
  毎回 XCUITest で撮らないのは、可視性検証が既定で有効で、検証のたびに数百 ms(in-app 約 45〜125ms)増えるため。
  画面全体の絵には in-app の絵の追いつき待ち(`InAppRenderCatchUp`)が効かないが、xcuitest モードと同じ条件で、
  可視性検証は見えないと判定した回に撮り直して待つ。見逃すもの: 通知バナー等の他の覆い・フェーズの途中で出たアラート
- **起動元の自己申告と doctor の刈り取り(2026-07-30)**: 3ブリッジとも `/status` で起動元
  (`ownerRepo`。iOS xcuitest はホスト上で停止できる `ownerPid` も)と直前の無通信秒数
  (`idleSeconds`)を申告する(注入経路: xctestrun 環境変数 / `-e owner` / SIMCTL_CHILD)。
  doctor は管理外ブリッジの処遇を `UnmanagedBridgeTriage`(唯一の判定者)で決める:
  **自動停止は「自リポジトリの旧版」「起動元リポジトリが消滅した確定ゾンビ」の2行だけ**。
  実在する別ワークスペースの所有物と起動元不明(旧ブリッジ)は報告のみ(他人の資産を殺さない)。

### DS-4.2 HTTP サーバ実装

- 依存最小方針に合わせ、**BSD ソケット直書きの極小 HTTP/1.1 サーバ**(~200 行)を
  テストバンドル内に実装する(GET/POST、Content-Length ボディ、JSON のみ)。
  実装が難航した場合の代替は FlyingFox(pure Swift、テストバンドル内動作実績あり)。

### DS-4.3 エンドポイント

| Method/Path | 動作 |
|---|---|
| `GET  /status` | ランナー生存確認・シミュレータ情報。inapp は `applicationState`(active/inactive/background)も返す(背面 suspend 診断用・追加 optional・旧ブリッジは返さず nil) |
| `POST /session` | `{bundleID}` → `XCUIApplication(bundleIdentifier:).launch()` |
| `GET  /snapshot` | アクセシビリティツリーを圧縮 JSON で返す(4.4) |
| `POST /tap` | `{ref}` または `{x,y}`。ref を撃つ要求(`/tap` `/press` `/type` `/clear`)は任意で `expect: {identifier?, type}` を添えられる(下の `stale-ref`)。**測定用の `probeStaleRef: true`**(v211〜・XCUITest ランナーだけが見る・ホストは `FT_STALE_TAP_PROBE=1` のときだけ送る)を添えると、撃つ直前に木を1回撮り直し(撃つのがその分 約 20〜120ms 遅れる)、ref の要素がもう控えた枠に居なければ応答の `hitAreaMiss.kind` に `movedBeforeFire` を載せる。**断らずに撃つ** |
| `POST /type` | `{ref, text}`(tap → typeText)。ref 経路は打つ前のタップの直前に木を1回撮り直し(`app.snapshot()`・ライブクエリなし)、ref の要素が同じ枠に居なければ撃たずに断る |
| `POST /swipe` | `{direction}` or `{fromRef, direction}`。用途つきの任意項目あり(下記「スクロールの語彙」) |
| `POST /press` | `{ref, duration}` または `{x, y, duration}` 長押し |
| `POST /hold` | `{x, y, duration}` 指を置いたら応答を返し、`duration` 秒後にブリッジが自分で離す(DSL の `hold { }`)。`/press` は離すまで応答せず、その間は木もスクショも返せない。XCUITest は `CoordinatePinch` と同じ非公開 API(無い Xcode では 422)、Android は離す側を別スレッドで注入(前の指が下りたままなら 409)。**in-app ブリッジは持たない**(inapp モードは XCUITest ブリッジへ回す) |
| `POST /doubletap` | `{ref}` または `{x,y}`。**2回の /tap では代用できない**(往復で OS のダブルタップ判定時間を超える)。XCUITest ランナーは非公開 API(`CoordinatePinch` と同じ経路)で2回の独立したタッチ(0.08秒ずつ・2回目は0.25秒後)を送る(XCTest の `doubleTap()` = 1回のタッチに tapCount=2 は RN が単タップと読む)。非公開 API が無い Xcode では XCTest の `doubleTap()` へフォールバック |
| `POST /pinch` | `{scale, frame?, identifier?, durationSeconds?, fingers?}` 2本指ズーム。**指の座標はホスト側 `FTCore.PinchGesture` が OS ごとの規則(iOS/Android で別)で1箇所に決め、`fingers` として送る**。**全ブリッジがそのまま再生**(XCUITest は非公開 API = `CoordinatePinch`)。**`fingers` が無い・座標ピンチが使えないときだけ** XCUITest が `identifier` で要素を引く(**縮退したことを注記で必ず言う**) |
| `POST /gesture` | `{fingers: [{points: [{x, y, t}]}]}` 指ごとの時刻つき経路を**1回のタッチ列として**再生する(DSL の `gesture` / MCP の `ft_gesture`)。各指は最初の点で押し最後の点で離す・同じ点が続く区間は静止。XCUITest は `CoordinatePinch` と同じ非公開 API、Android は多点 `MotionEvent`。**in-app ブリッジは持たない**(inapp モードは既定の 501 で XCUITest ブリッジへ回す)。非公開 API が無い Xcode では 422(501 は自分へ戻るので使わない)。本数・点数・秒数はホストの `TouchGesture.validate` が断り、両ブリッジも同じ上限で最後に断る |
| `POST /clear` | `{ref}` 省略可(省略時はフォーカス中の入力欄)。入力欄のクリア |
| `POST /pressEnter` | Return キー相当(受け口ごとの機構は DS-10) |
| `GET  /screenshot` | `XCUIScreen.main.screenshot()` → PNG |
| `POST /terminate` | 対象アプリ終了 |

上記13個は3実装共通のコア。差分は次のとおり(**唯一の正は
`Tests/FTCoreTests/BridgeContractTests.swift` のルート表**。ここはその写し):

| ブリッジ | 共通コアへの追加 | 計 |
|---|---|---|
| XCUITest(Runner/) | `POST /drag`・`POST /gesture`・`POST /hold`・`POST /appswitcher`・`POST /home`・`POST /hinge`(折りたたみの Duo の Simulator のヒンジ角。仮想 HID・`FTCore.FoldControl`)・共通コアの /screenshot のクエリ `display=<id>`(追加のルートではない。内蔵画面が2枚以上 = `/status` の `multiDisplay` のとき必須。ホストが devicectl で確かめた表示中の画面を渡す。`DisplayRouting`)・`POST /hidekeyboard`・`POST /appstate`・`POST /rotate`・`GET /hittable`・`GET /systemalert`・`GET /systemui/covering`・`GET /systemui/snapshot`・`POST /systemui/tap`・`POST /systemui/drag`・`POST /systemui/swipe`・`POST /waitForSettle`(DS-4.7)・`POST /responsePrepare`・`POST /responseCollect`・`POST /responseObservation`・`POST /responseObservationStop`(応答時間計測。RM-5・RM-7) | 34 |
| Android(AndroidRunner/) | `POST /gesture`・`POST /hold`・`POST /locale`・`POST /settle`・`POST /scrollAction`(DS-4.5)・`POST /waitForSettle`(DS-4.7)・`POST /responsePrepare`・`POST /responseCollect`・`POST /responseObservation`・`POST /responseObservationStop`(応答時間計測。RM-8.5) | 23 |
| InApp | `POST /hidekeyboard`・`POST /appstate`・`POST /rotate`(iPad では 501 = inapp モードは XCUITest ブリッジへ)・`POST /tapprobe`(iOS の hideKeyboard が叩く点がキーボード・ステータスバー・別のウィンドウの上でないか。`InAppTapProbe.swift`)・`POST /drag`(自前描画の Compose・Flutter だけ。実時間 60Hz で move を処理させ、終点の後に1刻み待って離す。それ以外は 501 = inapp モードは XCUITest ブリッジへ) | 18 |

**ジェスチャの秒数(`/press` の duration・`/drag` の press+移動・速度つき `/swipe`・`/pinch`・`/gesture` の全体)の上限は2層**:
方針(既定 10 秒・コマンドの `maxGestureSeconds` で最大 60 秒)は**ホスト側**(`FlowStep.gestureDurationViolation` /
`ArgumentBounds.gestureCapViolation`)がデバイスに触る前に断り、**ブリッジは絶対上限 60 秒
(`BridgeAPI.gestureSecondsCeiling`)だけ**を持つ —— XCUITest は見積もり所要が超えたら合成前に 400、
Android は 60 秒に丸める。in-app の `/drag`・`/pinch` も超えたら 400(アプリのプロセスに載るので、桁外れの秒数で
刻みの数を作ると整数化でアプリごと落ちる)。ブリッジに方針を持たせないのは、要求ごとの上限を運ぶ欄を作らずに済むため。
XCUITest で絶対上限を外せない理由は MN-49.1(桁外れの秒数で `testmanagerd` が合成列を
作り続けて数百 GB に膨らむ)。

`/hidekeyboard` は iOS の2実装だけが持つが、**中身は 501 を返すだけ**(`hideKeyboard` の iOS 経路はホスト側が
木から決めてタップするのでこのルートを使わない。DS-10「キーボードの観測と `hideKeyboard`」)。Android は `hideKeyboard` を
ホスト側の戻るキーで実現するのでルートを持たない。

InApp の `GET /screenshot` は `drawHierarchy(afterScreenUpdates: false)` で可視の窓を奥から重ねて描くが、
**自前描画のアプリ(`uiFramework` の `isSelfRendered` = Compose / Flutter)では、a11y の木が絵より先に進む**
—— CMP の起動後の初回訪問で、タップが返ってから 0.27〜0.45 秒のあいだ切り替え前の絵がバイト同一で返った
(2026-09-19 実測。2回目の訪問・SwiftUI では起きない。**XCUITest ブリッジでも起きるが直していない** = FD-3)。その絵で findImage / imageIs /
分類器 / occlusion-guard が判定すると、木の枠で別の画面の画素を切る。v117 の `InAppRenderCatchUp`
(`InAppSettle.swift`)が守る規律は3つ: **①操作の直前に 0.25 倍の画素の指紋と木(frames)の指紋を控える**
(`captureRenderBefore`。操作を起こす経路は `tapByRef` と `performSettlingIfMoved` の2つで、両方が通す。
約 12ms)/ **②`/screenshot` は、木が変わったのに画素が控えと同じ間だけ待つ**(上限 1.0 秒 = 実測の遅れの
2倍強。ホストが操作後に木を読んでいなければブリッジが自分で1回読んで比べる(2ms)。frames/nodes の対応表は
書き換えない)/ **③遷移の完了・アニメーションの静止は待たない**(ユーザー決定。ループする絵で毎回上限まで
待つ形を作らない。画素が1度でも変われば撮る)。**門は層の型ではなくフレームワークの自己申告** ——
Compose の `CMPMetalLayer` は `CAMetalLayer` の子孫ではなく素の `CALayer` の子クラスで、`nextDrawable` の
差し替えも1件も記録できなかった。

`/systemui/*` は XCUITest ランナーだけが持つ、SpringBoard(別プロセス)を読む・叩く口。
**`POST /session springboard` + `GET /snapshot` との違いはセッションを触らないこと**だけで、
返る木は同じ。ref は専用の名前空間(ランナーの `systemRefFrames`)に振り、
`app` / `sessionBundleID` / `refFrames` のどれにも書かない。

`POST /systemui/drag` / `POST /systemui/swipe` は**座標の原点を SpringBoard に取る**ジェスチャ
(`POST /appswitcher` / `POST /home` と同じ理由)。呼び手の `tapAppIcon` は直前に `home()` を
撃っているので、セッションのアプリを原点にする `/drag`・`/swipe` では、**背面なら**座標解決が
`Find the Application` を約45秒リトライして**ランナーごと落ち**、**未起動なら** `requireLiveApp`
の 503 で弾かれる。逆に `/tap` 側を SpringBoard へ寄せてはいけない —— あちらの 503 は
「アプリが死んでいる」の申告で、ホストが復帰の判定に使っている。

ref を引く表が2つあるので、**呼び手は直前に撮った木と同じ名前空間の口だけを叩く**。
また表は**撮るたびに作り直される**ので、撮り直した後に撃つ ref はその木から引き直す(撮る前の番号は別の要素を指しうる。
規律は `.claude/rules/executor.md`)。
`SystemUIDriver` は scoped で撮った回の ref を `/systemui/tap` へ回し、座標へ落とせない
操作(`type` / `clearInput` —— ランナーが要素そのものを引いて読み返す)は 422 で断る。
素通しすると**両方の名前空間が 1 から採番される**ため、番号がアプリ側の `refFrames` で
引き当たり、システム UI を操作したつもりで無関係なアプリの要素へ届く。

**なぜ要るか**(2026-08-25): xcuitest モードは**ブリッジが1本しかなく、主ドライバと
共有している**。旧経路はセッションを springboard へ移し ref 表を空にするので、権限アラートを
閉じた次のステップが SpringBoard の木を読んで `cannot resolve the locator` で落ちた
(E2E-iOS の `16_システムアラート.swift` で実測)。inapp モードはフォールバックが別ブリッジなので
巻き添えが無く、旧経路のままでも正しく動いていた —— **同じホストのコードが、モードによって
壊れたり壊れなかったりしていた**。ホスト側で「見た後に張り直す」ことでも塞げるが、
戻し忘れが**次のステップで**沈黙して失敗する形になるため、ブリッジ側に不変条件を置いた。

**アラートの有無で撮る/撮らないを分けない**: この口はホーム画面の走査(`tapAppIcon`)にも使う。
SpringBoard は system shell なので背面に回らず、`requireForegroundApp` が防いでいる
「背面アプリの木を読むとランナーごと落ちる」形には当たらない。

旧ランナー(版 < 79)は 404 を返し、`SystemUIDriver` が旧経路へ落ちる。

`POST /rotate` は iOS の2実装だけが持つ(`{orientation}` → 整定後の実際の向き、整定しなければ
`422`)。**in-app ブリッジは iPad では撃たずに `501`**(アプリから自分の画面を回せない = `requestGeometryUpdate` が
効かず portrait のまま。iPad の Simulator 2機種・iOS 27.2 で実測)。iPhone 専用アプリの iPad 互換表示は idiom が phone なので
in-app のまま回し、実際に回る(同じ2機種で実測)。in-app が 501 で断った回は元の向きの控えを捨てる(`BridgeClient.keepsOriginalOrientation`。
残すと終端の戻しが in-app へ撃って同じ 501 を出す)。inapp モードはこの 501 だけで XCUITest ブリッジへ回し
(`StepExecutor.executeDirectRotateTo`・ライブ操作は `HybridFallbackDriver`)、422 は回さない。Android は adb(`AndroidDriver`)で直接行うためルートを持たない。XCUITest ランナーは判定に
アプリの窓を読むので、**セッションのアプリが落ちていれば 503・背面なら 422 で撃たずに断る**
(`requireForegroundAppForRotation`。読むと XCTest が Tear Down してランナーごと消える。v118)。

**回転の契約は「アプリの UI がその向きになること」**(2026-08-10 ユーザー決定)。デバイスがどう
傾いているかではない —— テストが観測できる frame と画面サイズは、iOS も Android も、
Compose / SwiftUI / View-XML / Flutter / React Native のどれでも**アプリ座標系**で返る
(PoC で全部実測)。跨いで同じ意味を持つのはここまでなので、**語彙は portrait / landscape の2値**に
限る。`landscapeLeft` / `landscapeRight` は**置かない** —— 物理的な左右はテストから観測できず、
どう定義しても検証できない。実際、置いていた間は **iOS が厳密に一致を求める一方 Android は
「窓が横長か」しか見ておらず、同じ `.landscapeRight` の要求が Android では左横向きでも成功していた**。
検証できない区別を語彙に置かない。
実装上の帰結: 各ブリッジは**要求をどちらか一方の landscape へ写し、読みでは左右をまとめる**
(片側しか landscape と認めないと、OS がもう一方を選んだ回に整定が永久に一致せず 422 になる)。
Android の整定判定は**スナップショットの画面サイズ**で行う = 表示だけ回ってアプリが縦のままの形を
成功にしない。

**エラーの status はホスト側の分岐に使われる契約**(ブリッジ実装とホストで同期が必要。
`DriverError.isBridgeIncapable` / `AppAttachDriver` / `SessionRecoveryDriver`):

| status | 意味 | ホストの反応 |
|---|---|---|
| `501` / `404`(本文 `not found:`) | このブリッジでは**原理的に不可** | XCUITest へフォールバック(DS-10 の「in-app で不可・XCUITest で可」) |
| `404`(ref 不明) | スナップショット取り直しが要る本物の失敗 | 失敗(フォールバックしない。本文前置で 501 系と区別) |
| `409` | 一時的競合(キーウィンドウ不在・セッション消失) | セッション消失だけ `SessionRecoveryDriver` が張り直す。**フォールバック判定に使わない** |
| `422` + `reason: "stale-ref"`(XCUITest ランナー。`ErrorResponse.reason`) | ref が指していた要素が、撃つ時点でもう同じ場所に居ない(`/type` `/clear` は撃つ直前の撮り直しで、全 ref 操作はホストの `expect` との identifier・型の矛盾で)。**何も撃っていない**ことの保証 | `DriverError.staleRef` に写し、`StepExecutor.executeActionRetryingStaleRef` が木を撮り直して引き直し、`waitSeconds` の予算内で撃ち直す。**この断りだけが撃ち直してよい**(他の 422 は届いたかもしれない)。in-app・Android は未対応 |
| `422` | セッションはあるが**今のこの画面では実行できない**(フォーカス欄が無い・**入力欄でない ref を叩いても焦点が前の欄に残った**(XCUITest の type / clear)・クリアしきれない・type の読み返しが期待値に届かない・**中身のあるマスク欄への追記**・in-app の**座標タップの点が画面外**(ソフトキーボードの上は 501 = inapp モードでは XCUITest ブリッジが撃つ。ブリッジ v197)・**セッションのアプリが背面のままの type / clear / pressEnter**(焦点のライブクエリがランナーを落とすので撃つ前に断る)・**同じく背面のままの tap / swipe / drag / doubleTap / pinch / press**(座標は Find the Application、ref は要素のライブクエリが刺さる。v101)・**home を 3 回送っても前面が外れない**) | 失敗。`clearInput` だけ 409 と同様に typeDriver へ回す(`isClearInputFallback`) |
| `422`(Android。本文 `no-active-window-root:`) | `/snapshot` の再試行(WAKEUP 注入込み)後もアクティブウィンドウの a11y 根が読めない一時ストール(実測 Pixel 3a/Android 12: 13〜37 秒。app switcher・画面消灯・ウィンドウ遷移の最中に起きる) | 失敗(自然回復を待つ)。`DriverError.isNoReadableWindow` が判定・MCP は撃ち直しても同じ答えになることと前面復帰の手を案内する |
| `503` | iOS: セッションはあるが**対象アプリが起動していない**(XCUITest の `requireLiveApp`)。**Android: UiAutomation の接続が死んだ = ブリッジが自分で exit する** | iOS は `AppAttachDriver` が activate して1回再試行(包まれていない xcuitest 経路では素の失敗)。Android は status で分岐しない(ブリッジの起動し直しは供給と監視が拾う) |
| `504` | in-app: **main で実行されないまま締切を過ぎた**。XCUITest: **ハンドラが固まった = ランナーが自分で終わる** | status で分岐しない(失敗として返す。XCUITest は以後の接続断を供給・監視が拾う) |
| `500`(XCUITest の attach。本文 `the app to attach to is not in the foreground:`) | 起動済みのアプリへの接続で前面に届かなかった | `FastLaunchDriver` が注記 `activatedBeforeForeground` を立てて activate へ進む。**他の 500(XCUITest の例外)はこの目印を持たないので注記を立てない** |
| Android の `409` / `500` | 409 = 消せなかった・前の hold の指が下りたまま。500 = type が断られた(同じ事情を in-app は 409、XCUITest は 422 で返す) | status で分岐しない(失敗として返す)。**iOS の 409 と同じ意味ではない** —— `SessionRecoveryDriver` は iOS の XCUITest にしか掛からない |

**XCUITest ランナーは 409 を `requireApp()` の1箇所からしか投げてはいけない**(`SessionRecoveryDriver`
がこの経路の 409 を無条件に「セッション消失」と読み、activate を撃つため)。同じ「今は無理」を
表したいときは 422 を使う。in-app ブリッジは逆に 409 を一時的競合へ広く使ってよい
(あちらは `SessionRecoveryDriver` で包まれない)。2026-07-31 に `handleClear` が 409 を足して
この不変条件が破れ、clearInput の正当な失敗が「ランナーが再起動した可能性」と誤報告された
(実害)。以後 `BridgeRouterStatusContractTests` が 409/503/501 の本数を数えて守る

**in-app dylib は「古いまま注入される」事故が起きやすい**(2026-07-27 に実害):
`InAppBridge/build/` は gitignore・手動ビルドなので、ブリッジのソースを直しても
再ビルドしなければ**古いバイナリが注入され続ける**。実際に isChecked 追加と型の役割正規化
(b8a408c)が反映されず、ios-inapp / ios-heal だけ「checked が取れない」「switch 型が出ない」で
落ち続けた。`InAppLauncher.buildIfNeeded` は**存在ではなく鮮度**(`InAppBridge/Sources/*` +
`build.sh` + 共有 DTO の mtime)で判定する — 存在チェックに戻してはいけない。

### DS-4.4 スナップショットの圧縮(4K コンテキストへの最重要対策)

`XCUIApplication.snapshot()`(`XCUIElementSnapshot`)を再帰走査して:

1. **フィルタ**: 非表示・サイズ 0・画面外・`Other`/`Group` で情報を持たない中間ノードを除去
2. **属性の絞り込み**: type / identifier / label / value / frame / hittable のみ
3. **要素参照番号(set-of-mark)** を振り、FM には 1 行 1 要素のテキストで渡す:

```
[3]  Button   "ログイン"        id=login_btn  (120,610 180x44)
[4]  TextField "メールアドレス"  id=email      (24,320 342x44) value=""
[7]  StaticText "パスワードが違います"          (24,380 342x20)
```

- 操作 API(tap 等)は `ref` 番号で受け、ランナー側が直近 snapshot の
  ref→要素クエリ対応表を保持して解決する。
- 目標: 一般的な画面で **300〜800 トークン**。上限は `BridgeAPI.maxSnapshotElements`(120)で、
  超過分は `(+12 elements truncated)` と件数だけ出す。**打ち切りは描画の省略ではなく
  配列そのものからの脱落**なので、`waitFor` も `scrollTo` も打ち切り後しか見ない
  (だから MCP の失敗文は打ち切りを名指しする。`MCPServer.truncationHint`)。
- **呼び手が1回だけ上限を引き上げられる**(版 65。`GET /snapshot?max=<n>` / MCP は
  `ft_snapshot maxElements:`。天井 `BridgeAPI.maxSnapshotElementsCeiling`=400、
  解釈は `resolvedSnapshotElementLimit` の1箇所 = ホスト・3ブリッジで同じ規則)。
  **一発限り**にするのは、上げたままだと以後の整定ループ・探索の各周回まで重い木を引くため
  (`AppDriver.raiseElementLimitOnNextSnapshot`。**ラッパードライバは転送必須**)。
  なぜ要るか(2026-08-12・ブラウザ監査の実測): web ページは広告リンクだけで tier0 が枠を埋め、
  間引きは tier1(ラベル付きの本文)から捨てるので、**画面に写っている表の行が丸ごと消える**。
  tenki.jp の2週間天気では 248 候補中 128 件が脱落し、**その全部が labelled** ——
  `ft_scroll_to` が落ちた行を探して2回で 101 秒を空費した(`maxElements: 400` なら1回で全行入る)。
  **間引きの優先度そのものは変えない**(同じ規則がネイティブのリスト行にも当たるため。
  却下履歴は `BridgeSnapshotThinning.bulkGroupMinimum` のコメントと同型)。
- **探索中の打ち切りは最終木からは分からない**: 目的の行が画面に入っていた周回で上限に
  当たっていても、通り過ぎた先の最終画面が上限内なら注記は黙る。`ScrollSearchResult.
  maxTruncatedDuringSearch` が周回ごとに記録し、失敗した探索だけ `StepNote.truncatedDuringSearch`
  として運ぶ(MCP はこれで「不在の証拠にするな」と言う)。
- **DSL の否定判定も上限を上げる**(2026-08-15)。上限は**読み手が読み切れる量**として決めた値
  なのに、読み手の居ないシナリオ実行が同じ木で「不在」「件数」を結論していた ——
  間引かれた要素は木の上で存在しない要素と1文字も違わないので、`notExist`/`countIs` が
  **黙って誤った成功**になる(`StepExecutor.retakenAtElementLimitCeiling`)。規律は3つ:
  **①切り詰められた木で不在を結論しない**(天井まで上げて撮り直す)/
  **②一度当たったらこの検証の残りも天井で撮る**(`needsCeiling` の latch。毎周2枚払わず、
  判定に使う木が常に天井のものになるので失敗文言が嘘にならない)/
  **③天井でも足りなければ「判定不能」で落とす**(「見つからない」と言わない。
  送られていないだけの要素を「無い」と報告するのがこの欠陥そのもの)。
  探索中の打ち切り(上記)も同じ理由で `notExist(scroll:)` を通さない ——
  通り過ぎた画面の木はもう手元に無く、撮り直しでは救えないため。
- **間引きは優先度順**(2026-08-07。ここは長く「hittable 優先」と書いてあったが、実装は
  両 OS とも先着順だった)。低い帯から順に、**同じ帯の中では preorder の後ろから**捨てる。
  **並べ替えはしない** —— `RefGuard.lineage` が preorder+depth でツリーを復元し、
  ref の大小を z-order の代理に使うため:

  | 帯 | 中身 | 捨てる順 |
  |---|---|---|
  | tier2 | ラベルも identifier も持たない | 最初 |
  | tier3 = bulk | 同一 identifier が20件以上・非操作(自身が scrollable なら除く) | 2番目 |
  | tier1 | ラベルか identifier を持つ | 3番目 |
  | tier0 | 操作可能(clickable/入力欄など)か scrollable な容器 | 最後 |

  **tier2 を bulk より先に捨てる**(2026-08-08 に変更。旧順は bulk が最初だった)。
  ラベル付き同一 identifier 群(bulk)は、ラベルも id も無い装飾(tier2)より本物のコンテンツ
  である見込みが高いので、超過時は装飾から削る。POI 洪水のような大群の捲れは、tier2 が
  少ない画面では次に bulk が捨てられるので従来どおり保たれる。

  **bulk に「スクロール容器の外」という条件は置かない**(2026-08-08 に撤廃)。Apple マップの
  地図 POI(`id=VKPointFeature` ×67〜77、画面により変動)は地図=スクロール容器の中に居るため
  旧条件では bulk を素通りしてラベル付き tier1 になり、**preorder 前方(地図は木の先頭)に
  居るため同 tier 内では最後まで残って**、後方のカード内容から先に落ち、経路画面で 84 件の
  切り詰めを起こした。ラベルの異同は条件に入れない(同一 id ×20 はそれ自体が「塊」の証拠)。**scrollable な要素はどの帯でも捨てない**(cap 免除。容器が
  木から落ちると scrollFrame 解決が全滅する — 下記「scrollFrame の fail-fast」)。
  **この cap 免除は Swift 側(iOS の xcuitest ランナー・in-app dylib・WebView DOM マージ)だけが持つ**。
  Android の `SnapshotBuilder`(Java、tier0〜2 のみ)は tier0 を最後に捨てる点は同じだが、
  scrollable の cap 免除は持たない。また Compose/Flutter を XCUITest ブリッジで撮った木は
  スクロール容器が `.other` として出て `scrollable` を申告できず(in-app なら申告できる)、
  この免除には最初から乗らない。

  - 規則の定義元は **`BridgeSnapshotThinning`(`Sources/FTCore/BridgeDTO.swift`)**。
    XCUITest ランナーと in-app dylib が共有する。**Android は Java で書けないため
    `SnapshotBuilder.selectByPriority` に個別実装**していて、**tier3 だけ持たない**
    (下記のとおり Android では発火しなかったため。足すときは Swift 側を正として写す)
  - 先着順だと落ちるのは preorder 末尾で、**害の形は OS で違った**。Android(Material)は
    app bar と FAB が末尾に出るので**戻るボタンが画面に出ているのに木から消える**
    (実測: 発車一覧が 142 要素で `#nav_button` が引けない)。iOS は chrome が木の前方なので
    残り、代わりに**詳細シートの中身**が落ちる
  - **tier3(bulk)は iOS のために足した**。Apple マップの打ち切り画面は tier2 が 0 件で、
    枠の 75% を同一 identifier の装飾ピン(`id=VKPointFeature` ×90)が占めるため、
    tier0〜2 だけでは中身が落ち続けた。**スクロール容器の中の大群(=長いリスト)は降格しない**
    のが誤検知よけで、この判定は**生のツリーの再帰でしか採れない**(容器自体は identifier が
    無いとフィルタで落ちるので、出力済みの配列から親を辿ると正当なリストを bulk と誤る)
  - 誤検知の確認は**コーパス14本**(iOS/Android・2種の地図アプリ・4 SUT の実画面)で全数。
    発火は狙いの `VKPointFeature` ×90 の1件だけで、**Android は1画面も発火しなかった**
    (Google マップを含む)
  - **打ち切りは「何件」ではなく「何が」落ちたかを申告する**(2026-08-09。
    `SnapshotResponse.truncatedTiers` / `BridgeSnapshotThinning.droppedByTier`。版60)。
    実測(Apple マップの経路プランナー): 候補 211 件のうち **91 件が脱落**し、残った 120 件の
    **56% が地図の POI** だった。ここで「間引きの方針が妥当か」を議論しようとしたが、
    `truncatedCount` は件数しか言わないので **落ちた 91 件が飾りなのか操作要素なのかを
    ホストから知る手段が無かった**(残った側しか届かないため、後から再構成もできない)。
    そこで捨てた本人が tier ごとの内訳を申告する。キーは番号ではなく語彙
    (`operable` / `labelled` / `decoration` / `bulk`)—— 番号を外へ出すと、捨てる順を変えた
    瞬間にホストの表示が嘘になる。**iOS の2ブリッジだけが申告する**(Android の
    `SnapshotBuilder` は tier3 を持たず語彙が揃わない。tier3 が iOS 限定なのと同じ理由)。
    ホストは `ft_snapshot` / `ft_scroll_to` の**先頭 note** で出す —— `(+91 elements truncated)`
    は 120 行の一覧のいちばん下にしか出ておらず、いちばん重い事実がいちばん読まれない位置にあった。
    **捨てる順(tier)自体はまだ変えていない**: 上の 91 件が何だったかは、この申告が入った
    ブリッジで採り直してから判断する(見積りで順序を触らない)
  - **打ち切りに掛からなくても、大群は読む側の邪魔になる**(2026-08-09)。Apple マップの
    1画面は `id=VKPointFeature` が 42〜67 件あり、**一覧の 47〜58% がこれ**で、本物の UI が
    毎回下半分へ押し込まれていた。そこで**描画側でも畳む**:
    `SnapshotRenderer.render(collapsingBulk:)` が「同一 id が `bulkGroupMinimum`(=20。
    ブリッジの bulk tier と同じ値)以上・すべて `other` の葉・非スクロール」群を
    **見出し1行 + 「ラベル[ref]」の索引**に畳む。**frame は落とすが ref は全件残す**
    —— 実測で `#VKPointFeature` の ref タップは場所カードを開くので、消してはいけない。
    **印(⚠️scroll-leftover 等)が付いた要素も畳む**(2026-08-10): タップ時に RefGuard が
    改めて警告するので、snapshot 時点の個別列挙は冗長 —— 地図 POI 231件中40件が印付きという
    だけで出力の半分を個別行が占めていた。見出しに旗ごとの件数を添える
    (`38 ⚠️scroll-leftover, 1 ⚠️offscreen among them`)。`ghostNote` の先頭注記も畳まれた ref を
    個別列挙せず、`(+N folded into the ×M id=… line below)` で件数だけ言う(判定は render と
    同じ `SnapshotRenderer.foldedGroups` を共有し、二重実装を避ける)。
    `ft_snapshot` は既定で畳み `expandBulk: true` で全行に戻す。`ft_scroll_to` は常に畳む
    (答えは「探した1つがどこに居るか」なので大群を並べる意味が無い)。**間引き(ブリッジ)と
    畳み(描画)は別物** —— 前者は配列から消し、後者は見せ方を変えるだけ
  - **注記も同じ理由で畳む**(2026-08-12 の実アプリ監査)。減らすのは2形だけ:
    ① **記号だけのラベルは曖昧ラベル一覧に出さない**(`MCPServer.isSymbolOnlyLabel`)——
    実測(Google マップの経路詳細)では区切りの `" · "` ×3 が代替セレクタ付きで注記の上位を
    占めていた。**飾り葉フィルタ(`isDecorativeLeaf`)を広げて対応しない** ——
    あちらは `type == "other"` の判定で、staticText まで飾り扱いにすると見出しや値という
    正当なセレクタ対象が消える。判定は「Unicode の英数字(L\*/N\*)を1文字も含まない」で、
    仮名・漢字も語に含める。② **leftover / offscreen の注記は最外の行だけ名指す**
    (`MCPServer.outermost`)—— 実測(Apple マップの経路詳細)では leftover 8 件のうち 7 件が
    先頭行の子孫で、1つのはみ出しを 8 回読ませていた。子孫を撃つときは祖先も必ず同じ状態
    なので安全上の情報は減らず、**行そのものに付く ⚠️ 印は従来どおり全行に出る**
    (落とした件数は `(+N descendant row(s) of these, same flag)` で言う)
  - **bulk 群は要素上限の勘定に入れない**(版 61。2026-08-09)。上限は「読み手が選ぶ対象」に
    使い切らせるためのものなのに、実測(Apple マップの経路手順)では `#VKPointFeature` が
    保持 119 件中 87 件 = 73% を占め、操作可能要素とラベル持ち要素をその分だけ押し出していた。
    `BridgeSnapshotThinning.indicesToKeep` は **bulk を予算から外し**(`bulkExemptCeiling` = 400 の
    安全弁つき)、残りにだけ tier2 → tier1 → tier0 の掃き出しを掛ける。
    **捨てるのではなく外す**ので、ref タップ・SelectorInventory への記録・expandBulk の展開は
    従来どおり効く。件数は `SnapshotResponse.bulkExemptCount` で申告し、ホストは
    「上限を超えているのは異常ではない」と言える(超えた一覧を見て木が壊れていると読ませない)。
    **iOS の2ブリッジだけ**(Android は tier3 を持たないので nil = 従来動作へ縮退)
  - **「畳める群を先に捨てる」は却下**(2026-08-09 に実装して撤回)。動機は実測
    (Apple マップの経路手順で `#VKPointFeature` が **119 件中 87 件 = 73%**)だが、
    **同じ述語はリストの行にも当たる** —— 同一 id ×20 以上の行は普通にあり、群の尾を先に
    落とすと 30 行のリストの 21 行目以降が**無ラベル装飾より先に**消える。
    tier2 → tier3 の順序はまさにそれを防ぐために選ばれており(`BridgeSnapshotThinning`)、
    地図 POI とリスト行を木から見分ける手掛かりは無い(祖先ベースの区別は版 58 で一度失敗済み)。
    **代わりに原因を名指しする**: 打ち切ったときだけ `MCPServer.capHogNote` が
    「`#VKPointFeature` が 119 件中 87 件(73%)」と添える —— 読み手に取れる手は
    「それを描いている物を畳む」だけなので、**方針を変えずに手掛かりだけ渡す**。
    実地確認(2026-08-09・Apple マップ)では、この画面の打ち切り 164 件は内訳が
    **全件 bulk** で、間引き自体は正しく動いていた(仮説だった「本物の UI が押し出される」は
    起きていなかった)
  - **レイアウト専用の行を隠す `interactiveOnly`**(2026-08-09)。`ft_snapshot` の任意引数で、
    「ラベルも値もプレースホルダも持たず、操作可能な型でもスクロール容器でもない」要素を
    描画から落とす(`SnapshotRenderer.isSubstantive`)。実測では Google マップ Android の
    1画面 88 行のうち大半が `#navigation_bar_item_icon_container` `#fab_icon` `#TextStackView`
    のような**子と同じ矩形のレイアウト容器**で、実地確認でも 9〜18 行が消えた。
    **隠すのは描画だけ**(ホストが覚える木は素のまま)なので ref も frame も動かず、
    隠れた行も `ft_tap` で撃てる。**印の付いた行は隠さない** —— 印は行ごとに読ませるためにある
- **比較前の正規化は用途で2つに割れる**(`FTCore/TextNormalization`。2026-08-09 のユーザー決定)。
  求められるものが逆を向いているため、1つの規則では両立しない:

  | | セレクタでフィルタ(`.selector`) | テキストと期待値の比較(`.text`) | `strict` |
  |---|---|---|---|
  | 目的 | **見つける**(寛容に寄せる) | **確かめる**(見た目が一致すれば同じ) | 一切正規化しない |
  | 単独クラスタの不可視文字 | 削除 | 削除 | そのまま |
  | クラスタ内の制御文字(ZWJ・異体字・結合文字) | **残す** | **残す** | そのまま |
  | 空白の種類 | 全部 U+0020 へ | **NBSP だけ**(全角・thin space は別物) | そのまま |
  | 連続空白 / 両端 | 畳む / トリム | そのまま | そのまま |

  **判定は列挙で持たない**: 「そのクラスタが `Cf`/`Cc` だけで出来ていて、かつ White_Space でない」
  なら落とす。単独で立つ不可視文字(ZWSP・BOM・双方向制御・ソフトハイフン・C0)はこれで落ち、
  可視文字と同じクラスタに居る制御文字は残る —— **数え漏らした文字にも自動で効く**。
  例外は**末尾に余った結合子**(ZWJ/ZWNJ)で、繋ぐ相手が無いので落とす。実データの根拠は
  Google マップの `"…中央線\u{200D}\u{FEFF}"`(見た目は `"中央線"` そのもの)。
  異体字セレクタは末尾でも残す(直前の文字の見え方を変えるので繋ぐ相手が要らない)。
  タブ・改行・NEL は分類上 `Cc` だが White_Space なので**消さずに寄せる**
  (順序を逆にすると `"A\tB"` が `"AB"` になる。2026-08-09 にテストで検出)。
  描画(`SnapshotRenderer`)は `.text` を通す —— 印字は「画面で見えているもの」を写すため。
  **アサーション側は 2026-08-09 まで正規化ゼロだった**(素の `==`)ので、ゼロ幅1文字で
  `textIs` が落ちるのに同じ文字列のセレクタは当たる、という経路ごとに答えの違う状態だった。
  `strict: true` は DSL の引数 → `FlowStep.strictText` → `StepExecutor.textNormalization` で届く。
  **不一致の失敗文は「どちらの規則なら一致したか」を必ず出す**(`normalizationVerdict`) ——
  見えない差で落ちたのか本当に違う文字列なのかで、読み手の次の一手が変わる
- **「書けるセレクタ」は1箇所で決める**(`MCPServer.SelectorNaming`。2026-08-09)。
  優先順は **一意な `#id` > 一意なラベル > 型で絞る `.型&&ラベル` >
  スコープで絞る `#容器 >> ラベル` > スコープ記法 `#容器 >> .型[n]` > 書けない(nil)**。
  曖昧ラベル注記(B)と操作系の戻り値(E)と下書き生成(F)が同じ実装を通るので、
  「注記が勧めた式」と「シナリオに書かれる式」が食い違わない。
  **勧める前に自分で引く**: 候補を組み立てただけでは書けているか分からず、実際に
  ラベルを `"…"` で囲んで出していた版は**引用符ごと literal になって1件も当たらなかった**
  (実アプリ 18 枚へ当てて発覚)。`picksExactly` が DSL 本体の `matchDetailed` で解決し、
  当人が返ることを確かめてから返す。**`resolvedCandidates` は使わない** ——
  あちらは `[n]` を適用する前の候補列なので、正しいスコープ記法を「曖昧」と誤判定する
- **索引に落ちる前に絞る**(2026-08-12 の実アプリ監査)。`&&`(AND 合成)と `>>`(スコープ)は
  DSL の記法にあるのに候補に無く、「一意な id も一意なラベルも無い」を即 `#容器 >> .型[n]` へ
  落としていた —— 実測(Google マップの検索候補)では `#typed_suggest_container >> .clickable[3]`
  しか書けず、**候補の件数が変わると別の駅を選ぶ**。新しい2形は位置に依存しないので `.stable`。
  **既存の提案は1件も動かさない**(`#id` と一意ラベルより後ろへ入れる)—— 実アプリ・自前 SUT の
  コーパス 974 要素で確認: `indexed 326 → 157` / `書けない 38 → 18` / **既に stable だった行の
  変化 0 件**。
  **`.stable` を名乗る式は候補が1件だけであること**まで確かめる(`picksOnlyOne`)——
  `picksExactly` は `matchDetailed` の先頭一致を見るだけなので、**曖昧な式でも群の1件目には
  true を返す**。添字なしの新形をそれだけで採ると、1件目にだけ「一意に指せる」と嘘の助言が出る
  (2026-08-12 に既存テストが実際に捕まえた。この検査だけでコーパスの偽提案が 19 件消えた)。
  **`[n]` を含む式には使わない**(`resolvedCandidates` は添字適用前なので必ず複数)ため、
  検査は**綴りではなく耐久性**で選ぶ。スコープの解決規則(`uniqueScopeID`)は
  `.型[n]` 版とラベル版で共有する —— 2箇所に持つと別の容器を指しはじめる。
  **候補は数え上げで足切りしてから検証する**: 候補1つの検証は木2周で、当たらない候補まで
  並べると注記1本の生成が実アプリ画面で **29ms → 116ms** になる(2026-08-12 に実測)。
  「型×ラベル」の出現数は `SelectorNaming.init` の1周で持ち、スコープ内の出現数は
  候補を組む直前に1回だけ数える。**ゲートは取り分を1件も削らない**(コーパスの格付けは
  ゲート有無で完全に同一)ので、増えるのは速さだけ。
  **`=` 逃がしは素で書けない形のときだけ後ろに足す**(`needsEscaping`)——
  順序を入れ替えてはいけない: `asWritten` は逃がしを外した形を返すので、逃がし形を先に採ると
  **注記の文字列と下書きのコードが食い違う**(実測: ラベル `" ·"` で注記 `" ·"`・コード `"·"`)。
  判定は2種類で、**意味が変わる形**(`#`/`.` 始まり・演算子)と**綴りが往復しない形**
  (前後の空白)の両方を見る
- **「書ける」と「壊れにくい」を混ぜない**(`MCPServer.Durability`。2026-08-10)。
  優先順は「書けるか」で並んでいるが、`#容器 >> .型[n]` の `[n]` は**同じ型の兄弟が
  1つ増減しただけで別要素を指す**。無印で同じ一覧に並べると生成器は先頭を採るだけなので、
  **添字付きにだけ印を付ける**(一覧は `~`・単発の戻り値は但し書き・下書きは行末コメント)。
  印を付けるかは**候補の出所**で決まる(`Durability` は候補と一緒に組み立てる)——
  要素側の事情を後から持ち込むと、同じセレクタに対して注記と戻り値で言うことが割れる。
  **綴りで判定しない**: `#容器 >> .clickable` は `[` が無くても位置依存(= 添字付き)で、
  逆に `#容器 >> ラベル` は `>>` があっても位置に依存しない(2026-08-12)。
  どちらも「綴りを見れば分かる」と考えた版が取りこぼした。
  **安定側には何も付けない**: 全行にコメントが付くと読み飛ばされ、危ない行が埋もれる。
  **単発の戻り値の但し書きは初回だけ満額**(`reproductionNote` の `once("indexedSelectorCaution", …)`。
  2026-08-10)。id の薄いアプリ(地図等)ではタップのたび同じ index-based 注意が繰り返され、
  id を足せない他社アプリ相手ではノイズになる。**セレクタ自体は毎回出す**(縮むのは但し書きだけ)
- **下書きは刈り込める**(`InteractionLog.prune`。2026-08-10)。記録は「やったこと」であって
  「意図」ではないので、行き止まりのタップも試し打ちも同じ忠実さで載る。どちらも成功した操作なので
  自動では見分けられず、**番号を見せて選ばせる**(`drop:` / `lastN:`)。
  **番号は絞り込んだ後の並びに振る** —— 一覧を見て選ぶ道具なので、見えている番号と落ちる手が
  一致していなければ意味がない。範囲外の指定は**黙って無視せず**警告する(番号を1つ外しただけで
  別の手が落ちるので、効かなかったことに気付けないと誤った下書きを持ち帰る)
- **宛先は入口で1つに畳む**(`MCPServer.foldingUDIDIntoPort`。2026-08-10)。`udid` は
  `call(tool:args:)` で `port` へ解決してから配る。**機ごとの記憶は `sessionKey` で引く**
  (`lastSnapshots` / `launchedBundleIDs` / `uiFrameworkHints` / `connections` /
  `pendingWarnings` / `udids` / `bridges` / `rememberedSnapshotFilters` の8つ)が、`sessionKey` は
  生の引数しか見ないので、畳まないと udid で指した機が全部 `port=nil` の同じキーへ落ちる。
  実測した3症状(すべて同じ根): ft_status が `@ port …` を出さない / allowVersionSkew の
  警告が出ない / 機A に Preferences・機B に Maps を launch した後、機A への ft_open_url が
  com.apple.Maps へ配ると申告する(Android では intent の宛先なので実際に誤配送する)。
  **新しい宛先の指し方を足すときは、ここで畳めているかを必ず見る** ——
  ドライバのキャッシュだけ直しても記憶の側は揃わない。
  **畳むのは宛先(`udid`/`port`/`serial`)を取るツールだけ**(`toolAcceptsDeviceTarget` の分岐
  1箇所。2026-09-23)—— 畳み込みは `udid` → `port` の解決にブリッジ走査を撃つので、居なければ
  「no running bridge」で落ちる。1台を駆動している呼び手は `udid` を毎回添えるため、
  ブリッジが死んだ瞬間に `ft_list_devices` / `ft_doctor` のような**宛先を取らない一覧・診断まで
  道連れ**になり、その文面が案内する `ft_list_devices` 自身が同じエラーを返す袋小路になっていた
  (MN-46.5。集合は `DeviceIndependentToolsIgnoreTargetTests` が等号で固定する)。
  **セッション内デバイス記憶も同じ入口で畳む**(`MCPServer.foldInRememberedDevice`。2026-08-12)——
  当初 `driver(_:)` 内で適用していたが、キャッシュキーと `sessionKey` が生の引数を見るため
  「明示切替後の省略呼び出しが旧デバイスのキャッシュ済みドライバを引く」
  「明示 port で採った ref が省略呼び出しから見えない」の2症状を生んだ(上と同根)。
  適用条件は「udid/port/serial のどれも有効値で来ていない、かつ profile なし」で、
  判定は Android と同じ空文字規則(`argsGaveIOSTarget` / `argsGaveAndroidTarget`。
  `udid: ""` は省略扱い —— キー存在で見ると自動解決の結果を「利用者が選んだ」として記憶してしまう)。
  規律は4つ: **① iOS は port だけ注入する**(udid まで注入すると毎呼び出しに全ポート走査 +
  `reconcilePort` が走り、ブリッジが busy(quiescence 中は /status 無応答)なだけで hard fail する)/
  **② 注入した呼び出しは記憶を再記録しない**(`deviceFromMemoryKey` マーカー。再記録すると
  ポート再利用で別の機に化けたとき記憶が黙って乗り換わる)/ **③ platform も記憶する**
  (`lastExplicitPlatform`。platform 省略の既定は ios なので、これが無いと直前まで Android を
  driving していても省略呼び出しが iOS へ行く)/ **④ 注入は応答へも注記する**(ターゲットごとに
  初回だけ。stderr は MCP クライアントに見えない)。
  `forgetConnection` は一致する記憶も消す —— 消さないと、死んで別ポートで起動し直された
  ブリッジへ省略呼び出しが永久に再ダイヤルする。Android の死亡判定は
  `AndroidSerialResolver.connectedSerials()` の再照会(`androidSerialVanished` = 純粋関数)。
  **曖昧なら適用せず拒否する**(2026-08-13。`isAmbiguousMemory` / `rememberedDeviceRefusal`)——
  2026-08-12 は「2台以上なら毎回注記しつつ直近へ流す」だったが、**注記は事故を1件も止めなかった**。
  監査19(serial だけの呼び出しが黙って iOS へ)・監査20(キャッシュ命中で記憶が更新されない)・
  udid 2台の記憶混線は**3件とも「2台以上を触ったセッション」でだけ**起きており、逆に1台しか
  触っていないセッションは原理的に外しようがない。**記憶が安全なのは、それが一意なときちょうど**
  なので、そこを境に警告から拒否へ格上げした(1台のセッションの手数は変わらない)。
  拒否は候補を名指しする —— 断るだけだと読み手は総当たりで udid を試し、結局どれかの機を操作する
- **キーが指す機が変わったら、そのキーの状態は全部捨てる**(`MCPServer.forgetDeviceState`。2026-08-13)。
  `sessionKey` は `direct:ios:<port>:<serial>` で、**iOS のポートはセッション中に動く**
  (監視が別ポートで起動し直す。実測: -03 が 8128→8126)ので、死んだポートは後で別のシミュレータに
  再利用され得る。`forgetConnection` が `drivers`/`connections`/`connectedPorts` しか消して
  いなかったため、`lastSnapshots` と `refGenerations` は**前の機の木**、`launchedBundleIDs` は
  **前の機で起動したアプリ**のまま生き残っていた(古い ref が別の機の木を起点に解決され、
  `ft_open_url` が前の機のアプリへ配送する)。**出力がずれるだけの記憶と違い、これは操作が
  別物へ届く型**なので後始末を1箇所に固める。**`nextRefBase` だけは残す**(単調増加の不変条件。
  0 へ戻すと捨てた世代と同じ base が再配布され、世代管理が防いでいる「番号は同じだが別要素」を
  後始末の側から作る)。版ズレ拒否は `drivers[key]` だけを nil にするので、`driver(_:)` の
  iOS 生成側でも **udid の変化**(port ではなく機そのもの)を見て同じ後始末を撃つ
- **版ズレは既定で拒否**(2026-08-09 に警告から格上げ)。MCP の出力はシナリオへ書く文字列を
  供給するためにあるので、**古いブリッジの出す古い注記から誤ったセレクタが書き込まれる**ほうが
  「セッションが止まる」より高くつく。ゲートは `driver(_:)` の1箇所(`enforceVersion`)なので
  デバイスを掴む全ツールに掛かり、`ft_status` は「失敗するが理由と直し方を返す」。
  **どちらが新しいかを明示する**(対処が変わる)。押し通しは `allowVersionSkew: true` で、
  その回以降は**毎回**警告が付く(1度言って黙らない)
- **操作直後の整定(xcuitest, 2026-07-21)**: XCUITest の tap quiescence は非同期 push 遷移の
  完了前に返り、かつ直近 snapshot をキャッシュするため、操作直後の素取得は遷移前ツリーを返す
  (実測 50%)。対策として、直前が画面変更操作(tap/type/swipe/drag/press/session/…)だった
  snapshot に限り、取得前に短い待機(実測 350ms で staleness 0/10)を入れて遷移後の fresh ツリーを
  返す(`BridgeRouter.settlePending`)。連続 snapshot(操作を挟まない再取得)は据え置きで課金しない。
  固定待機は XCUITest が非同期遷移完了の event-driven な信号を出さないための妥協(要 private の
  quiescence API を使えば event-driven 化できるが未採用)。in-app ブリッジは tap 側の `InAppSettle`
  (アニメ整定をイベント駆動で待つ)が既に遷移を待つため対象外。
  **2026-10-09 からタップ・ダブルタップ・長押しは XCTest の quiescence 待ちを既定で飛ばす**(`QuiescenceWait.around` の
  `skipByDefault`)ので、タップ系の遷移の整定は操作直後の取得の `captureSettled`(2回続けて同じ木・予算で打ち切り)が
  単独で担う(4 SUT の A/B で退行無し。スワイプは待ちを残す。詳細は DS-11.2 の「DSL の `settle: false`」の段落と
  PT-8)

**value の正規化: placeholder がそのまま来る欄は空にする**(2026-08-06)。
WebKit は空の `<input>` の AXValue に placeholder を入れて返す(UIKit の入力欄は入れない)ため、
正規化しないと **iOS の WebView だけ `value="WebView 入力"`** になり `valueIs("")` が通らない。
**Android の同じ欄は empty で返る**ので、経路で割れていた。判定は `clearInput` の
`remainingText` と同じ規則(`value == placeholderValue` なら空)。

**重複ノードの畳み込み**(2026-08-06。規則は `Sources/FTCore/SnapshotDedupe.swift`)。
iOS の AX ツリーは**ラッパと実体を両方出す**ことがあり、実測で3形あった:
UIKit の Switch(`id=sw_notify 61x28` と無名の `63x28`)/ `UIAlertController` の各ボタン
(同一 frame・同一 id で2つ)/ キーボードの `#dictation`。**Android のブリッジは1つで返す**。
実害は「`.button[n]` の序数が見え方とずれる」と「同じ id が複数候補になる」。
落とす条件は**型が同じ・位置がほぼ同じ(2pt)・情報を足していない**の3つとも成り立つときだけ
(内側が id やラベルを新しく持つ形は落とさない = 指せる要素を消さない)。
**ラベルが違えば落とさない** —— 同じ矩形へクランプされた行(`行 09`〜`行 40` が `行 01` の
位置に畳まれる形)は重複ではなく「描かれていない残骸」で、扱いは MCP 側の警告(§MCP)。

### DS-4.4.1 WebView の中身

WebView(iOS=WKWebView / Android=android.webkit.WebView)の中身は、経路ごとに見え方が違う。

| 経路 | 中身の取得 | 備考 |
|---|---|---|
| Android ブリッジ | a11y の仮想ツリー | リンクは Chromium の `chromeRole`(非ローカライズ)で `link` に正規化。**全ノードを `refresh()`** してから読む(WebView は DOM 変更の a11y 反映が 4〜8 秒遅れ、ネイティブ画面でも IME 等が前面だと数秒古いツリーが返る) |
| iOS xcuitest | a11y ツリー | 中身が現れるまで **約 2.3 秒**(WebContent プロセスの a11y 起動待ち) |
| iOS in-app(uikit ホスト) | **DOM を JS で走査** | `InAppWebViewDOM` + `WebViewDOM.javaScript`。1往復・隔離ワールド |
| iOS in-app(Compose / Flutter ホスト) | **DOM を JS で走査**(2026-08-02 から) | interop が合成タッチと `insertText` を横取りするので**読めても操作は届かない**。読みは DOM のまま、**ref を使う操作だけ座標へ解決して XCUITest の実タッチ**へ回す(`webViewPath: "dom-interop"`。PT-3.13)。画面ごとの委譲は DOM が全く読めない構成だけに残る |

- **a11y ツリーは in-app からは見えない**(Web コンテンツの AX は WebContent プロセスが提供する)。
  そこで in-app は `evaluateJavaScript` で DOM を1往復読み、a11y 経路と同じ DTO へ写す。
  可視性(display/visibility/aria-hidden/0px/画面外/`elementFromPoint` の被り)は JS 側で自前判定する。
  **被りを見る点は「見えている部分」の中心**(素の中心ではない。2026-08-25)——
  ページがスクロールして上端に少しだけ残った入力欄は素の中心が viewport の外にあり、
  `elementFromPoint` は viewport 外の点に null を返すので、**触れる要素が木から丸ごと落ちる**。
  a11y 経路は残すので、それは「同じページで経路により見え方が割れる」= この経路が
  避けるために存在する状態そのものになる(witness: E2E-CMP の WebView シナリオが5回中4回赤)。
- **操作は DOM でやらない**。`element.click()` や value 代入は user activation・IME・`:active` を壊すので、
  DOM から得た矩形を画面座標へ変換して**合成タッチ**を打つ(ref に AX ノードを紐付けない =
  `tapByRef` が座標へ落ちる、という既存経路をそのまま使う)。
- **`dom-interop` では ref を XCUITest へ渡さない**。委譲先は自分が最後に撮った別 snapshot の
  ref 名前空間を持つため、混ぜると別要素を指す(「返す snapshot と ref の名前空間を一致させる」
  不変条件)。ホストが ref → 矩形中心 → 座標に解決してから渡す。
- **DOM の要素は WebView ノードの直後に、その depth + 1 で差し込む**(in-app の `mergeWebViewDOM`・
  ホストの `WebViewDOM.insertingDOM` = Android / Safari。**片方だけ変えない**)。子孫は pre-order + depth で
  決まるので、末尾へ足したり depth 0 で並べたりすると `.webView >> …` のスコープに中身が1件も入らず、
  WebView より後ろのネイティブ要素(タブバー等)の祖先の辿りもそこで切れる。
- **Safari に差し込んだ DOM の要素の ref はホストが振る**(応答の最大 ref + 1 から)= ランナーは知らない。
  `BridgeClient` が要素の中心を控え、`tap` / `press` は座標で撃ち、`type` / `clearInput` は座標で焦点を
  立ててから ref 無しで撃つ。`hitTest` はランナーへ聞かず「答えられない」を返す(聞くと「引き当て不能」が
  返り、木が画面を代表していないという別の検知の根拠に化ける)
- **画面に入るとき1回だけ委譲側へ接続確認する**(`delegated.snapshot()`)。これが XCUITest の attach を
  兼ねており、省くと**最初の座標タップが 200 を返しても効かない**。1画面1回に留めること
  (毎 snapshot 撃つと委譲と同じコストに戻る)。
- **DOM 由来の要素は `ElementInfo.web = true`** で申告する。ホスト(`WebViewDelegatingDriver`)は
  これを見て委譲要否を決める。**幾何で「中に何か居るか」を見てはいけない**: Compose iOS の
  interop 容器は WebView と同じ矩形を持つため、中身と誤認して委譲が止まる(2026-07-29 実害)。
- **中身が出ないまま待ちが尽きたら木がそう名乗る**(2026-08-15。`WebViewPath.delegatedEmpty`)。
  委譲直後は XCUITest 側の WebView AX 活性化に時間がかかるので中身ゼロの木を待つが、
  上限(`contentWaitMs` = 5000)は **Simulator の実測 2.3s に対する余裕**でしかなく、
  inapp モードは実機でも動く —— 13_WebView のシナリオ自身が「SUT により最大 約8秒」と書いている。
  尽きたときに黙って空の木を返すと**否定アサーションは必ず通る**(空の木に要素は無い)。
  木からは「AX がまだ公開されていない」と「本当に空のページ」を区別できないので**判定は変えず**、
  `StepNote.webViewNotRendered`(通った回にも残る)と失敗文言で名乗る。
  値の定義元は `FTCore.WebViewPath`(**BridgeDTO には置かない** —— あちらはブリッジの
  ソース集合で、触ると3ブリッジの指紋が動く)。
- **効果**(E2E-iOS / ios-inapp・4 run で再現): WebView 画面の検証 1 手が **450ms → 4ms**、
  シナリオ全体 **27.2s → 10.3〜11.0s**。委譲中は XCUITest 経由で 1 手 378ms かかっていた。
- **委譲中でもスクロールだけは in-app で行う**(2026-08-01)。interop が横取りするのは**タッチ**で、
  WKWebView の中の `WKScrollView` は本物の `UIScrollView` なので `contentOffset` は素通しで効く。
  `InAppBridge.handleSwipe` は compose/flutter + `scroll=true` のとき、AX 経路より先に**画面中央を
  覆う `WKScrollView`** を探して動かす(中央で絞るのは小さな埋め込み WebView のために画面本体の
  スクロールを奪わないため)。端では 501 でなく **no-op 200**(501 だと XCUITest の実スワイプへ
  ラッチして下端タップが不安定になる)。ホスト側は `WebViewDelegatingDriver.swipe(_:intent:path:)` が
  委譲中でも primary を先に試し、501 なら委譲先へ落とす。**ref を使わない操作なので名前空間の
  不変条件は崩れない — ref を伴う操作を同じ理屈で in-app へ回してはいけない**。
  効果は CMP/Flutter の WebView シナリオが **41s → 24s**(PT-3.11)
- **クロスオリジン iframe は読めない**(main frame の JS からは触れない)。数を数えて
  `SnapshotResponse.note` で申告する(黙って要素ゼロにしない)。
- 殺しスイッチ `FT_WEBVIEW_DOM=off`(ホストの環境変数。`SIMCTL_CHILD_` で注入先へ引き渡す)。
- **interop 配下かは WKWebView 単位で決める**(`WebViewDOM.isInteropHosted`)。祖先に
  `FlutterView` / `FlutterTouchInterceptingView` / `androidx.compose.ui.*` / `RNCWebView` が居れば interop 配下 =
  読めても操作が届かないので、**DOM は読んだうえで `webViewPath: "dom-interop"` を名乗り、操作だけホスト側
  (`WebViewDelegatingDriver`)が XCUITest へ回す**(上の表・下の「`dom-interop` では ref を XCUITest へ渡さない」)。
  **アプリ単位で判定してはいけない**: UIKit アプリの
  Flutter add-to-app や CMP 画面混在では、アプリは uikit なのに中の WebView だけ interop 配下になる
  (逆に1画面のためにアプリ全体で DOM 経路を捨てることにもなる)。目印は実測の祖先チェーンから採った
  (SwiftUI の `UIKitPlatformViewHost` は "PlatformView" を含むので雑な部分一致は禁物)。

**hitTest による名前非依存の判定は不採用**(2026-07-29 に実測。再提案しないこと):
WebView 中心点の `window.hitTest` が当の WebView かその子孫を返すかで interop を見分けられないか
測ったが、**3構成を分離できない**。Flutter は名前に反して**ヒットテストを WebView へ通し**
(`FlutterTouchInterceptingView` はジェスチャレコグナイザ側でタッチを食う)、
selfOrDescendant=true になってネイティブと区別が付かない。CMP だけは `OverlayInputView` が
ヒットテストを奪うので false になる。祖先のジェスチャレコグナイザ数も
ネイティブ 6 / CMP 9 / Flutter 12 で閾値に使えない。よってクラス名の目印を維持し、
取りこぼしは**失敗文言の注記**(`StepExecutor.webViewPathHint`)で追跡可能にする方針とする。

**失敗文言に経路を添える**(`SnapshotResponse.webViewPath`)。DOM 経路の未検出は
「無反応タップが成功として記録され、2ステップ先で別の文言で落ちる」形で出るため、
落ちた側に経路を書かないと追跡コストが跳ね上がる。**経路は snapshot を返したドライバが名乗る**:
要素の形から推測すると、webView 型を出すが web フラグを持たない **Android が
「XCUITest へ委譲」を名乗る**(2026-07-29 実害)。申告が無ければ何も足さない。

**`#id` は WebView 内でも使える**(旧「確定仕様: 使えない」は 2026-08-14 に撤回。
撤回の根拠と現在の供給源は §木はどこから来るか)。**意味は構成によらず id の完全一致**で、
変わるのは意味ではなく**供給の有無**だけ。供給できるのは DOM に届く経路(iOS in-app /
Android のアプリ内 WebView・ブラウザ)と、a11y が id を出す構成(Android WebView 150 以降)。

**撤回前の根拠は2つとも誤りだった**(記録として残す。同じ誤診を繰り返さないため):
「Android は id を出さない」は **WebView 124 限定**の観測を一般則として書いたもので、
150 は `viewIdResourceName` に出す(そのうえ 124 と 150 は **id と placeholder が入れ替わる**。
`AndroidWebViewVersions.swift`)。「CDP は対象アプリの協力が要る」も誤りで、
**debuggable なら `setWebContentsDebuggingEnabled(true)` 無しでソケットが開く**
(2026-08-15 に呼ばないビルドで対照を取って実測)。**リリースビルドは対象外でよい**
(id が難読化されるので id で指すテストは元からデバッグビルドの活動)。

**HTML id を供給できない構成は iOS xcuitest だけ**(WebKit は HTML id を a11y へ出さない)。
そこでは**黙って不一致にせず、構成を名指しして落とす**(`#id` の意味を構成ごとに変えない、
という原則は維持する)。

**`#x` は identifier で引けなければ placeholder を引く**(2026-08-15 ユーザー指示。
判定は `LocatorResolver.candidates` の1箇所)。**構成ごとに意味を変える例外ではない** ——
規則はどの OS・モードでも同じで、`#` が指す名前の集合が「identifier ∪(identifier で
引けないときの)placeholder」になる。入力欄はまさにここが経路で割れる(xcuitest は HTML id を
出さないが placeholder は出す / Android は WebView の版で **id と placeholder が入れ替わる**)ので、
シナリオ側に分岐を書かせない。**identifier が1件でも当たったらそちらだけ**を使う ——
混ぜると `#x[2]` の序数と `countIs` が経路で変わる(静かに別の要素を指す)。
台帳(`SelectorInventory`)も placeholder を貯める = dry-run が実在する欄を誤警告しない。`css=` のような**別記法を `#id` に相乗りさせない**方針も維持
—— css は DOM への問い合わせなので届く構成が `#id` よりさらに狭く(xcuitest と
非 debuggable が外れる)、相乗りさせると `#id` の適用範囲まで狭く見える。

**スクロールヒント(Android の WebView・2026-07-29 実装)**: Chromium は**全ドキュメントの
ノードをツリーに載せる**(画面外は extras の `offscreen=true`・実座標は `unclippedTop/Bottom`。
`isVisibleToUser` は true のままなので明示的に除外しないと通常要素に漏れる)。ブリッジはこれを
`SnapshotResponse.offscreen`(実座標付き・ref=0)として返し、ホストのスクロール探索が
「目的の要素がどの方向・何 px 先か」を知って、固定幅スワイプ(実測 1.05s / 974px)を
少数の長距離ドラッグ(0.44s / 1500px+)へ置き換える(`StepExecutor.offscreenJump` /
`offscreenEdgeJump` / `dragGesture`)。較正は持たず、毎スナップショット(25ms)で測り直す
自己補正。**ヒントは要素解決に使わない**(見えない要素へ exist/tap が当たる)し、
**不在の根拠にもしない**(ネイティブのリストは画面外を載せないため)。
効果(scrollTo 中央値・android プロファイル): ネイティブ 10.2s→3.7s / CMP 8.7s→5.9s /
Flutter は中立(9.5s。ドラッグ後の再計測サイクルが重く相殺。退行はない)。

**iOS(XCUITest ランナー・2026-08-04 実装)**: XCUITest も WKWebView 配下は**全ドキュメントの
ノードを実座標のまま**ツリーに載せる(旧記述「画面外ノードを出さない」は誤り —
`BridgeRouter.shouldInclude` の画面交差ガードが落としていただけ。クランプも無い: 画面 402x874 に
対し y=2784 や y=-1200 が取れ、スクロール量に追従する)。Android と同じ契約
(ref=0・elements に混ぜない)で供給する。**inapp モードには流さない**: WebView 委譲中の snapshot は
`WebViewDelegatingDriver` が offscreen を落とす(in-app の contentOffset 短絡 1.5s の方が速く、
ヒントが乗ると跳躍 = XCUITest 実ドラッグが優先されて遅くなる方向に挙動が変わるため)。
効果(WebView シナリオ・ios-xcuitest・アイドル3周 A/B): scrollTo 9.3〜9.6s→6.5〜7.3s
(全 SUT −22〜31%)/ scrollToTop CMP・Flutter 10.9〜11.0s→9.1〜9.2s(−16%)・SwiftUI 中立
(fling 2〜3回で足りる距離では跳躍の節約が settle コストに埋まる)。残る床は scrollToEdge の
毎周 `settledSignature`(WebView は snapshot 1枚 300〜500ms・減速中比較の実害由来で外せない)。

**未着手の副産物**: `AccessibilityNodeInfo` extras の `targetUrl`(リンクの href。
同ラベルのリンクを区別する手段になり得る)。

### DS-4.5 Android ブリッジ(対になる実装。AndroidRunner/)

iOS ブリッジと同じ WDA 方式を Android の instrumentation として自作したもの。
`AppDriver` の Android 実装(`AndroidDriver`, Sources/FTAndroid/)から見れば
iOS ブリッジと区別なく扱える。

- **常駐 instrumentation**: `am instrument -w` でデバイス内にバックグラウンド常駐させ、
  HTTP サーバ(BridgeInstrumentation)を内蔵する。`AndroidBridge.swift` が初回操作時に
  自動インストール・自動起動するためセットアップ手順は不要
- **共通コア13 + locale/settle/gesture/scrollAction**: DS-4.3 の共通コア(status/session/snapshot/
  tap/type/clear/pressEnter/swipe/press/doubletap/pinch/screenshot/terminate)に `POST /locale`・
  `POST /settle`・`POST /gesture`・`POST /scrollAction` を加えて話す(**`/scrollAction` は Android だけ**:
  端送りの1本を a11y のスクロール操作で送る。指のドラッグは端を越えた余りが SwipeRefreshLayout 等の親へ渡り
  引っ張って更新になるため。宛先は指を置く点を含み軸が合う最小の scrollable、軸が分からなければ送らず
  ホストが従来のドラッグへ落ちる。契約は BridgeDTO.ScrollActionRequest。iOS 固有の drag/appswitcher/home/hidekeyboard/
  appstate/rotate は**ブリッジのエンドポイントとしては持たない**。**機能が無いという意味ではない**
  —— drag / home / hideKeyboard / rotate は `AndroidDriver` がホスト側で adb・注入器を使って
  実装している)
  ため、共通コア部分はホスト側の `FTBridgeClient` 相当のクライアントコードを流用できる
- **操作応答 = a11y 静穏後**: 各操作 API は注入後、対象パッケージの a11y イベントが
  一定時間静まるまで応答を保留する(QuietWaiter)。固定 sleep をやめてイベント駆動にした
  2026-07 の高速化はこの仕組みが土台(詳細・実測は [performance-tuning/](../performance-tuning/README.md))
- **アニメーション自動無効化**: ブリッジ起動時に window/transition/animator の
  アニメーション倍率を 0 に固定し、静穏判定後に screenshot が古い絵を掴む問題を回避する
- **報告する `screen` はディスプレイ全体・フィルタの基準はアクティブウィンドウの根**
  (2026-08-06 に分離)。両方をウィンドウの根で兼ねていたため、**ダイアログが出ている間だけ
  `screen` がダイアログの DecorView**(実測 1024x427 / 735x386)になり、同じ応答に入っている
  要素座標(y=1342 等)がそれをはみ出す自己矛盾した木を返していた。実害はもう1つあり、
  `BridgeRouter` はこれを `lastScreen` として覚え**既定の全画面スワイプとピンチの座標を作る**
  ので、ダイアログを撮った直後の swipe が画面上部の狭い帯を払うことになる。
  ディスプレイは `Resources.getSystem()` の DisplayMetrics から採る(Context を持ち回らない。
  取れなければ従来値へ落とす)。**フィルタ側を display に替えてはいけない** ——
  「画面の大半を覆う容器を落とす」0.85 の意味が変わり、ダイアログの中身の出方が動く
- 実装・落とし穴の詳細は重複させず [AndroidRunner/README.md](../../AndroidRunner/README.md) を参照

### DS-4.6 座標系の契約と Compose の frame 制約

**tap/press/swipe の x/y は snapshot が返す frame と同一座標系。** 単位はプラットフォーム依存:

| | snapshot の `screen`/`frame` | tap の x/y | 備考 |
|---|---|---|---|
| iOS | **ポイント(pt)** 例 `402x874` | pt(同一空間) | window 座標。スクショの px でも screen px でもない |
| Android | **デバイスピクセル(px)** 例 `1080x2424` | px(同一空間) | |

利用側は snapshot の frame 値をそのまま tap の x/y に渡せる(変換不要)。スクリーンショットの
ピクセル座標とは別物なので、スクショ実測 px を tap に渡してはいけない。

**iOS の既知の制約(Compose Multiplatform 等の高密度・縦スクロール画面):**
ビューポート外(フォールド下)の要素は、iOS アクセシビリティの慣習でスクロールコンテナ下端バンドに
frame がクランプされ(y が実描画より小さく・高さが膨張して)報告されることがある。原因は Compose が
iOS の a11y 層に出す frame 自体で、**xcuitest / inapp どちらのモードでも同じ frame を読む**ため
モード切替や座標補正では直らない。実害: クランプされた座標/ref をタップすると、そこに実在する別要素
(または余白)に当たり、目的の要素は発火しない。可視領域内の要素の frame は正確。

回避策(利用側。**唯一確実**):
- 対象を `ft_swipe` で可視領域に入れてから `ft_snapshot` し直してタップする(可視セルの frame は正確)
- 小さすぎる要素(〜17pt)より、可能なら大きい親要素/隣接ラベルを狙う

**採らない対策(2026-07-21 実測で否定・シミュレータ -03)**:
identifier ベースの `XCUIElement.tap()`(scroll-to-visible 期待)は効かない。XCUITest の `isHittable` が
Compose では壊れており、クランプされた画面外セルを `hittable=true`(=画面内)と誤認してスクロールせず
クランプ位置を叩き別セルへ誤遷移する。逆に可視の正確セルは `hittable=false` になり `.tap()` が不規則な
自動スクロールを誘発して外す(座標タップなら当たる可視セルを退行させる)。`.tap()`/`isHittable`/`scroll-to-visible`
はいずれも同じ壊れた frame を信じるため救済不能。座標タップ(現行実装)を維持する。
**「クランプ」という機構の言い方は 2026-08-03 に不正確と分かった**(実採取では、画面外の行は
ビューポート内へ寄せられるのではなく**容器の外にラベル無しで並ぶ**)。この実験の結論
(`.tap()`/`isHittable` を使わない)は変わらないが、**機構を前提に何かを組むなら採り直すこと**。

補足: この frame 破綻とは別に、Compose の合成 a11y 要素は `accessibilityActivate()` が発火しないため、
inapp の ref タップも座標フォールバックに落ち、同じ壊れた frame を踏む(座標非依存の起動経路が無い)。

### DS-4.7 waitForSettle(画面の静止と木の同期)

DSL `waitForSettle(_ selector: String? = nil, quietSeconds: Double? = nil, throwsException: Bool = true, waitSeconds: Double? = nil) -> Bool`
(引数の意味・失敗文言は docs/commands.md「`waitForSettle`」)。**明示したときだけ待つ**。通常の操作の後に画像の静止を毎回待つ方式は、
E2E の A/B で +14〜36% 遅く正しさの差が無かったので撤去した。実測・残す知見(信号ごとの見落とし・描画間隔の最大・撮影の費用)は
PT-3.34。

**エンドポイント契約**: `POST /waitForSettle` に `{region?, quietMs, timeoutMs}` →
`{settled, elapsedMs, frames, lastChangeRegion?}`。`region` 省略 = 画面全体。`settled` は窓(`quietMs`)のあいだ範囲の画素が1つも変わらなかったか、
`frames` は撮った枚数、`lastChangeRegion` は最後に画素が変わった矩形(失敗文言 `last change at x, y, w×h` の元)。
**判定はブリッジの中で完結し、画像はホストへ出さない**(転送は撮影より高い。PT-3.34)。ブリッジの版は iOS `bridgeProtocolVersion` 174・
Android `VERSION_CODE` 100。XCUITest ランナーと Android ブリッジが持ち、**in-app ブリッジは持たない**。

**2段**(`waitSeconds` は `selector` の要素の解決と両段を合わせた上限。解決に使った分を引いた残りで画像の段、その残りで木の段。
実装は `StepExecutor+WaitForSettle.swift`、判定の純粋関数は `WaitForSettleJudgement.swift`):
1. **画像**: 上のブリッジ呼び出し。止まらなければ `the screen kept changing for N s (last change at …)` で時間切れ(座標は小数1桁)。
   ブリッジに渡せた時間が `quietSeconds` より短かったとき(要素の解決で上限の大半を使った・`waitSeconds` < `quietSeconds`)は
   「変わり続けた」とは言えないので、残り時間と窓を事実として書く(`only N s of waitSeconds was left after finding the element, …`)。
   XCUITest ランナーは返す直前に `settlePending` を立てる(次の snapshot を XCTest のキャッシュでなく取り直した木にする)
2. **木**: 画像が静止した後、ホストが**範囲に入る要素だけ**(範囲なし = 画面の枠に入る要素。画面外の行はラベルが取得のたびに揺れるので
   全体の木は比べない)を型・id・ラベル・枠の署名で比べ、2回連続で同一になるまで取り直す。周期は整定のポーリングと同じ規則
   (`settleSleepMs`)、Android はキャッシュを迂回して撮る(`.afterOwnMove`)。絵が止まっても木は遅れることがある(Compose の木は
   絵より遅れ、慣性の間は凍る。PT-3.34)ため。止まらなければ `the screen was still but the accessibility tree kept changing for N s (changing: …)`。
   終わった後の次のロケータ操作の解決もキャッシュを迂回する

**比べる範囲は常に各辺を 10% ずつ除く**。スクロールバー・インジケータのフェード、ステータスバー、ホームインジケータは本体が止まった後も
変わり続けるため(PT-3.34 の実測: Android のタップの 0.3〜2 秒後に出る変化は装飾だけ)。止まらない物(スピナー・シマー)は DSL の `selector` で範囲から外す。

**モード・ブリッジごとの経路と理由**:
- **iOS は inapp モード(既定)でも、撮影は常に XCUITest ランナー**。in-app のスクリーンショットはアプリ自身の描画しか写さず(キーボード・システムアラート・
  他プロセスが無い)、アプリのプロセスの中で撮り続けるとメインスレッドを塞ぐため。木の段は**次のステップを解決するドライバ**を使う(inapp モードなら in-app の木 = 次の解決が読む木と揃える)
- **Android は instrumentation ブリッジの中で撮る**。実機は連続で撮り、エミュレータは 50ms → 変化している間は 50→100ms → 窓の中ほどと終わり
  (エミュレータのスクリーンショットはホストの CPU を使うため間引く)
- **静止の窓 `quietSeconds` の既定**は `FTCore.WaitForSettleDefaults.quietSeconds(framework:isAndroid:)` の1箇所(iOS の Compose Multiplatform と
  フレームワーク不明 = 0.8 秒・それ以外の iOS と Android = 0.5 秒。根拠は慣性の終わりの描画間隔の最大の実測 × 約 1.2)

---

## DS-16 エミュレータ操作の gRPC 制御

Android エミュレータへの操作は**既定で emulator 内蔵の gRPC(EmulatorController)経由**、失敗時は
adb へ自動フォールバックする(ユーザー決定 2026-07-25)。動機は PoC 実測: スクショ 48ms vs adb
140〜250ms(3〜6倍)、キー注入 1.2ms vs 215ms、run 起動オーバーヘッド 3.2s→0.6s、adb 経路死亡個体
への修復・停止の到達性。

### DS-16.1 構成(3層)

| 層 | 場所 | 役割 |
|---|---|---|
| ディスカバリ | `FTEmulatorGrpc/EmulatorEndpoints` | `~/Library/Caches/TemporaryItems/avd/running/pid_<pid>.ini` から serial→port/token/avd.id を解決(pid 生存確認付き。トークンはブート毎に変わる) |
| RPC | `FTEmulatorGrpc/EmulatorGrpcSession`(grpc-swift-2) | 単発 RPC(接続は呼び出し毎)。認証は `authorization: Bearer <grpc.token>` のみ |
| 振り分け | `FTAndroid/EmulatorControl` | emulator なら gRPC・実機/失敗個体は adb。**失敗した pid は同一ブート中 adb 固定**(再ブートで自動復帰)。殺しスイッチ `FT_EMULATOR_CONTROL=adb` |

**gRPC を話すのは Swift だけ**。拡張は自前の gRPC クライアントを持たず、画面凍結修復を
`fleetest api repair-display`(`ApiRepairDisplayCommand`)へ委譲する(以前は `emulatorGrpc.ts` +
`emulatorEndpoints.ts` に proto コピー・ディスカバリ・blank 判定の第二実装があり、閾値と手順を
言語間で同期する必要があった)。proto は `third_party/emulator-proto/`(vendored・再生成手順は
同 README。Swift スタブは生成物をコミット)。

### DS-16.2 置き換え済みの操作と残存 adb

- gRPC 化済み: blank プローブ/sleep-wake 修復(AndroidHealthProbe)・停止=setVmState SHUTDOWN
  (DeviceBooter/DataWiper/DevicesCommand)・serial→AVD 名=ディスカバリ読み・bootCompleted
  (booted=true のみ確定、他は getprop 再確認)・難治型 reboot の adb 不達時 RESET・
  drag・press のタッチ合成(AndroidDriver)
- adb 残存(原理的に置き換え不可): ブリッジ到達の `adb forward`+localhost HTTP・shell 系
  (am/pm/settings/getprop/cmd wifi/dumpsys)・install・pull・実機の全操作
- **キー系は adb keyevent 固定**(home/back/appSwitcher/pressEnter)。gRPC のキー注入は
  DS-16.3 のとおり届かない(2026-07-25 の PoC が測ったのは送出 1.2ms vs 215ms = 往復の速さで、
  効いたかではない)

### DS-16.3 罠(実測で確定・変更時に踏み直さないこと)

- **キー注入(sendKey)は guest に入力デバイスがあるキーしか届かない。無いキーは RPC だけ成功して
  黙って捨てられる**(2026-08-19。emulator 36.5.10 / API 36 arm64 の 2 AVD で確認: 名前付きキー
  "GoHome"/"AppSwitch" は成功を返すのに前面が変わらず、`adb shell input keyevent` なら戻る。
  送出中の `getevent` は1イベントも受けず、guest の入力デバイスは **gpio-keys と
  virtio_input_multi_touch だけ**でキーボードが無い)。**キー系は adb keyevent 固定**にしてある
  (`AndroidDriver` の home/back/appSwitcher/pressEnter。名前付きキーの API は両層とも置いていない)。
  gpio-keys に載る **KEY_POWER(116)/KEY_SLEEP(142)** だけは届くので sleep-wake 修復は gRPC のまま。
  KEY_WAKEUP(143) の不発(2026-07-25 実測)も同じ機序。sleep は KEY_SLEEP(非トグル)→直後の
  POWER トグルは安全
- **blank 判定に gRPC PNG のサイズ閾値を使わない**(emulator エンコーダは一様黒でも 51KB。
  30KB 閾値は adb 較正)。gRPC 経路は ImageIO デコード+`uniformFrame` の画素一様判定
- **grpc-swift は約10MB の単一メッセージ受信で接続切断される**(RGBA 直取り不可。PNG で受けて
  ホスト側デコードにしている理由)
- grpc-swift v2 の正リポジトリは **grpc/grpc-swift-2.git**(grpc-swift.git の 2.x タグは旧系)

### DS-16.4 iOS 側の相当実装: simctl→CoreSimulator 直叩き

iOS には emulator gRPC に相当する公開 RPC が無いため、同型の勝ち筋は **simctl のプロセス起動固定費の
排除**。`FTCoreSimShim`(ObjC・dlopen+objc_msgSend、fleetest-simstream と同作法)が
CoreSimulator.framework を直接叩き、`SimulatorCatalog.devices()` が直叩き優先・simctl フォールバックで
振り分ける。殺しスイッチ **`FT_SIMULATOR_CONTROL=simctl`**。

- 実測(シミュレータ 210 台): 列挙 6ms vs simctl 567ms(92倍)・全台 state 読み 0.03ms。
  初期化(dlopen+SimServiceContext)は初回のみ ~470ms=常駐(monitor)で償却
- 保持する deviceSet ハンドルは boot/shutdown に live 追従(再初期化不要)
- セレクタ欠落(Xcode 版差)は列挙ごと nil → simctl へ(部分的な混在結果を返さない)。
  等価性は UDID/booted 集合の完全一致を live テストで担保
  (Tests/FTBridgeClientTests/SimulatorCatalogCoreSimTests.swift、FT_LIVE_SIM=1)
- ステップ実行(tap ~490ms)は XCUITest ブリッジ内部コストでこの施策の対象外。
  HID 注入バイパスは評価済み不採用(backboardd クラッシュ)・再提案しない

**適用範囲は列挙だけではない**(2026-08-02 拡張)。シナリオ毎に1回走る simctl 往復2つも
同じ作法で置き換えた(`CoreSimAppControl` が振り分け。殺しスイッチは同じ `FT_SIMULATOR_CONTROL=simctl`):

| 置き換え | 旧 | 新(CoreSimulator) |
|---|---|---|
| アプリ起動 | `simctl launch --terminate-running-process` | `launchApplicationWithID:options:error:` |
| 未インストール検査 | `simctl get_app_container` | `applicationIsInstalled:type:error:` |

- **launch の環境変数は接頭辞が違う**。simctl は `SIMCTL_CHILD_` を剥がして子へ渡すが、
  CoreSimulator の `options["environment"]` は**接頭辞なし**で渡す。剥がし忘れると
  in-app の dylib が注入されずブリッジが上がらない(`InAppLauncher` は接頭辞なしで持ち、
  simctl フォールバック側だけ前置する)
- **未インストールの断定は `NSPOSIXErrorDomain` code 3 のときだけ**。この API は
  「入っていない」も「判定できない」も `NO` を返すので、他のエラーは nil = 判定不能にして
  simctl の判定へ委ねる(誤って `appNotInstalled` で run を止めない側へ倒す)
- **律速は初期化に移った**。CoreSimulator の初期化は**プロセスごとに約 384ms**で、以降は 0〜1ms。
  **シナリオ1本=1プロセス**なので、最初に触った呼び出しが必ずこれを被る(性能の内訳と
  暖機を不採用にした理由は PT-3.12)
