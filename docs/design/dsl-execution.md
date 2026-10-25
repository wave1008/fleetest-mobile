# 設計: Swift DSL の実行・失敗時の情報・自己修復

| 種別 | 範囲 | 読む場面 | 扱わないこと |
|---|---|---|---|
| 正典 | 失敗時に返す情報・描画崩壊の検査・割り込みハンドラ・実行アーキテクチャ・自己修復・ロケータの指紋(DS-10 の後半)と、テストベースからの下書き(DS-17) | DSL の実行や失敗の報告を変える前 | 記述と語彙(→ [dsl-syntax.md](dsl-syntax.md)) |

DS-10 の前半は dsl-syntax.md。

## Swift DSL の実行・失敗時の情報・自己修復(DS-10 の続き)

### 失敗時に返す情報

- **解決失敗のメッセージに「近い候補」を最大3件**添える(`LocatorResolver.candidateHint`。
  id/ラベルの近さ(`FTCore.SimilarLabels`。強い一致 > 操作可能 > 文書順)→ 同型の順)。
  直すための snapshot 取り直しを1往復減らす
- **レポートに失敗時点の要素一覧**を折りたたみで載せる(`SceneRecordData.failureElements`)。
  スクリーンショットからは `#id` を読めないため、機械が直すための一次情報はこちら
- **「`checkIsOFF` で通ったが checked を一度も観測できなかったセレクタ」を run 終了時に警告**する。
  ブリッジは checked を**true のときだけ送る**ので、状態を持たない要素
  (ただのボタン等)や状態を報告しない実装(**iOS の SwiftUI / Flutter の checkbox**)を指すと
  `checkIsOFF` は**何を書いても成功する**。notExist の id typo と同じ構造の穴なので同じ扱いにする
  (一度でも checked を観測できたセレクタは警告しない = 正しい使い方を潰さない)
- **`scene` 番号の重複を警告**する。番号は利用者が手で振るのでコピペで重複しやすく、
  レポートに同じ番号が並ぶとどちらの結果か読み手が判別できない。
  **失敗にはしない**(番号は実行順にも結果にも影響しないため、既存シナリオを止めない)
- **「否定側でしか使われず一度も解決できなかった `#id`」を run 終了時に警告**する
  (`FTDriveCore.warnAboutNeverResolvedIDs`)。`notExist` / `countIs(x, 0)` は id の綴り誤りでも
  成功するため、構文検証では捕まらないこの穴の最後の砦
- **`ifCanSelect` の不成立は `.skipped` で記録**し、最後まで不成立だった分岐は同じく警告に出す
  (`.passed` にすると「セレクタが腐って毎回飛んでいる」状態が緑のまま見えなくなる)
- **台帳に無い `#id` を dry-run で警告**する(`SelectorInventory`)。セレクタの綴り誤り・
  でっち上げは構文検証を通り、デバイス実行で初めて「見つからない」になるため。MCP の `ft_snapshot` が
  撮った id を `<プロジェクト>/.fleetest/selector-inventory.json` に**和集合で**貯め、dry-run が突き合わせる。
  誤検知を出さない側に倒す設計: **台帳が無い/そのプラットフォームの記録が無いなら黙る**(「知らない」を
  「間違い」と言わない)・**台帳が薄いうちも黙る**(そのシナリオが触る id の **2/3 以上が台帳に在るとき
  だけ**警告する。有無だけで判定すると、1画面撮った状態で既存シナリオを回して **44/47 が誤警告**した
  —— 単体テストと『台帳が空なら黙る』の検証は両方緑のまま)・
  **完全一致の id だけ**(ワイルドカードとラベルは対象外。ラベルは文言変更で
  普通に変わるので警告にすると必ずオオカミ少年になる)・**古い id を消さない**(消すと警告が増える方向)。
  **書き手は `ft_snapshot` だけ**で、実行(run)の hot path では書かない(スナップショット毎の
  ファイル I/O を実行時間に載せない)。**照合も dry-run 専用**(実行では解決の成否そのものが答え)
- **アサーションが0個の `expectation` を警告**する(`FTDriveCore.runSection` /
  `warnAboutMissingAssertions`)。「`action` に全部書いて `expectation` は `tap` だけ」
  「`exist` のつもりで `select`」はコンパイルも実行も通り、**アプリがどう壊れても緑**になる
  (`verify` の inconclusive と同じ穴を CAE 側にも塞ぐ)。シナリオ全体で0本ならさらに強い提案を出す。
  **数える定義は `FTDriveCore.noteAssertion` 1箇所**(`verify` と共有。定義が割れると片方だけ誤検知する)。
  `appIs` は `FlowStep` を持たない唯一の検証コマンドなので `performCustom(isAssertion:)` で合流させる。
  **`ios`/`android`/`ifCanSelect`/`repeatWhileCanSelect` の本体を実行しなかったときは黙る**
  (`noteUnexecutedBlock`。中身は実行しないと分からないので誤検知を出さない側に倒す ——
  `expectation { android { notExist(…) } }` を iOS で回す形が実際にある)。
  **デバイス不要**(`api run --dry-run` / `ft_dry_run` で判定できる = デバイス実行の前に落とせる)
- **アプリより手前にある別プロセスの window を失敗時に添える**(Android のみ)。
  `AndroidForegroundWindows` が `dumpsys window windows` を z 順に読み、アプリの window より
  手前で `isVisible=true` かつ別パッケージのものを返す。**アプリの a11y ツリーには他プロセスの
  window が出ない**ため、覆われていても要素一覧は正常に見え、`tap` は成功扱いで返る
  (docs/verification/triage.md「操作は ✅ なのに画面が変わらないとき」)。
  常時可視の装飾(StatusBar / Taskbar / NavigationBar / 画面装飾)とアプリ自身の別 window は
  除外し、アプリの window を特定できないときは黙る(誤った断定をしない)。
  配線は `FTScenarioRunner` からの closure 注入(FTDSL は FTAndroid に依存しないため)
- **割り込み(`irregularHandler`)は1ステップで最大10回まで閉じる**(
  既定値で、`irregularHandler(…, maxDismissals:)` で宣言ごとに変えられる)。
  長いステップの最中に**2度目の配信**が湧くと、1回きりでは閉じ切れず待ち続けたまま失敗する
  (配信基盤が出す側なのでアプリでは止められない)。上限を残すのは**閉じても
  消えない相手に無限に付き合わない**ため。加えて**同じ検出が2回閉じても残っていたら打ち切る**
  (1回目で切らないのは、閉じるアニメーションの最中に撮った木で早合点しないため)。
  打ち切ったときは注記に `the interruption is still on screen after being dismissed` を出す ——
  黙って諦めると「割り込みのせいで落ちた」ことが読めない
- **対象を覆っているアプリ内要素を失敗メッセージに添える**(`StepExecutor.coveringHint`)。
  アプリ内メッセージ・モーダルは**同一プロセスなので上の別 window 検出では捕まらない**。
  判定は `OcclusionSuspicion.covering`(ツリーのみの幾何。FM もスクショも不要 = FM が落ちていても効く)。
  **過検出寄りなので判定は変えず文言を足すだけ**にする(ステップの成否には触らない)
- **「手前かどうか」は `PaintOrder` の1箇所で決める**(MCP の `RefGuard` と共有)。
  ツリーの並び順は描画順ではない —— Google マップは地図の chrome をシートより**後**に出すのに
  描画はシートが手前で、ツリー順の近似では**シートの裏に潜った chrome を1件も拾えなかった**。
  ブリッジが `ElementInfo.z` を申告する木(Android)では本物の塗り順、持たない木(iOS)では
  従来どおりツリー順へ落ちる。実測(固定コーパスの Android 5画面): 疑いの総数 153→108(−29%)・
  塗り順に起因する見逃し 8→0。**疑いが減ることには実利がある** —— `geometric` は FM を呼ぶかの
  前段で、FM は許可枠で制限される共有資源だから(PT-3.5)
- **撃つ前に言える「たぶん何も起きない」は注記にする**(`TapTargetGeometry`。
  MCP と共有)。3形とも実測由来: **無効な要素**(木には `disabled` と印字しているのに操作経路が
  `enabled` を見ていなかった)/ **中心が中身のどこにも乗らない容器**(`#layers_fab_button` を
  叩くと中心が地図の上なので海上にピンが落ちた)/ **中心が画面の外**(
  Compose iOS はスクロールで縁の外へ出た行を frame ごと木に残し、`#slot_07`(中心 y=-18)への
  ref タップが無警告の "done" で 1px も動かなかった。ウィンドウ外のタッチは hitTest に乗らず
  黙って落ちる。縁の丸め誤差(実測 0.3pt)を拾わないよう猶予 2pt を置く)。
  **失敗にはしない** —— 無効な要素をわざと叩いて反応しないことを確かめる書き方は正当で
  `enabledIsFalse` もある。注記なら後段の失敗から原因へ辿れる。
  座標に依る警告は MCP(`RefGuard.overlapWarning`)と同じ優先順の1チェーン
  `TapTargetGeometry.occlusionAdvisory` に集約し、強い事実から**最初の1件だけ**言う:
  zero-frame → 画面外 → 申告 scroller 外の残像 → 中心を覆う最前面
  (`OcclusionGeometry.overlayCovering`)→ 中身外し → 内側の別アクション → クランプ残骸
  (`stackedRefs`)→ 容器の縁で切り詰め(`clippedByContainer`)→ 細帯(sliver)。
  **関数は分けてある**: `keyboardCoveredAdvisory`/`disabledAdvisory` は
  **撃つ座標に依らない**のでどの経路でも言えるが、チェーンの残りは
  **frame の中心を撃つときにしか言えない** ——
  `visibleTapRect` が見えている部分へ寄せる経路では「背後へ抜けた」が嘘になる。
  載せる経路は tap(寄せない側)・長押し(`press(ref:)` は frame 中心)・doubleTap の3つで、
  **pinch / swipeBy は対象外**(掴んで動かす形なので無効でも意味がある)
- **縁の帯に潜っているだけなら、撃つ前に容器を1回送って外す**(
  `TapTargetGeometry.uncoverScrollJump` が唯一の判定元。**ソフトキーボードだけは
  `uncoverKeyboardScrollJump` / `keyboardUncoverDragArea`**—— キーボードは常に下の帯なので、下の
  「容器の半分以上」「中心線を跨ぐ」を当てない(背の低い容器ではキーボードが両方に当たり、送れば外れるのに送らなかった)。利用者向けの説明は
  docs/commands.md §縁の帯に潜った対象)。実アプリで頻出する形で、受け手の SUT では
  4.7 インチ実機でログアウトがタブバーに潜り、タップがタブに当たって7本が巻き添えで
  落ちた(D-02)。**外せないと分かる3形では送らない**(操作可能でない覆い・容器の半分以上を
  占める覆い・容器の中心線を跨ぐ覆い)。**拒否はしない** —— 覆われた要素をわざと叩く
  書き方を壊さない。実装で得た知見が2つ:
  **①「覆いが対象の上か下か」では向きが決まらない**(中心を覆っている以上、覆いの矩形は
  必ず対象の中心を含む)。**②「容器の縁に接しているか」でも決まらない** —— タブバーの下端は
  セーフエリアぶん内側で、内容を潜らせた容器の下端と揃わない(実測: 帯 778..840 / 容器 200..873)。
  採ったのは**容器の中心線のどちら側にあるか**。
  witness は `E2E-iOS/scenarios/17_縁の帯に潜る.swift`(`#btn_under_footer`)で、
  **効くのは xcuitest だけ** —— in-app ブリッジは要素を直接活性化するので座標のヒットテストを
  通らず、機能を殺しても緑のままになる
- **「この木は画面を代表しているか」も MCP と共有する**(`TreeCoverage`)。
  形は2つで、どちらも**幾何からしか疑えない**(打ち切りと違いブリッジの申告が無い):
  **①webView の内側に大きな空白帯が残る**(Android の Chrome は web コンテンツの a11y ノードを
  部分的にしか公開しない。同じ URL を iOS Safari で読むと全部出るのに、画面に描かれている表が
  フルツリーにも1つも無い)/ **②アドレス欄はあるのに webView 容器すら無い**(Chromium は
  a11y を要求するサービスが繋がってから木を作るので、その窓で撮ると chrome だけが返る。
  実測でブリッジ起動直後 19 要素 → 5 秒後 135 要素)。
  閾値は固定コーパスの実測から置いた(①容器比 8% + 画面比 5%。取りこぼしのある Chrome の1枚が
  容器の 13.6%、健全な iOS Safari の3枚が 0〜3.3% / ②空白率 0.5。witness が 0.886、
  健全なブラウザ画面が 0.059)。
  **DSL 側は注記だけで判定を変えない**(`StepNote.treeUnderreported`)—— 幾何からの疑いで
  断定すると、空のページに対する正当な `notExist` が書けなくなる。
  **同型が `DuplicateRegion`**(横スクロールで前後のコピーが両方 木に残る形。片方は描かれて
  いないので撃つと別物に当たる)。`hasClampedCoordinates` は**同一 frame**を要求するので、
  x だけずれるこの形では発火し得ず、流用できない。DSL の tap は `StepNote.staleDuplicateRegion`。
  毎ステップ O(n²) を払わないよう `riskFor` に**掴んだ要素の相方を探す O(n) の門**を先に置く
  (門は必要条件でしかないので、通ったら必ず `find` で確かめる)
- **「誰が覆っているか」は最前面を名指しする**(`OcclusionGeometry.occluder`
  [実体。`RefGuard` は転送]と DSL `OcclusionSuspicion.covering` の両方)。配列順で最初を返すと
  中間層(包んでいるシート)を名指しし、**実際にタップを受け取る最前面**を素通しする。実データでは
  `#place_page_tabs_container` ではなく**タップを受け取った広告行**が答えになった。
  **掃討ゲートは件数しか見ない**ので、この種の変更は明細(`FT_SWEEP_BASELINE=1`)で1件ずつ確かめる
- **occlusion-guard は絵の鮮度を確かめてから FM を呼ぶ**(`StaleFrameDetector`。MCP の
  ft_screenshot と同じ判定を共有)。「木は変わったのに絵が前回とバイト同一 = 凍結した古いフレーム」
  なら1回だけ撮り直し、なお stale なら**誤った緑への反転を宣言せず素通り**する(`StepNote.staleScreenshot`)。
  **待ちのループを持つ検証(exists・テキスト比較)は、古い間は素通りせずに待って撮り直し、追いついた絵で判定する**
  (締め切りまで古いままだった回だけ素通り。「見えない」の判定と同じループ = 整定してから判定)。**古いと判定した絵と
  バイト同一の絵は次のステップでも古い**(`StaleFrameDetector.isKnownStale`。`judge` は記録を新しい木へ更新するので、
  これが無いと 2 ステップ目は同じ古い絵を古いと言えず、その絵で判定して赤にする)。ループの無い select は素通りのまま。
  **判定は新規撮影のときだけ**(`guardScreenshot` の 200ms キャッシュ供給は同一 Data を返すため、
  比較すると木の揺れで必ず偽 stale になる)。`FrozenVerdict` には接続しない(凍結判定の定義元は
  あちらのまま。これはスクショ経路のローカルな鮮度確認)。**絵が下端の帯(ホームインジケータ /
  ナビゲーションハンドル)を除いて真っ黒なら判定の根拠にせず素通り**する(`StepNote.blankScreenshot`・
  `BlankFrameDetector.isBlackApartFromBottomStrip`)。FM も OCR も黒い絵には「描かれていない」と答えるので、
  撮れていない絵・固まった表示が赤になる。凍結の確定(回復を撃つ `uniformBlank`)には使わない
- **pressEnter は焦点の合図を待ってから撃つ**(`FocusWait` を MCP `awaitFocus` と共有)。
  木のどこかの `focused` 申告か `keyboardShown` を合図に最大 1.5s。合図が無ければ警告注記+実行
  (拒否しない)。keyboardShown を第二の合図に持つのは Compose iOS(in-app は UIResponder でない
  要素の focused を申告しない)対策
- **type は「200 = 入った」を信じない**(`AppDriver.verifiesTypedText`)。xcuitest ランナーと
  Android 注入器は内部で読み返すので true、in-app は false で `StepExecutor.verifyTypedText` が
  ホスト側で読み返す(期待値 = 撃つ前の値 + 入力・前方一致は追送・超過は clearInput + 全文打ち直し・
  マスク欄は検証不能として受理・停滞は**失敗**)。値そのものは失敗文言に出さない。
  ラッパードライバは実行側の値へ転送する(既定 false は安全側だが二重読み返しの固定費が乗る)
- **run の開始前に「画面だけ死んだ」仮想デバイスを弾く**(`BlankWorkerTriage`)。
  Android は `ProfileWorkerFactory.excludeOrRepairBlankScreenWorkers` が同じ位置で**修復まで**行うが、
  **iOS には軽い修復手段が無い**(確認できているのは `simctl shutdown`→`boot` だけ)ので、
  `recover:` に注入した `ProfileWorkerFactory.recoverFrozenIOSWorkers`(そのデバイスのブリッジを先に止めてから
  `simctl shutdown` → `SimulatorBoot.ensureBooted`・2 台ずつ・`recoveryAttempts` = 2)で**全機が戻るまで開始しない**
  (ユーザー指示 2026-08-09。弾くだけだと凍結が多発した run はレーンが半分で走る)。戻らない個体だけレーンから外し、
  復旧コマンドをログに出す。**iOS(BlankWorkerTriage)**の判定は恒常 blank
  (2.5s 間隔で5連続。約10秒の観測窓)に加え、一様が続いた機だけ画面を必ず変える入力を送る
  能動プローブ(`nudge`)で仕分ける ——「描画要求が無いだけの黒画面」(入力で戻る)と
  「本物の wedge」(戻らない)は受動観測では原理的に区別できない(拍動では
  分けられない)。**Android 側は 1.5s×2 の恒常 blank のみで nudge を持たない**
  (`AndroidHealthProbe.isPersistentlyBlank`。修復手段が sleep/wake で軽いぶん短い窓のまま。
  iOS と同じ窓+nudge へ揃えるかは未判断)。
  健全機は1サンプルで返る = 正常時の固定費はスクショ1枚。
  **実機は両 OS とも対象だが、判定を確定させない**。実機は**消灯が同じ絵を出す**
  うえ、画面を変える入力は端末の状態を変えるので `nudge` を撃てない = 消灯と wedge を分ける
  材料が無い。そこで根拠を別ケース `FrozenEvidence.darkScreenPhysical`(`isConclusive=false`)へ
  写し、**警告だけ出して除外も回復も撃たない**。写す場所は
  `FrozenVerdict.observe(uniformBlank:injected:physical:)` の1箇所で、run 前トリアージと
  モニターが同じ規則を通る —— 片側にしか写しが無いと、**消灯しているだけの実機が
  タイルで ❄️ になる**。
  **実測で確認済み(2026-09-25)**: Dozing の Pixel 4a の `screencap` は
  `BlankFrameDetector.isUniformBlank = true`(15KB)で、写しを外した対照では
  `api monitor` が3周目に `frozen=true` を出し、写しありでは3周とも false。
  **同じ消灯でも Pixel 3a は一様でない**(AOD で 54KB・`isUniformBlank=false`)ので、
  **機種で出方が変わる** —— 「実機なら必ず出る/出ない」と書かないこと。
  **「消灯ではない」と言える材料は Android にはある**。`dumpsys power` の
  `mWakefulness=Awake` を `AndroidPhysicalDevice.reportedAwake` が引き、**起きていると申告して
  いるのに一様**なら `.awakeButBlankPhysical` になる。**読めなければ nil = 消灯側へ倒す**
  (true に丸めると消灯した端末へ修復を撃つ)。**iOS 実機にはこの材料が無い**
  (点灯状態を取る手段が無く、消灯中はブリッジが応答せず絵も撮れない)ので
  `.darkScreenPhysical` のまま = 観測だけ。
  **`.awakeButBlankPhysical` もまだ確定させない**(警告から入れる規律)。代わりに
  **無害な修復だけは疑いの段階で撃つ** —— 画面の sleep/wake(`AndroidPhysicalDevice.cycleScreen`)を
  1回。**実機に再起動は撃たない**(持ち主の端末であり、iOS 実機では既知のウェッジに
  `devicectl reboot` が効かない実測もある)。戻ったかは**こちらの観測器で判定し直す**
  (修復側の戻り値を信じない = あちらの再判定はエミュレータ較正の閾値)。戻らなくても
  **レーンからは外さない**。材料と修復は `PhysicalScreenProbes` に括って run / api run の
  両経路へ同じものを渡す(`PhysicalDarkScreenWiringTests` が固定)
  **仮想デバイスの「下端の帯を除いて黒いまま」も警告だけの根拠**(`.blackApartFromBottomStrip`)。
  表示が凍結した Android Emulator はナビゲーションハンドルが残って一様判定(iOS の `isUniformBlank` も
  Android の全画素の幅も)を割り、run 前トリアージもモニターも素通りするため。同じスクショから一様と
  下端を除く黒の両方を取り(`FrameBlankness`)、窓の判定は `PersistentBlank.fold` の1箇所(iOS の
  `BlankWorkerTriage.persistentBlank` と Android の `AndroidHealthProbe.persistentBlank` が共有)。
  **nudge も修復も撃たず、レーンにも残す**(描画要求が無いだけの黒画面と分けていない)。
  **モニターには出ない**(`frozen` は確定だけ。警告の根拠を配る欄は無い)。実行中の失敗後の判定
  (`isBlankObserved`)は確定の経路なので変えていない
- **run の途中で「表示が止まった」仮想デバイスを見つけて再起動する**(`FTAndroid.DisplayFreezeWatch`・
  判定は `FTCore.DisplayFreezeDetector`・配線は `ProfileRunOrchestrator` → `RunOrchestrator.checkLaneDisplay`)。
  一様(白/黒ベタ)でない凍結がある —— 表示の止まった Android Emulator はブリッジの `UiAutomation.takeScreenshot` に
  **数分前の絵を返し続け**(同時刻の adb screencap は黒)、分類器・findImage・可視性検証が別の画面の絵で誤判定する
  (run 前トリアージの一様判定・下端を除く黒の警告は素通り)。絵の中身では見分けられないので
  **時間で見る**: レーンがシナリオの境目で撮った絵を前回の境目と比べ、**同じバイト列が 60 秒以上離れて返ったら疑い**
  (**前回の境目は run をまたいで引き継ぐ** = `.fleetest/display-freeze/<serial|udid>.json`。run ごとの控えだけだと、レーンあたり 1〜2 本の
  run が続く間は同じ run の中で 60 秒離れた境目を2回迎えず、凍結を一度も疑えない。MN-89)
  (生きた表示はステータスバーの時計が 1 分に 1 回変わる = 60 秒以上離れた 2 枚が同一になることは無い。時計を隠す
  全画面のアプリだけが例外)。疑いだけでは触らず、**home を押して絵が変わるかで確定する**(run 前トリアージの nudge と
  同じ「描画要求が無いだけ」との区別。変われば健全・変わらなければ凍結。**home を撃てなかったら判定しない** = 撃てていないのに
  「変わらなかった」と読まない。凍結でなければ確認の後に SUT を前面へ戻す)。撮る経路は Android = ブリッジ(古い絵を返すのはこちら)・
  iOS Simulator = OS の `simctl io screenshot`(in-app の撮影は SUT の中なので、home で背面に回ると撮れない)。確定したレーンは `.frozen` と同じ扱い ——
  **直前のシナリオの結果は合否を問わず捨てて振り直す**(その画像判定は止まった絵で下されている。振り直しの上限で捨てられない成功は
  記録を失敗へ書き換える = `RunRecorder.markLastFailed`。読み手への終了イベントは確認まで保留し、凍結なら失敗として流す)・
  録画の合否も確認の後に決める・レーンを離脱・回復してから revive で張り直す。対象外(notApplicable)のシナリオの後は確かめない。
  確認の後に前面へ戻すのはそのシナリオが使ったアプリ(子と同じ `ScenarioAppResolution` で解く)。
  **モニター(run の外)は警告だけ**(`MonitorStaleFrameTracker`: 同じ絵が 60 秒以上で stderr に 1 行・絵が変われば解けた旨を 1 行)。
  モニターはデバイスを触らず、`frozen` の欄は確定だけなのでタイルには出さない。Android のモニターは adb で撮るので、止まった表示は黒 = 既存の一様判定が拾う回復の順: Emulator = sleep/wake(ブリッジの絵で確かめる)→ ゲストの再起動
  (`adb reboot`)→ ブートを確認できなければ停止と起動 / Simulator = shutdown → boot。再起動の後は絵で確かめない
  (ブリッジが居ない)= 次の境目の撮影が新しい基準。**実機は見ない**(無害な nudge も再起動も無い)。撮れない
  (10 秒)ときは判定しない。固定費は境目ごとにスクショ 1 枚(Emulator 数十 ms・XCUITest 数百 ms)。run.json には
  `requeued`/`degraded`(cause `frozen`)と `recovered`(recovery `displaySleepWake` / `deviceRestart`)が対で載る。
  陽性対照は `FT_FAKE_FROZEN_FRAME_KEYS=<serial|udid,…>`(そのデバイスの撮影を固定の絵に差し替える = 検知も確認も同じ絵。
  **回復まで本当に撃つ**ので保守者の自分のデバイスでだけ使う)。
  プロセス内の `StaleFrameDetector`(上)はこの用途には使えない —— 2 週間の結果で `stale-screenshot` は通ったステップに
  約 1.4 万回立っており(木の更新と描画の間の揺れを拾う設計)、デバイスを触る根拠にはならない
- **容器の推測に依存する補正は3層で止められる**(上位から `FT_CONTAINER_INFERENCE=off` の殺しスイッチ /
  実行プロファイルの `containerInference` / DSL の `tap(containerInference:)`・`withoutContainerInference { }`。
  実装は `StepExecutor.execute` 冒頭の `Self.containerInferenceEnabled && (step.containerInference ?? 既定)` 1式)。
  容器は木からの**推測**なので想定外のツリーでは外れ得る。外れたときに起きるのは
  「別の場所を叩く」「明後日の方向へ送る」「正当な要素が候補から消える」= **より悪い事態**なので、
  推測の入口(`clippingContainer`)と `hasClampedCoordinates` の2箇所だけでフラグを見て
  まとめて無効化できるようにしてある。**見えている部分を撃つ補正には床(8pt/dp)**もあり、
  わずかな重なりへは突っ込まない。**床は木の単位へ換算してから比べる**:
  iOS の木は pt・Android の木は px なので、そのまま当てると3倍密度で床が約3倍緩み、
  この床が防ぐはずの誤タップ(沈黙する)が素通りする。倍率は `AppDriver.pointScale`
  (iOS=1 / Android=`wm density`。**ラッパーは透過必須** ——
  `SnapshotCacheBypassForwardingTests` が全ラッパーで見張る)。
  pt(1/163 inch)と dp(1/160 inch)は物理的にほぼ同じなので、pt で測った床は dp として通用する
- **座標が壊れている要素は解決候補にしない**(`ContainerGeometry.hasClampedCoordinates`)。
  フレームワークは**容器の可視域を外れた子孫の frame の原点を容器の原点へクランプする**ため、
  掴むと `tap` が別の要素へ落ち(可視性ガードを通らないので沈黙)、`exist` は画面外なのに真を返す
  (「exist は非スクロール」の契約に反する)。判定は**症状ではなく機構**で書く
  (同一 frame・同 depth が3つ以上 かつ 原点を貸す上位要素が居て 群がそれより小さい)。
  消したときは `clampedStackHint` が理由と回避策(先にスクロール)を失敗文言へ添える。
  規則の根拠と実採取は docs/verification/constraints.md「画面外要素の frame は信用できない」
- **飲まれたタップを失敗メッセージで名指しする**(`StepExecutor.tapDiagnosisHint`)。
  タップには事後検証が無く(何が起きるべきかをホストは知らない)、飲まれると落ちるのは
  2ステップ先の検証なので原因が遠い。**タップ直前に解決で使った木**を覚えておき、
  失敗した検証が既に持っている木と突き合わせて、1ピクセルも変わっていなければ注記を足す。
  **追加のスナップショットを撮らないことが設計要件**(実行中に I/O を足すと事象が消える。
  docs/verification/ の heisenbug)。判定は変えず注記のみ。
  記録は `select` では消さない(`tap → select → textIs` が失敗の定型)。
  機構・署名の作り方・誤検知の向きは docs/verification/triage.md「操作は ✅ なのに画面が変わらないとき」

- **スクロール残像(ghost)は拒否せず、警告して撃つ**(`RefGuard.ghostWarning`)。Compose iOS は容器の外へ出た行をフルフレームで木に残し、`ios-xcuitest` はそれを座標で叩く
  (実測: 下部タブへ遷移して "tap done" を返した。`ios-inapp` は要素起動なので当たる = モードで割れる)。**応答に「何に当たったかもしれないか」を添え**、一覧の行にも
  `⚠️scroll-leftover` を出す(`MCPServer.ghostNote` / `ghostFlags`。先頭の注記だけでは、行から ref をコピーする動作に届かない)。
  - **印は2種類に割る**: `⚠️scroll-leftover` は「撃つと別の物に当たる」(沈黙した誤操作)、`⚠️offscreen` は「今そこに無い」だけ。**割る基準は打ち手ではなく危険度** ——
    どちらも対処は `ft_scroll_to` で出し直すことだが、同じ重さで並べると本物の残骸が埋もれる(実測: Apple マップの経路詳細で、`y=-59` の行まで「別の物に当たるかも」と警告された)。
    判定は `TapTargetGeometry.offscreenAdvisory`(中心が画面の外)で、**画面外を先に見る**(`RefGuard.preTapWarnings` の優先順位と同じ。同じ要素について**ツールごとに言うことが変わらない**ため)。
    `⚠️offscreen` の一覧注記は方向まで言う(`MCPServer.offscreenDirection`): 中心のはみ出し量が大きい軸で方向グループに分け、`ft_scroll_to` の `direction:` へそのまま渡せる語(down/up/right/left)を添える。
    左右方向の offscreen があり、かつ画面に `pageIndicator` が居るときだけ、横ページャが1ページずつしか描画しないこと・`ft_scroll_to` で届くことを1文添える(`ghostNote` の `pageIndicatorHint`)
  - **当てる相手**は `OcclusionGeometry.occluder`(中心を覆う別要素。実体は FTCore で DSL のタップ前警告と共有・`RefGuard` は転送)。**遮蔽と数えないものが7つ**ある(外すと起きることはすべて実報告):
    ① 相手自身が ghost(描かれていないものは何も覆えない。設定アプリの「閉じる」が画面外のリスト行に弾かれる)/
    ② 何も描いていない葉コンテナ(label も value も子も無い `other`。起動直後の「スキップ」が全幅・非 clickable の `#compass_container` に弾かれる)/
    ③ 自分を丸ごと包む**画面規模の**相手(全画面の暗幕・toolbar は遮蔽でなく容器)/ ④ 自分の祖先と子孫(「自分より深いものだけ」に絞ると残像に重なる下部タブ(浅い)を見落とす)/
    ⑤ **奥に描かれている相手**(`drawnAbove`。Apple マップの `#MapsSearchBar` が中の `#userProfileButton` を覆う扱いになる)/
    ⑥ **矩形がぴったり同じ相手**(同寸同位置はラッパーか入れ替わり。本物の積み重なりは `stackedRefs` が見る)/
    ⑦ **いちばん内側の入れ物より外の枠**(`enclosesAnInnerWrapper`。z が無いブリッジだけ。`#HomeView` が `#MapsSearchTextField` を覆う扱いになる)。
    **⑤の「奥/手前」はブリッジの申告(`ElementInfo.z`)が最優先で、無ければツリー順へ落ちる**。ツリー順は production で裏返る(Google マップは地図の chrome をシートより後に出すのに描画はシートが手前で、
    シートの裏の `#mylocation_button` を無警告でタップして Chrome が起動した)。Android は `getDrawingOrder()` を根から積んで `SnapshotBuilder.assignPaintOrder` が通し番号にして送る
    (段ごとの値ではホストで合成できない —— 出力ツリーは中間ノードを間引くので共通祖先が残っていない)。iOS は描画順を読む API が無いのでツリー順のままで、⑦の推測が要る。
    **z があるときは⑥⑦を使わない**(真値がある場に当て推量を混ぜると真値を打ち消す)。
    **①を③より先に見る**(③の包含判定は 1pt の差で外れるほど際どい: 閉じる `y483..521` 対 残像 `y484..536`)。本物の遮蔽は一部しか重ならないことが多い。
    **③に「画面規模」の条件が付くのは、包含を無条件に容器と読むと逆側へ倒れるから**: app bar の下へ潜り込んだ行はまさに「丸ごと包まれる」形で、除外するとタップしても何も起きないのに警告も出ない。
    面積が画面の `fullScreenContainerAreaRatio`(0.5)以上のものだけを容器とみなす(暗幕・全画面 toolbar は 100%、app bar は 12%)。**②と③は表と裏**(②を足すと鳴りすぎが止まり、③を緩めると黙りすぎが止まる)
    なので、片方だけ動かすと残る側が悪化する
  - **これでも誤検知は残る**。木の幾何だけでは「実際に描かれているか」を決められない(最後に出たのはキーボードの下にある普通の行。キーボードはスナップショットから丸ごと除外していて frame すら取れない)。
    だから**拒否ではなく警告**にしてある。**ここを再びブロックへ戻さない**。教訓: `isOutsideContainer` は DSL では「掴み直して送り直す」= やり直しの合図で、外れても次の周回で回復する。
    **同じ判定を拒否へ格上げすると、外れがそのまま機能の喪失になる**。強度を変えて再利用するときは、外れたときの損害が同じかを確かめる。
    誤検知5形とも利用者の実アプリで出た(4 SUT 全画面(84画面)の掃討では0件)。同日の実アプリ(Google マップ)でも3種類出たが自前 SUT 掃討は0件 ——
    **この検知系で「自前 SUT の誤検知0」は production を代表しない**。掃討は `Tests/Fixtures/RealAppSnapshots/` の固定コーパス(`SweepHarnessTests`)で実アプリにも当てる
- **容器の中に居ても別の物に当たる2形**(`RefGuard.overlapWarning`)。上の ghost 判定は `isOutsideContainer` を入口条件にするため、この2形を捕まえない:
  ① **上に描かれた overlay に覆われている**(`overlayCovering`): E2E-iOS のホームで `#nav_heal` (16,788 370x62) が下部タブ `#tab_controls` の下で、ref タップがコントロールタブへ遷移して "tap done"。
  `occluder` のうち**木の順序で後ろ**にあるものだけ(先に並ぶ大きな背景パネルを遮蔽と読むと誤検知に逆戻りする)/
  ② **同一矩形に積まれている**(`stackedRefs`): スクロール画面で `行 09`〜`行 40` の staticText 29個が全部 `行 01` の位置にあり、ref タップが `selected=row_01`。同じ矩形を共有するもののうち
  **label か value を持つものが3つ以上**。**入れ子の一本鎖は数えない**(Android のダイアログは `action_bar_root`→…→`custom` が全部同じ矩形)。数えるのを「中身を持つもの」に限るのは、
  件数だけだと普通の木が鳴るため(Android の同一 bounds のラッパー連鎖が可視ボトムシートで積み重なり扱いされた)。
  どちらも**拒否せず警告**。積み重なりは一覧にも `⚠️scroll-leftover` を出す(原因も打ち手も ghost と同じなので**印を2種類に割らない**)。
  **例外はキーボード被覆**(決定: ユーザー 2026-09-14。`MCPServer.keyboardRefusal`): 中心がソフトキーボードの下にある要素への ref 操作(tap / long_press / type / clear / double_tap・batch の1手目)は
  **両ブリッジとも断る**。結果が確実で副作用がある(XCUITest はキーの上に指が落ちて焦点の欄に文字が入り(実機 SE3・`#tab_about` で「o」)、in-app は 422 で断っていた = ブリッジで割れていた)。
  判定は ref 形・DSL と同じ `KeyboardOcclusion`(chrome 除外済み)。**座標形は断らない**(キーを押す意図があり得る。`keyboardCoordinateWarning` で警告)。**DSL の tap は据え置き**(注記)
- **自分の子孫が中心を横取りする形**(`TapTargetGeometry.nestedActionCoveringCentre`)。`occluder` は祖先と子孫を除外する(親子の重なりは正常な入れ子)ので、この形を捕まえない。
  実測(Apple マップの検索候補): `#Maps.PlaceTableViewCell` の中心が同じセル内の `#FeaturedInMultipleGuidesContextLineItem` の内側にあり、ref タップは場所カードでなくガイド一覧を開いて無警告で "done"。
  条件は「親が対話的」「子孫も対話的」「面積比 < `nestedActionAreaRatio`(0.25)」の3つ。比の上限は行を包み直すだけのラッパー(同セル内の無名 button は 0.99)と行の主ラベル
  (`#MultiTextView` は 0.31〜0.49 で、押しても行と同じ場所が開く)を外し、**行の中に別の遷移先を持つ小さな帯**だけを残す値。コーパス全数(18枚)で発火は `#PinnedItemSection` ← `#PinnedTile` の1件だけ(真陽性)。
  非対話の容器は `missesItsOwnContent` の担当なので**排他**(二重に言わない)。警告のみ
- **申告されたスクロール容器の外へ送り出された行**(`TapTargetGeometry.outsideDeclaredScroller`)。ghost 判定は容器を木の並びから**推測**するので、申告のある UIKit/SwiftUI では推測が中間ノードに当たって nil に落ちる。
  実測(Apple マップの場所カード): `#MUScrollableStackView` の上へ抜けた行が frame ごと木に残り、`link "ウィキペディア"` (16,-2 85x18) への ref タップが "done" を返して実際には中心がステータスバーに当たりカードが先頭へ飛んだ。
  こちらは推測せず **`scrollable` を申告している祖先だけ**を見る。**ただし depth からの祖先復元はブリッジの間引きで嘘になる**(Google マップの検索結果で本文10件を誤検知)ので、`clippingContainer` と同じ
  「その depth の兄弟が2つ以上、容器の中に居る」を条件に足す。一覧の印は ghost と同じ `⚠️scroll-leftover`(**印を割らない**)
- **細帯(sliver)の注記**: 幅・高さのどちらかが 10 以下の極端に細いラベル付き要素(実測: 右端で 9x137 に切れたタブ「サンライズ瀬戸」)は掴めないことが多いので `ft_snapshot` が note で名指しする。
  判定は `TapTargetGeometry.isClippedSliver`(ラベル2文字以上 + 細い辺 ≤10 かつ対辺 ≥30。アイコン 9x13 等は対辺条件で除外)。**判定は要素自身の細さだけ**(縁で切れた結果か元々細いかは見ない)
- **ソフトキーボードの遮蔽は木からは原理的に判定できない**。iOS xcuitest は `.keyboard`/`.key` サブツリーを木から除外し、残る外側コンテナ(`inputView`)は子孫ゼロの空葉になって空葉除外(誤検知対策)に正しく弾かれる。
  Android は IME が別プロセスの別ウィンドウで木に出ない。実害は両 OS で実測済み: iOS はキーボード下の候補行への ref タップが顔文字キーに化けて検索欄を汚し、Android は Gboard のレイアウト選択シート下の候補タップが
  IME の「QWERTY」選択に化けた(どちらも無警告)。だから**ブリッジが `SnapshotResponse.keyboardFrame` で実矩形を申告する**:
  iOS xcuitest = 走査中に見た `.keyboard` ノードの frame / iOS in-app = `keyboardWillChangeFrame` 通知の最新値(**TextEffects window の frame を使ってはいけない** —— 開いていても全画面が返り上部の要素まで誤警告する。
  `UIInputSetHostView` のクラス名走査も iOS 27 で不発。通知値が無ければ frame は申告しない = 誤検知側に倒さない)/ Android = `UiAutomation.getWindows()` の TYPE_INPUT_METHOD の bounds
  (要 `FLAG_RETRIEVE_INTERACTIVE_WINDOWS`。ブリッジ起動時に恒久で立てる副作用があり、`getWindows()` は毎 snapshot 叩く = dumpsys と違い a11y 内 API で安い)。
  判定は `TapTargetGeometry.keyboardCoveredAdvisory`(中心が keyboardFrame 内)の1箇所で、DSL はステップ注記・MCP はタップ警告 + `ft_snapshot` / `ft_scroll_to` の note に使う
  (note は覆う矩形を常に申告し、その下に操作対象が居るときだけ ref を列挙する)。**警告のみで拒否しない**(新しい検知は警告から)。旧ブリッジは申告しない = 黙って従来どおり
- **iOS の `keyboardFrame` はキー面だけで、実際に覆う面積より狭い**。`.keyboard` ノードの frame は上のサジェストバー(`SystemInputAssistantView`)と地球儀/Dictate 行を含む `inputView` の下端を含まない
  (実測: iPhone 17 Pro / 402x874 で申告 y=583..816 に対し木の chrome は y=538..874。実機 iPhone 15 Pro でも上45pt・下58pt が欠ける)。中心点判定は正しいのに矩形が狭いせいで隠れた要素を見落とす。
  **中心点判定は変えない**(矩形が1pt重なっただけの入力欄まで警告すると誤検知)—— `FTCore.KeyboardOcclusion` が申告と木の chrome(`inputView`/`SystemInputAssistantView`。**申告と交差するものだけ**)を
  足し込んで実効矩形を作り、MCP/DSL の呼び手(MCPServer+Snapshot / MCPServer+Hints / MCPServer+GesturesTools の ftDoubleTap / StepExecutor+Actions)全員がこの型を通す。
  chrome が木に無ければ申告どおり(Android は既に画面下端まで届いており対象外。ブラウザの WebView 内キーボードも chrome が木に出ないため対象外)。
  **広げるだけでは雑音になる**: キーボード自身の部品(地球儀キー・変換候補バー)まで「隠れている」に該当し、注記は先頭8件しか名指ししないので本命が押し出される。
  chrome 自身とその部分木(木は親→子順+`depth`)は除外する(覆っている側を「覆われている」とは言えない)。実測(`ios-maps_suggest_keyboard`): 16件(見落とし)→ 30件(広げただけ)→ **20件**(除外後)で、
  増分4は本当にキーボードに隠れた5件目の検索結果。**拾い直しが要る**: `SystemInputAssistantView` は申告矩形と縁が接するだけで交差しないので最初の走査に入らない —— 実効矩形で chrome を引き直さないと、その部分木が除外から漏れる

### 描画崩壊の検査(iOS Simulator のみ・ユーザー決定)

iOS Simulator ではアプリのプロセスの描画が壊れ、アプリを起動し直すまで戻らないことがある(触らずに置いた壊れた Compose が
26 分以上文字なしのままだった)。形は2つ: アプリの領域が**一色**(白・黒。観測の約 70%)/ 図形は描かれるが**文字が一つも無い**(約 30%・Compose のみ)。
**木は正常なまま**なので、木だけを読む検証(`keyboardIsShown`・`checkIsON`・`exist("#id")` …)は壊れた画面で緑になっていた
(文字の検証は既存のテキストの可視性検証が赤にする)。実機と Android は対象外。**自前描画(Compose・Flutter)のアプリと、フレームワークが分からないアプリだけ**を確かめる —— 失敗レポートの画面写真の全数当てで崩壊が当たったのは Compose・Flutter だけ(RN 0 / 192・SwiftUI は全面が黒い写真 3 / 648)。判定は `StepExecutor.checksRenderCollapse`。アプリのログの Metal エラーは信号に採らない
(MN-90)。

- **負債の記録**: 検証が、テキストの可視性検証による**画素での文字の確認**(静的テキスト要素のインク・OCR の読み・FM の可視)無しで通ったら、負債を記録する
- **検査点**(`launchApp` / `restartApp` / `clearAppData` / `terminateApp` の直前・`afterEach` の前・シナリオの末尾): 負債があれば
  スクリーンショットと木を1回ずつ取り、判定する。**文字の確認が通った検証は負債を消す**ので、区間の全ての検証にそれがあれば撮らない
- **判定は `FTCore.RenderCollapse` の純粋関数の1箇所**。アプリ領域(木の最上端の要素から導いたステータスバーの帯・下端の帯・キーボードの枠を除く)について
  (a) 32×32 の格子で**一色**かつ木がその領域に静的テキスト要素(型 staticText / text / label)を1つ以上申告 /
  (b) 静的テキスト要素(可視性検証の対象になる・アプリ領域内・覆われても切れてもいない・WebView の内側でない)の**全てにインクが無く**
  (輝度の標準偏差がテキストの可視性検証と同じ閾値 12 未満)、かつ**3つ以上**。スクリーンショットと木の向きが違えば判定しない
  (a) のうち**ステータスバーまで画面全体が一色**なら、アプリの描画ではなく画面そのものが写っていない形として `wholeScreenBlank` に書き分ける(MN-90.4)
- **確定**: 見つかったら 1 秒待って撮り直し、**まだ見つかるときだけ**「screen rendering check (before launchApp | at the end of the scenario …)」の
  失敗ステップを記録してシナリオを中断する。文言は事実だけ(一色 / N 個の文字要素のどれも描かれていない・1 秒あけた2枚・最後に描画を確認してから
  画面を見ずに通った検証 N 件の名前)
- **費用**: 画素で文字を確認した検証が無い区間だけ、スクリーンショット1枚(Simulator で約 100〜115ms)。E2E の iOS 実行の 15%(直近3日)
- **閾値 3 の根拠**: iOS の失敗スクリーンショット 2,453 枚(レポートの要素一覧 + PNG)の全数走査で、目視で崩壊と確かめた最小は文字要素 2 個、
  全てインク無しだが崩壊でなかった最大は 2 個(木と絵の取得時刻が違う)。向きの違う横長のスクリーンショットがもう一つの崩壊でない当たりで、向きの門の理由
- **環境変数**(`FT_*` はシナリオの子に届く): `FT_RENDER_COLLAPSE_EVERY_ASSERTION=1`(計測用: 通る検証ごとに判定し、崩壊なら赤にする。
  デバイス実行で誤検知の数を数えるときだけ使う)/ `FT_FAKE_RENDER_COLLAPSE=1`(陽性対照の注入。判定の答えだけを差し替える)
- 結果 JSON: docs/results-json.md(`failureKind` / `command` は無い)。フレームワーク別の出方: FD-3

### 割り込みハンドラ(アプリ内メッセージ)

- **`irregularHandler("#promo_modal", dismiss: "#btn_promo_close")`** を宣言すると、以降どのステップでも
  出た時点で閉じてから本来の操作を続ける(`StepExecutor.dismissInterruption`)。
  各所に `ifCanSelect` を撒く必要がなくなる
- **宣言の寿命はシナリオ1本**(ハンドラは `FTDriveCore` が持つ = 1プロセス1シナリオ)。
  `beforeEach()` に書けば各 `@Test` の前に自動で入るので実質1箇所で済む。
  beforeEach を持たないクラスでは `@Test` ごとに書く
- **アクションでも検証でも発火する**。割り込みは `exist` / `textIs` の**待機中にこそ出る**ので、
  アクション側だけだと宣言した意味が半分失われる(ポーリングの各周回で照合する)
- **閉じ方はアプリ作者しか知らないのでツールは推測しない**。宣言が無ければ何もしない。
  OS 側のダイアログ(権限・IME の案内)は**ここに書かせない** — ツールが吸収する範囲
  (デバイス設定での抑止 + 別 window の検出)。両者を混ぜると責任の所在がぼやける
- **アプリ内メッセージを自動で閉じる相手にしてはいけない理由**: 「今後表示しない」「購入」「削除」が
  閉じるボタンの隣にあり得る。押し間違えるとアプリの状態が壊れ、以降のシナリオを汚す。
  同じ理由で **FM に閉じ方を選ばせるのもアプリ内には広げない**
- **評価は操作前のスナップショットへの照合だけ**(追加のスナップショットを取らない)。
  正常系のコストはゼロで、閉じた後にだけ取り直す
- **閉じたことは必ずステップの注記に出す**(`割り込み … を閉じました`)。黙って閉じると
  「毎回出続けている」異常に気付けなくなる。1ステップで閉じるのは最大10回まで(`maxDismissals:`。
  閉じても消えない相手で無限に回らないため)

### 共通ステップとライフサイクル

- **`group("名前") { }`** は記録の見え方だけを変える(実行・失敗セマンティクスは素の列と同一)。
  内側のステップ説明に `[名前]`(入れ子は `[外/内]`)を前置する。前置は `FTDriveCore.recordStep` の
  1 点でだけ行い、**修正提案の description は素のまま**(ソース行との照合に使うため)
- **`beforeEach()` / `afterEach()`**: 同じクラスに引数なし・非async・非throws で書くと `@TestClass` マクロが
  各 `@Test` の run クロージャに織り込む(基底クラスからの継承は見ない)。ライフサイクル無しの
  クラスの生成コードは従来どおり(`X().method()` の 1 式のまま)
  - **beforeEach の失敗はシナリオごと中断**する。中で失敗すると本体と同じく `handleFailure` が `scenarioAborted` を立て、
    以降のステップは skipped で記録される(中断の状態は `scenarioAborted` の1つだけ。`scene(n)` の入口では戻さない)
  - **afterEach は失敗後でも実行**する(中断フラグを一時解除 → 実行後に「元の中断」と「片付け中の失敗」の
    OR で復元)。片付けが飛ぶと後続シナリオを汚すため。ただし**画面凍結・ユーザー中断(debug stop)では
    実行しない**(前者は別デバイスで振り直すので無駄、後者は「止めた」のに片付けで再び止まるのが不合理)

### 実行アーキテクチャ

- `scenarios/` を SPM の実行ターゲット(fleetest-scenarios)としてコンパイル。
  マクロが生成する登録クラス(NSObject 派生)を objc ランタイム走査
  (メッセージ送信なしの class_getSuperclass のみ)で自動発見する
- **1 プロセス = 1 シナリオ実行**のサブプロセス方式。ホスト(CLI/GUI/MCP)は ScenarioHost 経由で
  起動し、NDJSON イベント(FTCore/ScenarioEvent)を受信。ビルドはホスト側で1回だけ
- **セッションの状態**(契約は `FTCore/DeviceSessionHandoff.swift`): 親が持つ状態は2層。
  **run 共有の `RunSharedSession`**(メモと `beforeAll` の状態。1 run に 1 つ)と、
  **1 run × レーンキー(デバイス)ごとの `RunDeviceSession`**(`setUpDevice` / `tearDownDevice` の済み印)。
  子は `--device-session-stdin` で起動され、**stdin の 1 行目**に `DeviceSessionHandoff`(その時点のメモの写し +
  `runSetUpDevice` + `runBeforeAll`)を受け取る(制御コマンドの読み手より先に読む)。子→親は `ScenarioEvent` の
  `memoWrite` / `memoClear` / `deviceSetUp` / beforeAll の開始・結果を**片道通知**(応答なし)で送り、`ScenarioHost.run` が
  横取りして状態へ反映する(`fleetest api` の NDJSON 契約には出さない)。メモは run 共有なので、シナリオが受け取るのは
  起動時点の写しで、走行中の他デバイスの書き込みは見えない(書き込みの直列化・ロックなし)。
  **`beforeAll` は 1 run × 1 クラスで 1 回**: そのクラスの最初のシナリオの子が走らせ(`runBeforeAll = true` を受ける)、
  走っている間、同じクラスのシナリオを受け取った他デバイスの親は終わるまで待つ(待ちはシナリオの所要・タイムアウトに数えない)。
  開始後に失敗・子が落ちたら撃ち直さず、そのクラスの残りは走らせずに失敗として記録する。beforeAll の開始前にそのシナリオが
  終わった場合(起動失敗等)は別のデバイスが引き継ぐ。run が複数のマシンに分かれるとマシンごとに別の状態になる。
  **`afterAll` は 1 run × 1 クラスで 1 回・全デバイスの仕事の後**: 各シナリオの子が開始時に afterAll の申告を出し
  (`afterAll` "declared"。親はその OS を添えて `RunSharedSession` に貯める)、親は全レーンの合流後(各デバイスの
  tearDownDevice の後)に `ScenarioHost.runAfterAlls` で `--after-all-only` の専用の子を1クラス1本起こす。走らせる先は
  申告した OS で仕事を最後まで終えた(離脱しなかった)デバイスで、その間だけ run-lease を取り直す。選べなければ走らせず
  「was not run」と1行残す。中断した run では呼ばない。直指定・dry-run・MCP の経路は tearDownDevice の直後に同じ関数を呼ぶ
  (`AfterAllWiringTests` が経路ごとの呼び出しの数を揃える)。
  **`setUpDevice` は高々 1 回**: 親が「試行した」時点で済み印を付け、結果不明(子が落ちた等)でも
  同じデバイスで撃ち直さず、デバイスの復旧後も同じ run では再実行しない。失敗したクラスの後続は
  走らせずに失敗として記録する。**`tearDownDevice` はシナリオの子では走らせない** —— 共有キューでは
  「このデバイスでのクラス最後のシナリオ」が取り出し時点で決まらない(残りを別デバイスが取りうる)。各シナリオの子が
  `deviceTearDown`(status `declared`)で「このクラスは tearDownDevice を持つ」と申告し、親は**デバイスがキューを
  掃き切った後**(`RunOrchestrator.runWorker` の末尾・逐次の各経路はループの後)に、申告のあったクラスだけを
  `--device-teardown-only` の専用の子で1本ずつ走らせる(`ScenarioHost.runDeviceTearDowns`。取り出した時点で済み印 =
  高々1回)。結果は results に載せない(`<クラス>.tearDownDevice` は @Test ではないので `--failed` に拾わせない)。
  離脱・中断したデバイスでは走らない。MCP は**呼び出しごとに新しいセッション**(空のメモ)。人が直接起動した子は
  `--device-session-stdin` なしで空のメモ・`runSetUpDevice = true` から始まる。**子の stdin は常にパイプ**
  (親の stdin を継がない。MCP サーバの stdin = プロトコルの経路を子へ渡さない)で、書き手の fd は `F_SETNOSIGPIPE`
  (起動直後に死んだ子への write で親ごと落ちない)
- シナリオ本体は**専用スレッドで同期実行**し、async の StepExecutor/AppDriver へは
  セマフォで橋渡し(FTSync)。ブロックするのは専用スレッドのみで協調プールは塞がない。
  **上限(既定120秒)で諦めたら op を必ず cancel する**。放置すると諦めたはずの
  tap/snapshot が**後続ステップの最中にブリッジへ着弾**し、記録に残らないまま画面を動かす
  = 原因不明の一発ずれになる。cancel は届く(通信は `URLSession.data(for:)`、待ちは
  `Task.sleep`。どちらも cancel 対応)。cancel を見ない処理(Process 実行等)は走り切るだけで悪化しない。
  **副作用: op は任意の await 点で巻き戻り得る**ので、掴んだ資源の解放は `defer` に置くこと
  (契約は `FMCallAdmission.enter()` のコメント。ここを崩すとホスト全体の FM の呼び出しの枠が漏れる)。
  `procedure` と `doUntilTrue` は中で DSL のコマンドを実行するブロックで、1つのステップではないので
  この上限は掛からない(利用者向けの記述は docs/commands.md)
- 失敗セマンティクス: コマンド NG → **シナリオ全体を中断**(以降のステップは scene を跨いで
  すべて skipped。throw を使わない Shirates 的中断)。afterEach だけは失敗後でも実行される。
  scene 単位のスキップで次の scene へ進む形にはしない(ユーザー決定 2026-07-27): 失敗後の画面状態は不定で、
  続けても壊れた前提の誤った緑・誤った赤を生むだけのため
- **登録不要の単発実行**: `fleetest run-file <path.swift>`(Sources/fleetest/RunFileCommand.swift)。
  `fleetest project create/sync` で Package.swift へ登録していない .swift をそのまま実行する。
  実装は「対象プロジェクトの `scenarios/_runfile/` へコピー → 通常どおり `RunScenarios` へ委譲 →
  実行後に撤去」だけで、**ビルド・プロファイル・レポート・ヒール・並列は通常 run と完全に同一**。
  - シナリオを**解釈実行**する軽量モードは採らない。実行系が2本になると意味論が必ず分岐し、
    生 Swift・`procedure`・ホスト言語の制御構造という DSL 最大の資産を単発実行だけ失う
  - ファイルが既に登録済みターゲットの中にあるならコピーしない(重複クラス定義になる)。
    `_disabled/` はコンパイル対象外なので、退避したままの単発実行はステージ側に回る
  - 実行するシナリオはファイル内の `@TestClass` から拾う(`--scenario` で明示も可)
  - `_runfile/` は実行の前後で消す。SIGKILL 等で残った場合は次の run-file の開始時掃除まで
    そのプロジェクトの通常 run にも混ざる(.gitignore 済み)

### 自己修復(ロケータの指紋照合のみ)

現在の解決順は **プライマリ → フォールバック → 指紋照合**(FM は呼ばない)。ソース位置付きの
修正提案をレポートに出し、実行の終わりにソースへ自動で書き戻す(下記「ソースへの書き戻し」)。`heal` は他のトグルから独立(自己修復は
FM 機能ではないため。ユーザー決定 2026-09-15)。

**FM ヒールもヒールキャッシュも置かない**: FM ヒールの採用門(confidence == high)が本番で実測 0/272 しか開かず
(MN-22)、ヒールキャッシュは FM 版だけが書き手だったため、指紋照合だけの1層構成にしている。

#### ソースへの書き戻し

git 管理を前提に、修正提案(ファイル・行・変更前・変更後が揃ったもの)を結果を記録した実行の終わりに
シナリオの `.swift` へ書く(`FTCore.HealWriteBack` が規則(純粋)、`FTCore.HealSourceWriteBack` が読み書きとロック)。
書くのは `fleetest run`(プロファイルの有無を問わない)・`fleetest api run`・MCP の `ft_run_scenario`(プロセス内で回すので
イベントから集める)、リモート実行では結果を集めた発行元(ランナー機の子は `FT_DISPATCHED_RUN=1` で書かない)。
`ft_start_run` は `fleetest run` を起こすのでそちらで書く。
**分割した run**(`FleetRunner`・`DeviceMachineRunner`・`ApiRunMachineFanout`)の子は書かずに親の受け口
(`HealSourceWriteBack.Collection`。子へは `DispatchTicketIssuer.childEnvironment` の必須の引数で `FT_HEAL_SUGGESTIONS_OUT` を渡す)へ
追記し、親が全部の子のあとで1回だけ計画して書く —— 子ごとに書くと、子をまたいで食い違う提案を先に書いた子が採る。
受け口は親の一時フォルダ(シナリオの子は書けない)。dry-run は書かない。規則: 変更前のセレクタがその行に Swift の
文字列リテラルとしてちょうど1回出現するときだけ置換する / 同じ場所(ファイル・行・変更前)に別々の変更後が
あれば何も書かない / 同一の提案は1回 / このプロジェクトの `scenarios/` の外とシンボリックリンクは書かない / 行に変更後があり
変更前が無ければ書き込み済み(エラーにしない) / 行が変わっていれば書かず理由を報告する。
同じプロジェクトへの同時の書き込みは `<project>/.fleetest/heal-writeback.lock` で直列化する。出力は既存の ⚠️ の行のあとに
`✏️ Self-healing wrote N selector fix(es) back …`(失敗は `⚠️ Self-healing could not write …`。`api run` では標準エラー)。
レポートと JUnit の提案は書き戻しの有無にかかわらず残る。利用者が避けるには `heal=false`。
VSCode 拡張は確認パネルを持たず、書き戻した実行の終わりに通知(「変更を表示」でソース管理ビュー)を出す。
`fleetest api apply-heal` は無い。

### ロケータの指紋

**FM を採否の判断から外す層**(`FTCore.LocatorFingerprint` / `FTDSL.LocatorFingerprintCache`)。
「id が変わってラベルは不変」という典型的なドリフトを、推測なしで解決する。
下の知見にあるとおり **confidence は信号を持たない**ので、FM に採否を委ねると
正しい提案まで却下される —— その判断を決定的な照合へ移す。

- **効くのは失敗経路だけ**(プライマリ・フォールバックがすべて外れたとき)。
  **今緑のステップの挙動は変えられない**ので、リスクがこの1箇所に閉じる
- **控えるのは `type` + `label`**(+ 非 nil のときだけ `placeholder`)。**`id` は控えない**
  —— ドリフトで変わるのがまさに id。**`value` も控えない** —— 実行ごとに変わる
- **ちょうど1件一致のときだけ採用**。0件・複数件は解決失敗としてステップを落とす
  (これ以上のフォールバック層は無い)。
  **スコアも距離も重み付けも作らない**(根拠のない定数を置かない)——
  複数件を「もっとも近い」で選ぶと別要素へ静かに解決し、誤った緑を作る
- **記録するのはプライマリ/フォールバックで素直に解決できた回だけ**。指紋照合で解決した回を
  記録すると、誤った解決が指紋として固定化され再生産される
- **指紋照合の結果はキャッシュしない**。決定的で毎回再導出できるので、キャッシュしても
  得られるのは速度だけ。一方、一意に一致したが実は別要素だった場合に誤りが永続化し、
  以後は注記無しで解決されて気付けなくなる。修正提案は毎回出す(提案と固定化は別)
- 注記 `heal-fingerprint-match` を必ず立てる(結果 JSON に出て run 横断で数えられる)
- **`heal=false` は指紋照合を止める**(ユーザー決定 2026-09-15)。門は `StepExecutor.execute`
  の入口1箇所。他のトグルとは独立 —— 自己修復は FM 機能ではない。
  **記録(採取)は heal=false でも続ける** —— 修復ではなく観測なので、heal を戻した日に
  控えが古びていない
- **型だけの指紋(label も placeholder も空白だけ)は記録も照合もしない**(`isIdentifying`)。
  `nil == nil` で一致するので、ラベル無しのアイコンボタンが消える回帰でも、画面に残った
  別のラベル無しボタンが「ちょうど1件」になれば叩いて緑にしていた。記録時は同じ鍵の古い控えも消す
  (要素がラベルを失ったのに古いラベルの控えを残すと別要素へ解決し得る)
- 書き出しはメモリに溜めて `defer` で1回だけ(`LocatorFingerprintCache.record` はメモリへ溜めるだけ。毎ステップのファイル書き直しを払わない)
- **鍵は `"<scenarioID>|<platform>|<file>:<line>|<selector>"`**(`LocatorFingerprintCache.key`)。
  **OS を含める**: iOS と Android で回す共通のシナリオは同じ行を共有するが、同じ要素でも型名が
  OS で違う(CMP のボタンは iOS `button` / Android `Cell`)。OS を跨いで1つの鍵を上書きし合うと、
  直前にもう一方の OS で採った指紋と一致せず、交互に回す限り直らない
- **失効はシナリオ単位の置き換え**(時間の定数は使わない)。鍵が `file:line` とセレクタを含む
  以上、利用者が**行を足す/消す・セレクタを直す**たびに古い鍵が生まれ、二度と lookup されない
  まま永久に残る(実測: 1 run で 90 エントリ / 19.6KB)。シナリオが**通った**とき、その
  `scenarioID` の鍵のうち今回**触れなかった**ものを刈る。**「触れた」= lookup または record** ——
  鍵はソースの行+セレクタなので、引かれた = その行は今も在る。record だけを数えると、
  指紋で直ったステップ(record しない)の鍵を、同じシナリオでプライマリが通る別ステップが
  record した run の終わりに刈ると = **run2 は緑・run3 で指紋を失って赤に戻る**
  (`94_指紋照合` は2周しか回さないので踏まない。`LocatorFingerprintRecordingTests` の3周テストが守る)。守る条件3つ ——
  **①通ったときだけ**(失敗・中断した run は後続ステップに到達していないので、刈ると
  生きている指紋を落とす)/ **②そのシナリオの鍵に1件以上触れていたときだけ**(触れた集合が空の
  run で刈ると、そのシナリオの鍵を根こそぎ失う。**消してはいけないガード**)/
  **③接頭辞 `"<scenarioID>|<platform>|"`(`LocatorFingerprintCache.scope`)で自分のぶんだけ**
  (`--scenario` の部分実行で他シナリオの指紋を巻き込まない・iOS の run が同じシナリオの
  Android の指紋を刈らない)

**witness は `TestProjects/E2E-CMP/scenarios/_disabled/94_指紋照合.swift`**(唯一の witness。
FM 版の witness `90_自己修復` は持たない → MN-22)。
94 は「同じ行が一度成功し、次にドリフトする」状況を作る。**状態(schema)の制御はシナリオの外**に
置く —— 中に入れると失敗中断時に後始末の scene へ到達できず回復しない。
**schema はデバイスごとのアプリデータ**なので両周を同じ `--device` に固定すること
(指紋はホスト側のファイルなので、デバイスを跨ぐと指紋だけが引き継がれて噛み合わない)。
**回すのは `Scripts/heal-verify.sh`**(補助 `95_指紋照合の前提切替` で schema を切り替え、
v1 で採取 → v2 で2周 → `heal=false` で赤、を1台に固定して判定する。docs/verification/)。

実測(2026-09-02): ドリフトした `#btn_heal_v1` が `#btn_heal_v2` へ **FM 呼び出し無し**で解決し、
アプリ側の記録が `tapped=v2`(正しい要素を叩いた証拠)。フル E2E 231 シナリオで採取 304 件・
`workerAnomalies` 0 件。

## DS-17 テストベースからのシナリオ下書き生成

`TestProjects/<name>/docs/testbases/*.md`(テスト設計の元資料)を Swift DSL シナリオの**下書き**に
落とす。`fleetest draft-scenario`。探索の操作列からの下書き(MCP の `ft_draft_scenario`)は実セレクタを持つが、
こちらは設計資料しか無いのでセレクタは全て TODO プレースホルダになる。

### DS-17.1 二段構え(FM → 決定的パーサ)

| 層 | 実装 | 役割 |
|---|---|---|
| 構造化(FM) | `FTFoundationModels/TestbaseDrafter` | 資料 → `ScenarioDraft`(scene の並び + CAE ごとの自然言語手順)。1呼び出し1セッション |
| 構造化(決定的) | `FTCore/TestbaseOutline.parse` | 見出し(`#`=説明 / `##`=scene)・`### 前提`・行頭ラベル(`前提:`/`Given:`)・「〜こと」で CAE に振り分け |
| レンダリング | `FTDSL/ScenarioDraftCodeGen` | 手順文 → コマンド候補(語彙の包含判定のみ・**FM 不使用=決定的**)+ Swift ソース |

**FM が不可用・失敗・出し損ないのときは決定的パーサへ落ちる**(`--no-fm` で常に決定的)。
4K 制約のため FM へ渡すのは先頭 2400 文字だけで、超過時は警告する(全文要約より「頭から確実に」)。

### DS-17.2 生成物の性質(壊さないこと)

- 生成クラスには **`@Draft` を付ける** → 一括実行から外れる(一覧には残る)。人が TODO を実セレクタへ
  置き換えてから `@Draft` を外す運用。出力先は `scenarios/Drafts/`(SPM ターゲットに含まれるので
  **下書きもコンパイル対象**。`ScenarioCodeGen.writeValidated` でビルド検証し、失敗時は `_disabled/` へ隔離)
- プレースホルダは `#TODO` = **決して解決できない id**。埋め忘れたまま `@Draft` を外すと
  「ロケータを解決できません」で確実に落ちる(空実装で緑になる方が危険なので意図的)
- 手順文は必ずコマンド行の末尾コメントに残す(写像が外れても元の意図が読める)
- `--name` 明示時は重複回避の連番が付かないため、同名ファイルがあれば上書きせずエラーにする
