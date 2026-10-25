# 設計: Swift DSL の記述と語彙

| 種別 | 範囲 | 読む場面 | 扱わないこと |
|---|---|---|---|
| 正典 | Swift DSL の記述形式・ライフサイクル・Shirates 準拠・入力とキーボード・セレクタ・検証・スクロールの語彙(DS-10 の前半) | DSL のコマンドや語彙を変える前 | 失敗時の情報と実行(→ [dsl-execution.md](dsl-execution.md))・各コマンドの引数(→ [commands.md](../commands.md)) |

DS-10 は2ファイルに分かれる。後半は dsl-execution.md。

## 目次

- DS-10 Swift DSL

## DS-10 Swift DSL

テストは **Swift DSL** で書く。イレギュラー処理(不定ダイアログ等)やデータセットアップを「コード」で書ける。

### 記述形式

- `@TestClass(platform:)` クラス + `@Test(_:platform:scenarioTimeout:)` メソッド + `scene(n)`(Shirates の case 相当)
  + `condition/action/expectation`(CAE)の3層構造
- **`@TestClass` に `app:` は無い**(書くとコンパイルエラー)。アプリは
  **実行プロファイル → アプリプロファイル → 実行中 platform の `ios.app` / `android.app`** から
  解決される(`FTCore.ScenarioAppResolution` が唯一の定義元。親が `--app` で子へ渡す)。
  これで**同じシナリオを `--profile ios-run` と `--profile android-run` で別 bundle ID の
  アプリに対して回せる**。実行プロファイル無し(`--port` / `--serial` の直指定)は `--app-id <bundleID>` で渡す。
  どちらからも決まらなければ明示エラー(**dry-run だけは代替表記で通す** —— デバイスに触らず bundle ID を使わないので、
  ここで落とすと「実行プロファイル無しでは構文検査もできない」になる)。MCP `ft_run_scenario` は `profile` 無しなら
  プロジェクトの唯一のアプリプロファイルを使い、2つ以上あれば断る(`profile:` を渡す)。
  複数アプリを扱うプロジェクトは、アプリごとに実行プロファイル(とフォルダ)を分けるか、切り替えるステップで
  `launchApp("<id>")` に明示する
- **`@Test(scenarioTimeout:)`**(秒・メソッドのみ)はそのシナリオ全体の watchdog 秒。優先順位は
  `@Test` > プロファイル `scenarioTimeout` / `--scenario-timeout` > `ScenarioHost.defaultScenarioTimeout`(600)で、
  解くのは `FTCore.ScenarioTimeoutResolution` の1箇所。シナリオ側が短くても勝つ。マクロは整数リテラル 0 以下をコンパイルエラーにし(式で届いた 0 以下は `ScenarioHost.run` が子を起こさずに赤 = `invalidScenarioValueReason`)、
  値は `FTScenarioDescriptor` → `ScenarioInfo.scenarioTimeout`(子 → ホストの `list --json`・`fleetest api` 契約には載せない)→
  `ScenarioHost.run(scenarioTimeoutOverride:)`(既定値なし)で運ぶ。timeout のログ行に出所を括弧で添える。
  呼び手が info の値を渡していることは `ScenarioTimeoutOverrideWiringTests`(ソース走査)が固定する
- **シナリオの打ち切りは2系統**(`ScenarioHost.run`。どちらも SIGTERM → 2 秒 → SIGKILL・`timedOut: true`・
  先に `TimeoutGuard` を取った側だけが打つ。`--debug` では両方とも無効):
  - **出力の途切れ(idle)**: 子の stdout / stderr の出力の間隔が `ScenarioIdleBudget`(2 × `commandTimeout` =
    1ステップの上限 + 失敗時の証跡の上限)+ **いま開いている** `deadlineExclusion` の上限 + **子が申告した待ち**
    (`FTCore.IdleAllowance` → `idleAllowance` イベント。canSelect 系の waitSeconds・httpRequest・doUntilTrue。
    入れ子は最大を採る。締め切りからは差し引かない)の上限を超えたら止める(`FTCore.ScenarioIdleWatch`)。
    長さの分からない素の Swift(procedure の中など)は申告しない = 240 秒を超えて黙れば止まる(利用者向けに明記)。行は `⏱ The scenario produced no output for <S>s (allowed <A>s = …) and was killed`。
    **遅いだけで出力を続ける子は止めない**。出力の到着は**パイプの受け口**(`lineStream(onChunk:)`)で数える ——
    読み取りループで数えると、ループが installRequest を待つ間と、親が止まっていた直後の未消化の行を「無出力」と
    見る。打つ直前にパイプの未読(`hasUnreadOutput` = poll)も見る(親の再開と同時に起きた killer が先に走る形)。
    警告の段を経ずに打ち切りで入れた(ユーザー決定 2026-10-12)。根拠の実測: 過去の全体打ち切り 61件のうち 45件は
    最後の出力から 30 秒以内 = 進行中の子を切っていた・緑の出力間隔は p99.9 で 57 秒、最長は OCR コンパイル待ちを
    含む 120 秒台(延長の申告で許される側)。9/17 の緑で最後のステップの後 555 秒・178 秒無出力だった2件は、当時
    シナリオごとの実行ログが無く原因を判定できていない(同じ形が出れば今は idle で赤になる)
  - **全体の上限(scenarioTimeout)**: 行は
    `⏱ The scenario exceeded <N>s (<出所>) and was killed (last output from the scenario <S>s before)` ——
    `<S>` が小さければ進行中の子を切った(遅いだけ。上限を見直す材料)
- **`@Test(platform:)`** はメソッド単位の対象 OS 宣言(クラスの `platform:` より優先)。
  宣言した OS を回さない実行プロファイルでは**キュー投入前に外して skipped(対象外)として記録する**
  (`FTCore.PlatformApplicability`)。**複数の機械にまたがる分散(host 混在プロファイル /
  `--fleet --split`)でも同じ判定**を fleet 全体の OS 和集合で掛けてから割り当てる
  (`FleetSplit.applicability`。2026-08-23 まで割り当てが throw して1本も走らなかった。
  分散の親は recorder を持たないので、スキップは記録ではなくログに出る)。**失敗に数えない** —— 以前はクラス側の `platform:` すら
  「担当ワーカーなし」に落ちて失敗として数えられており、「そのOSでは対象外」を表現する手段が
  無かった。記録は `ScenarioSkipKind` で**意図された対象外**と**インフラ都合の未実行**を
  区別する(混ぜると「緑だが1本も走っていない」run を見分けられなくなる)
- `@Deleted("コメント")` で論理削除(Shirates の @Deleted 相当)。テストクラスまたは
  `@Test` メソッドに付与する。一覧には「削除済み」として残り、全実行・フォルダ実行・クラス名指定の一括実行から除外される。
  完全一致 ID の明示指定でのみ実行可能。コードは残るため復活はアノテーションを外すだけ
- `@Draft("コメント")` で実装中(未完成)マーク。テストクラスまたは `@Test` メソッドに付与する。
  除外・実行可否の規則は `@Deleted` と同一(全実行・フォルダ実行・クラス名指定からは除外、
  完全一致 ID なら実行可)で、**違うのは意味だけ**(Deleted=もう使わない / Draft=これから使う)。
  `fleetest draft-scenario` の生成物にはこちらが付く
- コマンド(tap/type/exist/…)は**同期・非 throw のモジュールレベル自由関数**。
  `try await` も `{ it in }` も不要。カレント実行コンテキストを暗黙参照する。
  **DSL スレッド外(Task / 別スレッド)からの呼び出しは fatalError にしない**(2026-07-29)。
  1プロセス=1シナリオなので落とすと**レポートごと消える**。`FTDriveCore.recordThreadViolation` が
  失敗ステップを**1 run につき1回だけ**記録してシナリオを中断し、以降は既存の skip 経路へ乗せる
  (`handleFailure` は呼ばない = スクショ撮影を別スレッドから走らせない)。
  **core 未初期化だけは fatalError のまま**(記録先そのものが無くレポートを残す手段がない)
- **上と対になるロックが2つある**(どちらも「落とさずレポートを残す」ための最低条件。
  排他しないと `record.scenes` の append と `record.scenes[last]` への代入が競って
  **レポートを残すどころかプロセスが落ちる**):
  - `FTDriveCore.stateLock`(**再帰**): `record` 全体・`scenarioAborted`・`deviceFrozen`。
    DSL スレッド以外に、①違反スレッド ②`executor.onDeviceFrozen`(FTSync の detached Task 上)
    が触る。再帰にしてあるのはロック下の処理が `scenarioAborted` を触るため(`markDeviceFrozen`)
  - `FTRuntime.lock`: `core` / `dslThread`。**tearDown の書き込みと違反スレッドの読みが競る**
    (素の Optional への同時読み書きは実際に落ち得る)。
    **`stateLock` より先に取り、握ったまま core を呼ばない**(ロック順序を一方向に保つ)
  - **他の実行状態(`groupStack` / `scrollContextStack` / `currentSection`)は DSL スレッド専有のまま**で、
    違反スレッドが中断検知の前に触り得るのは受容した残存リスク(記録の見え方が乱れるだけで
    結果は壊れない)。検証は `swift test --sanitize=thread --filter FTDSLTests`
    (**ロックの正しさは目視では担保できない**。触ったら必ず TSan を通すこと)
- **要素が見つからなければ失敗(シナリオ中断)。唯一の例外は `select`** で、掴めなければ
  失敗させず空要素を返す(`FTElement.isEmpty`)。**「出るか不定」を表す引数は持たない**
  (`optional:` は 2026-08-02 に全廃。`irregularHandler` と `ifCanSelect` に一本化した。下記)
- **待つ上限の引数名は全コマンドで `waitSeconds:`**(ユーザー決定 2026-09-19。Shirates と同名・単位が名前に出る。
  `timeout:` は DSL に置かない。**MCP ツールの待ち上限も `waitSeconds`**(2026-09-25 に `timeout` から改名。
  MCP は DSL を書くための入口なので、同じセッションで2つの名前を書かせない)。`FlowStep.timeout`・実行プロファイルの
  `defaultTimeout` / `scenarioTimeout` は内部 / 別系統の名前で据え置き。**`ft_batch` は DSL の行を受けるので DSL と同じ `waitSeconds:`** ——
  索引の signature とビルダーのキー(`MCPServer.batchStepBuilders`)を片方だけ変えると、実在するラベルを断り
  無いラベルを受ける。`BatchLineParserTests.testWaitCapLabelFollowsTheDSL` が縛る)
- **引数の並びは「対象 → コマンド固有 → `waitSeconds:` → `scroll:` → `maxSwipes:`」**(ユーザー決定 2026-09-19)。
  `exist(sel, requireVisible:, waitSeconds:, scroll:, maxSwipes:)` / `textIs(expected, requireVisible:, strict:, waitSeconds:)` /
  `checkIsON(prefer:, waitSeconds:)` / `tap(sel, holdSeconds:, maxGestureSeconds:, containerInference:, waitSeconds:, scroll:, maxSwipes:)` /
  `scrollTo(sel, direction:, scrollFrame:, startMarginRatio:, endMarginRatio:, containerInference:, maxSwipes:)`
  (`containerInference:` もコマンド固有の引数。2026-09-25 までは末尾にあった)。以前は検証系だけ
  `waitSeconds` が固有の引数より前で、`checkIsON` とも操作系とも逆だった
- tap/type/select は `waitSeconds:`(ロケータ解決の再試行待ち上限秒。0=リトライなし。
  省略時は tap/type が約0.7秒・select は `defaultTimeout`)を取る。
  出るか不定の要素を `ifCanSelect` で見るときの空振り短縮用(PT-5)
- **秒は全て小数(Double)**(2026-07-29。`waitSeconds:` / `defaultTimeout` /
  `--default-timeout`。`FlowStep.timeout` も `Double?`)。`waitSeconds: 1.2` が書ける。
  表示は `FTSeconds.format`(FTCore)が唯一の生成元で `5.0s` ではなく `5s`・`1.2s` と出す
  (`StepDescription.formatSeconds` はここへ委譲)。
  `ifCanSelect` のポーリングは残り時間と 0.25 秒の小さい方で待つ(**0.5 秒固定だとサブ秒の待ちが
  丸められる**)。`waitSeconds: 0` = 即時1回判定の契約は不変
- `tap(holdSeconds:)` は長押し秒数(既定 `FlowStep.defaultTapHoldSeconds` = 0 = 通常タップ。
  Shirates 準拠)。`holdSeconds` が 0 より大きいときだけ StepExecutor がブリッジの `/press` へ回す。
  既定値と同じときは `FlowStep.duration` を nil のままにする(生成コードを
  既定ケースで太らせない)
- **要素の出現待ちは暗黙**: `tap` はロケータ解決を再試行(省略時 約0.7秒)し、
  `exist`/`textIs`/`valueIs` は既定タイムアウト(5秒・`--default-timeout` で上書き)まで
  スナップショットを取り直してポーリング再判定する。遷移後の検証直前に固定 `wait` を足すのは冗長で、
  足りなければ各コマンドの `waitSeconds:` を上げるのが本筋。例外は `ifCanSelect`
  (既定 `waitSeconds:0` で即時 1 回判定。待つなら `waitSeconds:` を渡す)。
  `wait(1)` の出番はセレクタで待てない整定(アニメ中の座標ずれ等・下記知見の iOS シート例)に限る
- **型名は先頭小文字**(`.button` / `.staticText`)。ブリッジは `Button` を送ってくるが
  `ElementInfo.normalizedType` がデコード時に畳むため、スナップショット表示・セレクタ記法・
  生成コード・ヒール提案の綴りが一致する(3ブリッジの wire 形式は不変 = 版上げ不要)。
  先頭大文字で書くと `validationError` が実行前に落とす
- セレクタ式は文字列1本。**フィルタを `&&` で AND 合成**し、`||` で**候補集合の和**をとる
  (2026-07-26 に Shirates(Classic) の記法へ、2026-07-27 に `||` の意味も寄せた。
  優先順位は `&&` > `>>` > `||`)。**要素を1つ選ぶコマンドは和集合の先頭**(節の順 →
  節内のツリー順)を採るので、`#id||ラベル` はヒール連鎖としても従来どおり働く。
  唯一の解釈者は `LocatorResolver.unionCandidates` / `resolveDetailed`。
  短縮形と完全形の対応:

  | 短縮形 | 完全形 | 意味 |
  |---|---|---|
  | `ラベル` | `text=ラベル` | **完全一致**(暗黙の部分一致フォールバックは無い) |
  | `*語*` / `語*` / `*語` | `textContains=` / `textStartsWith=` / `textEndsWith=` | 部分一致 |
  | — | `textMatches=^…$` | 正規表現(**部分一致**。全体一致は `^…$`) |
  | `#id` | `id=` | id(完全一致) |
  | `#foo*` / `#*foo*` / `#*foo` | `idStartsWith=` / `idContains=` / `idEndsWith=` | id の部分一致(Shirates 準拠) |
  | — | `idMatches=^…$` | id の正規表現(**部分一致**。全体一致は `^…$`) |
  | `.型` | `type=` | 型(先頭小文字) |
  | `[n]` | `pos=n` | 候補内の順番(1 オリジン) |
  | — | `value=` / `placeholder=` | 値・プレースホルダ(`text`/`id` と同じく `Contains`/`StartsWith`/`EndsWith`/`Matches` が使える) |
  | — | `checked=true\|false` / `enabled=true\|false` | 状態(`checked=false` は「オンでない」= 状態を持たない要素も含む) |
  | `(a\|b)` | `text=(a\|b)` | **フィルタ内 OR**(Shirates 準拠。下記) |
  | `!値` | `属性!=値` | **否定フィルタ**(下記。短縮形は `!保存` / `!#id` / `!.button`) |

  一致方法(`Contains`/`StartsWith`/`EndsWith`/`Matches`)を持つのは `text`/`value`/`placeholder`/`id`
  の4属性のみで、`type`/`pos`/`checked`/`enabled` は完全一致だけ。id の否定も text 系と対称
  (`idContains!=` `!#id` が使える)。
  `.型#id` = `.型&&#id`、`.型[n]` = `.型&&[n]` の短縮形。
  **型名に `=` は使えない**(`=` は text= 等のフィルタ名と先頭エスケープに使う)。`.型=ラベル` と
  書くと `=` 以降が型名の一部として never-match になるため、validationError(typeEqualsError)が
  実行前に `.型&&ラベル` を案内して落とす。
  `[n]` は**型に限らずどの組み合わせにも効く**(`#list >> [3]` / `*行*&&[2]`)。
  絞り込み条件が1つも無い節(`[2]` 単独)はスコープの中でしか書けない
- **型エイリアス**: `.input` = `textField|secureTextField` / `.widget` = OS を跨いで保証される役割型
  (`button` `staticText` `textField` `secureTextField` `switch`)。
  **役割不明の `clickable` は `.widget` に入れない**(容器やリスト行を掴まないため)。
  1つの実型で足りる名前(`.label` → `.staticText` 等)はエイリアスにしない = 語彙を増やさない
- **素の文字列は完全一致だけ**。部分一致を暗黙のフォールバックにすると
  **短いラベルが長いラベルに黙って当たる**(`許可` が `通知を許可` に当たる / 別項目の要約にも
  当たって「曖昧解決不能」で throw)ため、部分一致は `*語*` 等で明示させる。
  解決に失敗し**部分一致なら在る**ときは失敗メッセージが `"*語*" と書くと拾える` を出す
  (`LocatorResolver.partialMatchHint`)
- **画面には出ているのに当たらない**残りの形として、**本文が複数ノードに割れている**ときは
  失敗メッセージが `the text is split across N elements ("2026年" + "2月18日")` を出す
  (`LocatorResolver.splitTextHint`。DSL と MCP が共有)。Web の本文は `<span>` や強調で普通に割れ、
  **インラインだけの塊は DOM 側で1ノードへ畳んでいる**(`WebViewDOMSnapshot.isInlineTextBlock`)が、
  間に役割を持つ要素やブロック級の子が挟まると畳めない。**畳めないものを無理に畳むと
  操作対象を潰す**ので、木は変えず言葉で伝える。繋いで見るのは**連続する最大4件**まで
  (増やすと偶然の連結で当たる)。受け手報告 2026-08-20 の実例: 画面末尾に見えている
  「2026年2月18日 改訂」が木では3ノードで `*2026年2月18日*` が両 OS とも空振りした。
  **実体は表組みの行**(3セルが同じ y・x が連続・interactive 要素なし)で、
  **行そのものは要素として出ない**(セルが別々に出る)。したがって
  **「まとめている要素に書け」と言ってはいけない** —— 全体を含む要素は木に1つも無く
  (この助言が出る条件そのもの)、利用者は存在しない逃げ道を探すことになる。
  **表組みの行を1ノードへ畳む案は採らない**: セル単位のアサーションを潰すうえ、
  畳んでも連結の仕方(空白を挟むか)で利用者の書いた文字列に一致するとは限らない
- **ゼロ幅文字は照合前に両辺から除去する**(2026-08-07。`FlowMatchMode.matches`。
  U+200B/200C/200D/FEFF/2060。正規表現のパターンだけは書き換えない)。実データに紛れており
  **画面にもスナップショット出力にも見えない**ので、完全一致が落ちても原因に辿り着けない
  (実測: Google マップの路線名は `​​中央線​` で `"中央線"` が当たらない)。
  `SnapshotRenderer` も出力から同じ集合を除去する = **出したものは必ず一致する**
  (除去しないと、一覧からコピーした文字列に不可視文字が入って .swift へ埋まる)。
  **走査は Character でなく Unicode スカラ単位** —— Character は書記素クラスタなので
  ZWJ は隣接文字と融合し、Character 比較では素通りする
- **`名前=値` の生ラベル**(SUT の状態表示 `notify=off` 等)はそのまま書ける。
  既知のフィルタ名と紛らわしい名前(前方一致関係・大小文字違い・6文字以上で1文字違い・
  既知の基底名〈`text` `value` `placeholder` `id` `type` `pos` `checked` `enabled`〉を接頭辞に持ち
  直後が大文字で続く名前〈`idPrefix=` `textFoo=` 等〉)のときだけ
  `validationError` が落とす(`textContans=x` の綴り誤りがラベル扱いで黙って緑になるのを防ぐ)。
  `名前!=値` にも同じ規則を使う(`count!=0` は素のラベル)。
  **既知の残穴**: 小文字で続く未知名(`identifier=5` 等)は生ラベルと区別できず素通りする
- **フィルタ内 OR `(a|b)`**(2026-07-27。Shirates 準拠): トークン単位の文字列置換で
  **パース時に節へ展開する**(`(保存|OK)&&.button` → `保存&&.button || OK&&.button`)。
  `||` が和集合になったのでこの等価が成立し、照合・serialize・ヒールは一切変更が要らない。
  `|` を含まない括弧はラベルの一部(`保存(推奨)`)。
  **相対セレクタの引数では括弧を自分で書く**(`:right((保存|OK))`。`:right(...)` の括弧は
  引数の括弧なので `|` の囲みにならない)。**展開数が 32 に達したら validationError**
  (`FTSelector.maxExpansion`。実際に書けるのは 31 通りまで)。
  **既知の非対応**: `(a|b)&&[2]` は「各節の 2 番目」であって「和集合の 2 番目」ではない
  (Shirates は後者。節ごとに `[n]` を持つ fleetest の構造をそのまま使うため)
- **否定フィルタ `属性!=値` と短縮形 `!値`**(2026-07-27): `FlowLocator.not` に
  「属性1つだけのロケータ」を並べ、肯定フィルタで絞ったあとに引く(`LocatorResolver.candidates`)。
  一致方法も使える(`textContains!=済`)。**短縮形は Shirates 準拠**で、中身を肯定と同じ経路で
  解釈して `not` に入れるだけ(`!保存` = `text!=保存` / `!#id` / `!.button`)。
  `=` エスケープ(`=!先頭が感嘆符のラベル`)で回避できるので記法の衝突は起きない。
  **否定だけの節は validationError で落とす**(「〇〇以外の全要素」は容器やレイアウトノードまで掴む)。
  **`pos` は否定できない**(完全形 `pos!=n`・短縮形 `![2]` の両方を実行前に落とす。
  候補集合を絞れず黙って無視されるため)。
  **否定は「同じ条件を2回書いている」の重複検査から外す**(`attributeName` が nil を返す)。
  肯定の text と否定を並べるのは正当な使い方で、外さないと `.button&&項目&&!#btn_item_2` が
  構文エラーになる(2026-07-27 に E2E で検出)
- **スコープ `祖先 >> 子孫`**: `#list >> .clickable[2]` は `#list` で解決した要素の**子孫だけ**を
  候補にし、序数もスコープ内で数える(画面クロム・スクロール位置で序数がずれる問題への対処)。多段可。
  子孫判定は「スナップショットは pre-order + 元ツリーの depth」という 3 ブリッジ共通の規約に依存する
  (`LocatorResolver.descendants`。中間ノードのフィルタや上限打ち切りは pre-order を崩さないので保たれる)。
  **スコープ付きロケータはアサーションのフォールバック連鎖から除外されない**(id/label 無しの
  type+index でも容器に錨があるため。`FlowLocator.isWeakForAssert`)
- **スコープはプラットフォーム非依存**(4 SUT × iOS/Android 実測・2026-07-26)。成立条件は
  「**アプリが容器を a11y ツリーに公開している**」ことだけで、フレームワークの差ではない
  (`#id` が「アプリが identifier を付けていること」を要求するのと同じ性質の要件)。
  容器の公開方法だけがフレームワークごとに違う:

  | フレームワーク | 容器の公開方法 |
  |---|---|
  | Compose Multiplatform | `LazyColumn` 等に `testTag` |
  | SwiftUI + UIKit | `UITableView` の `accessibilityIdentifier` |
  | View/XML | `RecyclerView` の `android:id` |
  | Flutter | `Semantics(container: true, explicitChildNodes: true)`。**`MergeSemantics` で包まない** |
  | React Native | `FlatList`/`ScrollView` に `testID`。**iOS は id 付きラッパー(`RCTScrollView`・非 scrollable)と実 scroll ノードが同 frame で別要素に割れるため、ホスト側の正規化で統合する**(両モード) |

  **畳むと子孫が消えてスコープ対象が無くなる**のが唯一の落とし穴(Flutter の `MergeSemantics`、
  Compose の Box+重ね置き `#pad_swipe` は iOS で子 Text が同 depth に平坦化される)。
  当初「Flutter では使えない」と判断したが、SUT が `MergeSemantics` で畳んでいただけで、
  容器を非マージで公開したら iOS/Android とも入れ子になった(=**フレームワークの制約ではない**)。
  回帰は 4 SUT 共通の `#list_rows >> …`(`TestProjects/E2E-CMP/scenarios/09_否定と個数と方向セレクタ.swift`・
  `TestProjects/E2E-*/scenarios/06_待機とタイムアウト.swift` の旧 12_セレクタ拡張 ブロック)。
  `notExist` / `countIs` も 4 フレームワーク全てで同一に動く(同実測)
- **相対セレクタ `基準:rightSwitch`**(`right` / `left` / `above` / `below` × 型別接尾辞
  `Button` / `Input` / `Label` / `Image` / `Switch` / `Widget`。Shirates 準拠で**基準が先**):
  基準から見て指定方向にある候補だけに絞る。**id が付いていないアプリで「〇〇の右のスイッチ」を
  指すための主力記法**(id があるなら `#id` が常に優先)。
  - 引数は3形。`通知:rightSwitch` = 型別 / `数量:right(2)` = 近い順の2番目 /
    `#a:below(.button&&項目)` = 任意のフィルタ式(`||` は和集合 = **全節の候補を合わせてから方向で並べ**、
    最も近い1つを採る。`:right(.button||.switch)` は「両者のうち最も近い方」)
  - **基準は `<...>` で囲める**(Shirates の正典形 `<text1>:rightButton`。囲みは構文糖でパース結果は
    囲まない形と同一で、serialize は付けない)。`<` 始まりの節は括弧形式の予約なので、読めない形は
    生ラベルに落とさず検証エラーにする(`<` で始まる生ラベルは `=` エスケープ)。
    スコープは括弧の外(`#row >> <数量>:rightButton`)
  - 接尾辞なしの `:right` の既定フィルタは `.widget`(役割が確定した要素だけ = 容器を掴まない)
  - **連鎖できる**(`見出し:right:belowButton`)。各ステップの結果が次の基準になる
  - 判定規則は3条件のみで調整値を持たない(`LocatorResolver.directionalCandidates` が唯一の解釈者):
    ①候補の中心が基準 frame をその軸方向へ伸ばした帯に入る ②候補の中心が基準の中心よりその方向に
    ある ③満たすものを方向軸の中心間距離の昇順に並べ、序数(既定 1)番目を採る(同距離はツリー順)
  - **条件を満たす候補が無ければ解決失敗**(「最も近いものを必ず返す」ことはしない。
    レイアウトが変わったときに黙って別要素を掴むため)。基準自身は候補から除く
  - **スコープは節の中の基準にも対象にも効く**(`#row >> 数量:rightButton` は容器の中だけで解決する)
  - 画面外要素は frame が丸められる環境があるため**可視要素にのみ**有効
- **構文検証 `FTSelector.validationError`**: パースは失敗しない契約のままなので、
  `:rigth(x)` のような綴り誤り・他ツール記法(`:near` `:parent` 等)・
  既知フィルタ名と紛らわしい未知のフィルタ名(`textContans=` 等。判定規則は前述の「生ラベル」項)・
  型名の `=`・`[abc]` `[0]` の序数・括弧の不整合・条件が空の節は
  **別経路で検出して落とす**。放置すると誤記が label 扱いになり、`notExist` / `countIs(x, 0)` が
  **必ず成功**する(黙って緑になる唯一の経路)。呼ぶのは `FTRuntime.perform`
  (dry-run でもデバイスに触る前に判定)と `ifCanSelect`(perform を通らないため個別に)。
  **既知の残穴**: 括弧を伴わない綴り誤り(`基準:rigthSwitch`)は
  方向名との前方一致・大小文字違いに当たらないと検出できない
- `||` と `>>` と `&&` の分割は**括弧の外だけ**(`:right(...)` の中は割らない)。
  結合の強さは `&&` > `>>` > `||`。ラベルに `>>` `&&` `:right` `*` を含めるときは `=` エスケープ
  (`=A >> B`)。パースは失敗しない契約は不変
- **木構造セレクタ(`:parent` / `:child` / `:sibling` 等)は実装しない**(2026-07-26 決定)。
  `祖先 >> 子孫` のスコープでほぼ代替でき、語彙を増やすと生成側の誤用が増えるため。再提案しない
- **フローベース相対セレクタ(Shirates の `:flow` / `:input` / `:label` / `:inner` / `:vflow`)は
  実装しない**(2026-07-26 決定・再提案しない)。「ウィジェットを垂直位置でグループ分けし各行を
  左→右に走査」する規則は、**同じ行とみなす閾値という根拠の無い調整値**を1つ要求する
  (中心 y の差 20pt か 10pt かで掴む要素が変わり、iOS/Android の frame の 2〜3pt 差でも割れる)。
  相対セレクタが調整値ゼロなのは帯を**基準自身の frame** から取っているからで、この性質を壊さない。
  ツリー順(pre-order)で定義すれば調整値は不要だが、ツリーの形はフレームワークごとに違うので
  「見た目の次の入力欄」と食い違う。**方向セレクタで取れなかった実例が出てから**再検討する
- **一致品質(exact/substring)は記法ではなく掴んだ要素で決まる**(`LocatorResolver.quality`)。
  `*ログイン*` が `"ログインに失敗しました"` を掴めば substring、`"ログイン"` を掴めば exact。
  読み手は**inapp モードの tap アクションだけ**で、primary が substring 止まりなら fallback を照会し
  fallback の exact を優先する(§performance-tuning「フォールバック検証の誤検知」)
- **inapp の tap は activate 不発時に「整定待ち→要素取り直し→再 activate」で粘る**(2026-07-27)。
  Compose iOS は**画面遷移直後、要素が AX ツリーに載っていても accessibilityActivate がまだ
  配線されておらず false を返す**ことがあり、その瞬間の合成タッチも無反応(成否検知不能)で
  タップが黙って空振りする(実測: sut-ec-mobile お気に入り一覧→詳細で 2/15 失敗)。
  `InAppBridge.tapByRef` が InAppSettle(イベント駆動・cap 800ms)で遷移の整定を待ってから
  ツリーを取り直して再 activate し(+250ms でもう1回)、それでも不発なら従来どおり合成タッチへ。
  待ちはメインをブロックしない(asyncAfter)ので遷移自体は進む。**再試行は activate false の
  ときだけ**発生し通常経路のコストはゼロ。レポート注記「要素を取り直して再実行」
  (`re-fetched the element and retried`)で観測できる。
  **撃ち直すのは自前描画(Compose / Flutter)のアプリだけ**(v109。`AppUIFramework.retriesUnfiredActivate`)。
  救済が効いた記録は全期間で sut-ec-mobile(Compose)の 21 件だけで、UIKit / SwiftUI / RN の不発は恒常的
  (RN の Pressable は tap の 96%・SwiftUI は表のセル・入力欄・アラートのボタン)。E2E の 9 月の約 1.6 万回で
  一度も効かず、1 回あたり約 0.4 秒(RN は 1 シナリオ 7.5 回)を払うだけだった。それ以外のアプリでは
  取り直しを**座標のためだけに**1 回行う(RN のコールドラウンチでレイアウト確定前の frame を叩いた実害 =
  8/8 の `freshTapPoint`)。**合成タッチの前の整定待ちは省かない**(v110): v109 で「保存時の frame から
  動いていたときだけ待つ」にしたところ、E2E-RN の回転直後の tap が吸われた(要素の位置は保存時のまま = 回転の
  遷移中はタッチが捨てられる)。省くのは 250ms の小休止と 2 回目の取り直し・activate だけ。
  語彙が読めなければ従来どおり撃ち直す。
- **Compose/Flutter のスクロールは UIAccessibility の scroll アクションで駆動する**(2026-07-31)。
  両者は `UIScrollView` を持たないので `contentOffset` 経路が無く、move を一気に流す合成タッチの drag も受理
  されない(実時間で刻む `/drag` = 座標ドラッグは 2026-10-22 から受理を確認。スクロールには使っていない)が、**VoiceOver が使う `accessibilityScroll` は実装している**
  (Compose = `AccessibilityElement` / Flutter = `SemanticsObjectContainer`)。1回 = 1ページで、
  実測では XCUITest の実スワイプより**距離が長く**(row_01→27 対 row_01→16)、
  **1回あたり 106ms 対 456ms**。scrollToTop の中央値は 5,304→1,714ms。
  - **`swipe` を `unsupportedActions` に申告しない**: 可否は「目的と画面」で割れる
    (スクロール目的=可 / ジェスチャ目的=不可)ので、一律申告では表現できない。
    判定は `handleSwipe` に一本化し、不可なら 501 を返してホストにフォールバックさせる
  - **スクロール目的の swipe だけ AX 経路へ流す**(`SwipeRequest.scroll`)。DSL の `swipe`
    (ジェスチャ自体が目的)を混ぜると、**ジェスチャ検出パッドの上でもスクロール可能な親が
    受理してしまい**、パッドに届かないまま 200 を返す(2026-07-31 に E2E-Flutter の
    ジェスチャ画面が 2/2 で黙って空振りした)
  - **包むドライバは `swipe(_:intent:path:)` を必ず素通しする**。既定実装は自分の `swipe(_:)` を
    呼ぶので、受けないと**フラグが最初のラッパーで落ちて**経路が丸ごと不発になる
    (実際に落として、フルスイート2周ぶん「緑だが遅いまま」を測ってしまった)。
    `SwipeForScrollForwardingTests` がソース走査で守る
- **整定の打ち切りは黙って返さない**(2026-07-31)。整定待ちは3層にあり(ホストの
  `settledSignature` = 6 poll / in-app の `InAppSettle` = cap 2,500ms / XCUITest ランナーの
  `captureSettled` = budget 350ms)、**どれも収束と打ち切りを同じ顔で返していた**。そのため
  「常態的に上限へ張り付いているのに緑」が誰にも見えず、実際に2件を長く見逃した
  (ラベル振れによる `scrollToEdge` の非収束 / scroll edge effect による in-app の 2.5 秒張り付き)。
  唯一申告していた `scrollToEdge` の `stopped at the limit of N` が、その2件を見つける入口になった。
  以後3層とも note で申告する(ブリッジは `OKResponse.note` / `SnapshotResponse.note`、
  ホストは `StepOutcome.driverFallback`)。**打ち切りは失敗ではない**ので status は 200 のまま
- **整定は「視覚効果パラメータ」を動きと数えない**(2026-07-31)。`InAppSettle` は無アニメが
  100ms 続いたら整定とみなすが、iOS26/27 の scroll edge effect(スクロール縁のぼかし)が
  `CABackdropLayer` の `filters.gaussianBlur.inputRadius` を 0.25s で animate し続けるため、
  **無限反復ではなく既存の除外(match/punchout/SDF)にも掛からず**、静止区間が一度も作れない。
  結果 Compose iOS では launch 直後の 1〜2 アクションが毎回 cap 2500ms に張り付いていた
  (実測 actionMs 2,521ms。温まった後の同じ操作は 107ms。SwiftUI/Flutter には出ない)。
  `keyPath` が `filters.` / `backdropFilters.` で始まるアニメーションは無視する。
  **位置・不透明度・transform は除外しない**ので本物の遷移待ちは従来どおり効く
  (この修正で CMP の in-app スイートは 74s→57s)。
  同種の問題は「cap 打ち切りが常態化しても黙っている」ため見つけにくい —— 疑ったら
  `InAppSettle` に一時 NSLog を入れて `xcrun simctl spawn <udid> log stream` で層と
  キーを1回採るのが早い(手順は docs/verification/)
  修正後: シナリオ×15 + フルスイート×3 で失敗ゼロ・救済発火4回
- **inapp の type は Compose Multiplatform でも通る**(2026-07-21 更新。それ以前は XCUITest 切替が
  必要だった)。Compose は「フォーカスアンカーの OverlayInputView(入力セレクタ非応答)」と
  「実際のキーボード受け口 IntermediateTextInputUIView(UIKeyInput 準拠・isFirstResponder)」が
  **別ウィンドウの別ビュー**のため、first responder を1つ捕まえるだけでは前者を拾って 409 になる。
  現実装(InAppInput.m)は「insertText: に応答し かつ isFirstResponder のビュー」を全ウィンドウから
  探して最優先で挿入する(実測 253〜358ms。XCUITest attach 経路 1.0〜1.3s の約1/4)。
  - `preferTypeDriver`(Compose 検出時に最初から attach)は廃止(常に false)。
    `/status` の `uiFramework` 申告は情報として残存
  - 安全網: inapp type が 409 なら `typeDriver`(`AppAttachDriver`)でリアクティブ切替
    (`StepOutcome.driverFallback` に記録。**ロケータの `passedViaFallback` とは別物**で、
    セレクタ更新の提案は出さない=セレクタは正しくドライバが変わっただけ)。
    409 メッセージには first responder 診断が付く
  `AppAttachDriver` は XCUITest ブリッジへ `/session {activate:true}`(実行中アプリを再起動せず
  状態保持で attach)→ snapshot → type(ref は typeDriver 側 snapshot で取り直す。ref 名前空間は
  ブリッジごとに独立)。**springboard 参照の SystemUIDriver(fallbackDriver)はアプリ要素を一切
  見られないため type の受け皿にできない**(実測: snapshot は SBSwitcherWindow 等8要素のみ)。
  用途を混ぜないこと。XCUITest ブリッジが無いとき(xcuiPort 無し)はこの経路は無く、409 メッセージが
  xcuitest プロファイルへ誘導する
- **`type` の `\n` は iOS では XCUITest 経路へ回す**(2026-07-28。`StepExecutor` の type 2経路):
  `typeText` は改行を **Return キー押下**として発火するので **iOS 既定の挙動そのもの**になり、
  「改行を入れるか確定アクションを撃つか」をフィールドが決める。in-app の `insertText` は改行の解釈が
  フレームワーク任せで OS 既定と揃わない(Compose は完全一致 `"\n"` だけアクション化、Flutter は握り潰す)。
  **`\n` を含まない入力は両経路で結果が同じ**なので、この振り分けは**モード間の観測可能な差を生まない**
  (モードはツール内部の最適化であり、シナリオから見えてはいけない)。判定は `typeDriver` の有無だけで
  行い、プラットフォーム判定は書かない(`typeDriver` は iOS の inapp モードでしか設定されないため自動的に
  iOS 限定。条件を二重に持つと将来ずれる)。**ロケータ無しの `type`** も同じ規則で回るが、ref が無く
  attach 前だと 409 になるため `AppAttachDriver.type(ref: nil)` に activate 再試行を入れてある
  (ref 有りには入れない — activate が refFrames をクリアする)
  **tap の直後のロケータ無し・改行入りの type は、先に焦点が立つのを待つ**(`awaitFocusBeforeKeyInput`。
  pressEnter と同じ待ちで、焦点が既に立っていれば 1 枚読むだけ)。この経路は焦点救済も読み返しも通らず、
  Return で即確定して打ち直せない —— E2E-RN で `tap(#field_single)` → `type("pqr\n")` が "pq" で確定した
  (9 月の 386 回で 1 回。tap が速くなった v110 以降に初出。単独 10 回では再現せず、帰属は未確定)。
- **iOS の Enter はフレームワークごとに受け口が違う**(2026-07-28 実測。吸収は
  `FTPressEnterOnComposeFirstResponder` の1箇所。**名前は Compose 由来だが実態は
  Compose / UITextField(UITextView)/ Flutter の3経路を吸収する** —— 改名すると
  ブリッジ指紋が変わり版上げと入力系 E2E が要るので見送っている): Compose は `insertText("\n")` が IME アクションに
  変換される。**UITextField は変換されない**ので UIKit が Return で行うこと自体を再現する
  (`textFieldShouldReturn:` + `EditingDidEndOnExit`。SwiftUI の `onSubmit` もこの経路)。
  UITextView は Return = 改行挿入なのでそのまま `insertText("\n")`。
  **この関数を通るのは `pressEnter` だけ**(`type` の `\n` は上記のとおり XCUITest へ回るので
  in-app の `handleType` には届かない。XCUITest ブリッジが無い(xcuiPort 無し)ときだけ来る)。
  **React Native は `RCTUITextField`/`RCTUITextView` が UIKit 派生なのでこの UITextField/UITextView
  経路をそのまま通る**(新しい分岐は不要。2026-08-08 実測。E2EAppRN/docs/ui-contract.md)。
  **Flutter は engine の私有 API へアクションを配送する**: `insertText("\n")` は engine に
  握り潰され(文字も入らずアクションも出ないのに 200 が返る最悪の形)、inapp モードの xcuitest
  フォールバックも **in-app の合成タッチが立てたフォーカスに届かない**ため、in-app で完結させるしかない。
  `[view textInputDelegate]` → `flutterTextInputView:performAction:withClient:` を
  `returnKeyType`(UIKit の公開 enum)からの逆写像で呼ぶ。**私有 API なので各段で存在確認し、
  欠けたら 409 に縮退する**(E2EAppFlutter/docs/ui-contract.md。退行の検知はシナリオ 18 が唯一)
- **Android の Enter はキーイベントでは届かない**(2026-07-28 実測): ソフトキーボードが出ていると
  `input keyevent 66`(gRPC の名前付き "Enter" も同じ)は **View/XML の `EditText` に到達しない**
  (IME が消費する)。`adb shell ime disable <id>` で IME を止めると同じキーで発火する。
  **Compose の入力欄は同条件でも発火する**ため、Compose だけで検証すると気付けない。
  そこで `pressEnter`(と `type` の末尾改行)は **a11y の `ACTION_IME_ENTER`**(ブリッジの
  `/pressEnter` → `InputInjector.pressImeEnter`)を既定にし、404/409/501 のときだけキーイベントへ
  落とす。Shirates も Android は `mobile: performEditorAction` = エディタアクション直実行で、機構は同じ。
  受け側に届く actionId が経路で違う(a11y = フィールドの imeOptions / キーイベント = `IME_NULL`)ので、
  SUT 側は**両方受理**する必要がある(E2EAppAndroid/docs/ui-contract.md)
- **短いラベルは別項目の要約(summary)にも contains 一致し「曖昧解決不能」で throw する**:
  例 `"ディスプレイ"` は行 `"ディスプレイとタップ"` と、無関係な `"ユーザー補助"` の要約
  `"ディスプレイ、操作、音声"` の両方に当たる。実 UI の完全ラベルに寄せる(`"ディスプレイとタップ"`)か
  一意な部分文字列にする(2026-07-16 実測)
- **`||英語` フォールバックはデバイスが英語ロケールのときだけ発火する**(実 UI が日本語なら英語候補は
  一切当たらない)。ja-JP フリートでは日本語プライマリが唯一の頼りで、OS 改名で陳腐化すると即ハード失敗する
  (英語ロケール機なら英語 FB で延命するため「たまに緑」に見えて切り分けを誤らせる)。
  プライマリは対象 OS/ロケールの実ラベルに合わせて維持する
- **既定は非スクロール**(現在画面のみ判定)。一覧の折り返し下にある項目は
  `tap`/`exist` の `scroll:` 引数(または `withScrollDown { }`)で探索するか、
  直前に `scrollTo(セレクタ, maxSwipes:)` で送ってから確認する。
  テキスト検証(`textIs` 等)は探索手段を持たない(次項)
- **テキスト検証コマンド(`textIs` / `valueIs` / `textContains` / `textMatches` /
  `textStartsWith` / `textEndsWith` / `textIsNot` / `textIsEmpty` / `textIsNotEmpty`)に
  `scroll:` を足さない**(ユーザー決定 2026-07-27)。これらは**静止した画面のテキストを詳細に
  検証する**ためのもので、条件を満たすまで自動でスクロールする挙動は**望まれていない**。
  `exist` と `tap` が `scroll:` を持つのは「在るか」を探す・操作するコマンドだから。
  一貫性を理由に対称化しないこと(**再提案しない**)

### アプリのライフサイクルと OS 分岐

- `launchApp(bundleID?)` / `restartApp(bundleID?)` / `terminateApp()` / `clearAppData(bundleID?)`
  はロケータを取らず、`FTDriveCore.performCustom` でドライバを直接呼ぶ(スナップショットも
  セレクタ解決も挟まない)。bundleID 省略時はこの run の既定アプリ(上記 ScenarioAppResolution)。
  `restartApp` は terminate の失敗を無視して launch する(既に落ちている状態から呼べる)
- **器のディレクトリ名は `TestProjects/<name>/scenarios/`**(2026-08-05 に `Projects/` /
  `Scenarios/` から改名。profiles / reports / results / docs と大小を揃えた)。
  **旧名も解決する**: `ProjectStore.projectsDir` は `TestProjects/` が無ければ `Projects/`、
  `TestProject.scenariosDir` は `scenarios/` が無ければ `Scenarios/` を見る
  (既に導入済みの受け手は旧名のままで、`Projects`→`TestProjects` は大小が違うので
  macOS でも解決できない)。`Scripts/preflight.sh` も両方を見る
- **`home` の機構は iOS 実機とシミュレータで違う**: シミュレータは `XCUIDevice.press(.home)`、
  **実機は springboard の下端フリック**(`press(.home)` が実機では ok を返すのに効かない。
  2026-08-05 実測)。フリックは**速さでホーム/アプリスイッチャーが分かれる**ので数値を変えない
  (下端から 1/4 強・0.08 秒相当・press 0.05)。判定は `/appstate` ではできない
  (実機の `XCUIApplication.state` はスイッチャー表示中でも foreground を返す)
- **`clearAppData` の機構は OS で違う**: Android = `pm clear` / iOS = データコンテナの中身を
  削除 + **cfprefsd の入れ直し** + `simctl privacy reset all`。**中身の削除だけでは
  NSUserDefaults が戻る**(cfprefsd がドメインを抱えていて、次の起動で消したはずの値を配り
  plist を書き直す。2026-08-05 実測: 消して起動を3回で launch_count が 2→3→4)。
  `launchctl kickstart -k system/com.apple.cfprefsd.xpc.daemon` で 3/3 初期化される。
  **順序は「ファイルを消してから入れ直す」**(先に入れ直すとディスクの旧値を読み直す)。
  `defaults delete` は効かず(サンドボックスのドメインが見えない)、`killall` はシムに無い。
  `ClearAppDataContractTests` が2段の欠落を検出する。
- **simctl / devicectl の対象特定は `BridgeClient.resolveTarget` に一本化**(install /
  uninstall / clearAppData)。`/status` はデバイス名しか返さないので名前で引き当てるが、
  **名前をそのまま simctl へ渡さない**: 実機に繋がっているとき「Invalid device」という
  的外れな失敗になり、**同名のシミュレータが起動していればそちらを操作してしまう**。
  引き当ては booted シミュレータ優先 → 実機(devicectl 一覧は**必要になったときだけ**引く。
  数百 ms かかる)→ どちらでもなければ従来どおり名前。実機と分かれば install/uninstall は
  devicectl・clearAppData は 501。`DeviceTargetResolutionTests` が規則を固定する**権限はコンテナの外(TCC.db)にある**ので後者を省くと
  「Android では権限ダイアログが出るのに iOS では出ない」という OS 差が黙って生まれる
  (`pm clear` は権限もリセットする)。**ドライバの層では iOS はシミュレータ専用**(実機は devicectl に同等手段が
  無く 501)。DSL と MCP は実機ではアンインストール + 入れ直しに切り替える(`reinstalled-to-clear-data`)。1件でも消せなければ失敗させる(部分削除を「消えた」と言わない)。
  キーチェーン/Keystore の値は残るので、そこに初回起動判定を置くアプリでは再現しない
- `ifCanSelect(セレクタ, waitSeconds:) { }.ifElse { }`: 「出るか不定」の唯一の表現手段
  (`optional:` 全廃後)。既定 `waitSeconds: 0` = 即時1回判定。**`FTRuntime.perform` を
  通らないので構文検証を個別に呼ぶ**(上記 `validationError` 項)
- `ios { } / android { }`: 対象 OS のときだけ実行する。**中身が実行されなかったことは警告しない**
  (ブロックに何が書かれているかは実行しないと分からないため)

### ディープリンク配送(`openURL`/`launchApp(url:)`)

- `openURL(url)` = 起動済みアプリへの warm 配送(**再起動しない**)。`launchApp(bundleID?, url:)` は
  restartApp 相当の再起動 → 同じ配送を1コマンドにまとめたもの
- **配送はホスト側の外部コマンドで行い、ブリッジを経由しない**(ブリッジ版を上げる必要が無い):
  iOS シミュレータ = `xcrun simctl openurl` / iOS 実機 = `xcrun devicectl device process openURL`
  (**未実行検証**)/ Android = `adb shell am start -W -a android.intent.action.VIEW -d '<url>' <package>`
- **Android は URL をシングルクォートで包む**(`adb shell` の先はデバイス側シェルなので、
  クォート無しだと URL 内の `&` でコマンドが切れる)。**package は必ず付ける**
  (明示パッケージは解決先をそのアプリに固定し、App Links の検証状態に依存させない)
- **`am start` の失敗判定は `Error:` の有無だけ**。`Warning: Activity not started, intent has
  been delivered to currently running top-most instance.` は**成功**(singleTop アプリへの
  warm 配送の通常応答)。ここを失敗扱いにすると Flutter/RN への配送が全滅する

### openURL 後の SpringBoard 確認アラート自動了承(iOS)

- iOS 27 のシミュレータはカスタムスキームの `openurl` に対し「"<表示名>"で開きますか?」の
  確認アラートを出すことがある(アプリが前面でも・スキーム登録が1アプリだけでも出る)。
  **同意は端末+アプリの組で永続する**(以後は無警告で配送される)
- **アラートはアプリスコープのスナップショットに1要素も現れない** —— `com.apple.springboard` へ
  attach したときだけ木に出る(既存の springboard 参照 SystemUIDriver/fallbackDriver と同じ経路。
  「type の受け皿にできない」制約とは別用途)。アプリ側から見ると「何も起きなかった」ようにしか
  見えず、沈黙して失敗する
- fleetest の対処: `openURL` 直後に springboard へ attach → アラートを同定 → 確定ボタンを押す →
  対象アプリへ戻す。**`(デバイス, bundleID)` ごとにプロセス内で1回だけ**試みる
- **同定条件**(3つとも満たさなければ何も押さない): アラートの label が**表示名を引用符で
  囲んだ形**(`"名前"`)を含む / ボタンが**ちょうど2つ** / 押すのは**ツリー順で最後**
  (右側=確定)。**素の部分一致にしてはいけない** —— 表示名は互いの部分文字列になり得る
  (`FT E2E` ⊂ `FT E2E RN`。iOS の4 SUT が同居する E2E シミュレータで実際に起き得る形)
- **XCUITest ブリッジが無いとき(in-app ブリッジ単独)は自動了承できない**(in-app ブリッジの `/session` は自分の bundle
  以外を 409 で拒否するため springboard を見られない)。inapp モードでは XCUITest ブリッジの接続が
  受け持つ。4 SUT の `ios-inapp` プロファイル全緑で inapp モードの経路の動作を確認済み

### Shirates(Classic) 準拠の方針と承認済みの差分

**コマンド名・引数名・既定値・挙動は Shirates(Classic) をそのまま踏襲する**。独自の「改良」を
しない — 差分を作るときは実装前にユーザーへ提示して判断を仰ぐ(経緯: 独自アレンジを重ねて
指摘を受けた)。迷ったら `~/github/wave1008/shirates-core` のソースを読んでから書く。

**準拠状況の正典は [shirates-parity.md](../shirates-parity.md)**(何が揃っていて何を持たないかの
全リスト)。**コマンドを足す・名前を変えるときに更新するのは向こう**で、こちらの表は
**理由の説明が要る代表例**を抜き出したもの(挙動差を見つけたら、まず parity に載っているかを見る。
載っていない挙動差は準拠漏れ = バグとして扱う):

| 差分 | 理由 |
|---|---|
| `FTScrollDirection` に `None` が無い | 「スクロールしない」は引数の省略(Optional)が担う |
| スクロールの時間指定(`scrollDurationSeconds` / `scrollIntervalSeconds`)が無い | 現行のフリング前提の実測値(Android 300ms・端送り 150ms+fling / iOS 端送り velocity 1500)を捨てることになるため。**間隔は固定 sleep でなく静止待ち**で担保する。`scrollFrame` とマージンは 2026-08-02 に実装済み(既定値だけ fleetest の実測で決める) |
| `(a\|b)&&[2]` は「各節の2番目」(Shirates は和集合の2番目) | 節ごとに `[n]` を持つ fleetest の構造をそのまま使う |
| `!` 短縮形で序数を否定できない(`![2]`) | 候補集合を絞れず黙って無視されるため実行前エラーにする |
| テキスト検証(`textIs` 等)に `scroll:` が無い | ユーザー決定(上記「再提案しない」項) |
| `thisIs` 系が素の値にも直接生える(`FTValue` 転送) | Swift は非 Optional に `Any?` 拡張が生えない(言語制約の吸収であり挙動差ではない) |
| 相対セレクタの引数の `(a\|b)` は括弧を自分で書く | `:right(...)` の括弧が引数の括弧で `\|` の囲みにならないため |
| `scrollFrame:` に型付きセレクタ(`Sel`)版が無い(String 固定) | ユーザー決定 2026-08-04・**再提案しない**。1対1を保証するのは**対象セレクタ**まで。`scrollTo` は対象と `scrollFrame` の両方を取るためオーバーロードが 2×2 になり、他20コマンドと合わせて語彙が増える割に、`scrollFrame` は生成コードにほとんど出ない(下記「型付きセレクタ」) |
| フローベース相対セレクタ(`:flow` 等)を持たない | 根拠の無い調整値を要求する(上記 2026-07-26 決定・再提案しない) |
| `pressEnter` の iOS 実装がソフトキー tap ではない(xcuitest = `typeText("\n")` / inapp = 受け口ごとに Compose は `insertText("\n")`・UIKit は delegate 再現・Flutter は Flutter engine への配送) | キーボード要素をスナップショットから除外しているため tap できない。受け口で機構が違うのは iOS 側の事情(上記「iOS の Enter は…」)。観測できる挙動(Return キー相当)はいずれも同等 |
| `back()` は Shirates の `pressBack`(Android 専用)を home()/appSwitcher() と同列の OS 差吸収コマンドとして両 OS 提供(iOS はエッジスワイプ) | iOS に物理バックが無く、コマンド語彙を OS で割らない方針 |
| `swipePointToPoint` / `swipeElementToElement` に withOffset・offsetY・intervalSeconds・repeat・safeMode・marginRatio・adjust が無い | ブリッジの drag が単発ジェスチャのため |
| `optional:` 引数を持たない(Shirates は `throwsException: false`) | ユーザー決定 2026-08-02・**再提案しない**。「出るか不定」はアプリ内メッセージなら `irregularHandler`、その場限りなら `ifCanSelect { }` で表す。空振りを黙って許す引数が操作系に付いていると、腐ったセレクタが緑のまま残る。掴めないことが答えになり得る `select` だけは失敗させず空要素を返す |
| `notExist`(Shirates は `dontExist`) | 否定の意味が読み取りやすく `exist` との対称も保てる(ユーザー決定 2026-07-31・**再提案しない**) |
| `existAll` / `dontExistAll` を持たない | `exist` のチェーンで書く方が保守しやすく、要素ごとに `waitSeconds:` / `scroll:` を指定できる(ユーザー決定 2026-07-31・**再提案しない**) |
| `clearInput` がソフトキー/Appium clear 機構ではない(xcuitest=末尾タップ+delete 連打 / inapp=first responder のテキスト置換(WebView の欄は全選択+削除1回で、確かめは呼び手が木で行う)/ Android=ACTION_SET_TEXT "") | キーボード要素を snapshot から除外しているため(pressEnter と同じ事情) |
| キーボード可視の取得元がブリッジで違う(iOS xcuitest=AX ツリーの `.keyboard` ノード / iOS in-app=`UITextEffectsWindow` の可視判定 / Android=ホストが見る dumpsys の InputMethod window) | IME が別プロセスの window でアプリの a11y ツリーに出ないため(iOS の2経路の事情は下記「キーボードの観測と `hideKeyboard`」) |
| `waitForDisplay` / `waitForClose` に `throwsException` が無い(タイムアウトは常に失敗として記録) | `optional:` 全廃(2026-08-02)と同じ方針。空振りを許すと腐ったセレクタが緑のまま残る(2026-08-03 承認) |
| `waitForClose` の expression 省略(Shirates の直前セレクタ再利用)は不可 | 2026-08-04 に `lastElement`(暗黙の要素保持)を実装したので当初の理由(概念が無い)は消えたが、**省略形は引き続き置かない** —— 待っている対象がソース上で読めなくなり、直前のコマンド次第で待ち先が変わる。値の読み出しと違って**待ちは何を待つかが読めることが要**(2026-08-03 承認の判断を維持) |
| `waitForDisplay` の判定は `exist` と同じ可視性込み(Shirates は `safeElementOnly=false` のツリー存在判定) | コマンド名の意味(displayed)に沿い、既存の exists 検証機構をそのまま使う(2026-08-03 承認) |
| 待ち系(`waitForDisplay`/`waitForClose`/`appIs`)のポーリング間隔が `PollBackoff`(100→1000ms)である(Shirates は 0.2s 固定) | ポーリングは既存機構の再利用が契約(PollBackoff.swift「コピペ禁止」)。既定の待ち秒数 15.0(`WAIT_SECONDS_ON_ISSCREEN`)は踏襲(2026-08-03 承認) |
| `screenshot` が `force`/`onChangedOnly`/`withXmlSource` を持たない(`filename:` のみ) | この3引数は Shirates の auto-screenshot 機構(毎操作の自動撮影・変化なしスキップ・XML dump)の制御で、fleetest はその機構自体を持たない(撮るのは失敗時の証跡と `screenshot()` の明示呼び出しだけ)。画像はレポートの該当ステップ直後に埋め込む(2026-08-03 承認) |
| `flick*` は画面基点の8種のみで、`scrollableElement`/`safeMode` を持たない。`flickAndGo*` 一族・要素基点 `flickTo*`/`flickOut*` は持たない | 領域指定は `scrollFrame` のセレクタ式で足りる(既存の scroll 系と同じ判断)。`flickAndGo*` は scroll 系の別名で語彙を増やすだけ(2026-08-03 承認) |
| `verify` が Shirates の `MANUAL` 相当(強制 passed 化)を持たず、アサーション0個は**ステップ状態 inconclusive** | 2026-08-03 ユーザー決定。MANUAL の語彙は持たない(`manual`/`knownIssue` を入れない既存方針と同根)が、失敗にもしない。passed でも failed でもない中間状態(`StepResult.Status.inconclusive`)として理由つきで記録し、シナリオは中断しない。弱い修正提案も残す |
| `appIs` はニックネーム解決を持たず ID(iOS=bundle ID / Android=package)を直接書く | fleetest はアプリのニックネーム機構自体を持たない(既存方針。2026-08-03 承認) |
| `packageIs` を持たない | 2026-08-03 ユーザー決定(いったん実装後に削除)。ニックネームが無い fleetest では `appIs` が ID 直指定のため Android で完全に同じ検査になり、同じことを2通りで書ける語彙になる。**再提案しない** |
| `tapAppIcon` が `auto` 相当のみ(method 切替・マクロ機構なし) | 対象は実質エミュレータ/シミュレータで `auto` の分岐だけで足りる。名前省略時の既定は installApp と同じ形で親が解決する(`--app-name` = プロファイルの `appName`。2026-08-03 決定。実行自体は子のまま — UI 操作は「1シナリオ=1プロセス=1ドライバ」の子の責務で、親が同じランナーを叩くと二重クライアントの事故型になる) |
| `installApp` の実行主体がオーケストレータ(親プロセス)である | 2026-08-03 ユーザー決定。子(シナリオサブプロセス)は install の依頼だけを親へ送り(stdin/stdout RPC)、親が実行プロファイルの `appPath` を解決して実インストールする。パス解決の優先順は明示引数 > プロファイルの `appPath`(Shirates の `appPackageFile` 既定に一致)。オーケストレータ無しの単独実行だけ、子が直接 `driver.install` を呼ぶ従来経路にフォールバックする(パス解決は 明示引数 > `--app-path` > 明示エラー)。iOS の inapp モードではインストールで in-app ブリッジが道連れになるが、次の `launchApp()` が再注入する(注記は実行中の ℹ️ ログにのみ出る。保存レポートには残らない) |
| `enabledIs(expected:)`/`checkedIs(expected:)`(生文字列親形)を持たず、糖衣形 `enabledIsTrue/False`・`checkIsON/OFF` のみ | 生値比較は OS 依存(checked の iOS "1"/"")で、正規化済み Bool と衝突する。糖衣形は OS 差を吸収済みで fleetest の正規化と一致(2026-08-04 ユーザー決定。旧 `isEnabled` 系4名からの改名も同決定 — Is 後置の社内語彙とも揃う) |

### `clearInput` の受け口ごとの機構と Flutter の縮退

嘘の成功(消えていないのに 200)を構造的に潰すため**3層**で守る:

1. **実行**: 受け口ごとに機構が違う。UITextField/UITextView は `.text = ""` + 変更通知の明示発火
   (`.text` 代入は `insertText:` と違い `EditingChanged`/通知を自動発火しない)/ その他 UITextInput
   (Compose の `IntermediateTextInputUIView` 等)は全文書レンジへ `replaceRange:withText:@""`
2. **受け口の自己検証**: 置換後に**読み返して**空を確認する。読み返せない受け口
   (`ftRemainingTextLength` が `NSNotFound`)は**空に見えても成功を主張しない** → 409
3. **ホストの事後検証**: `StepExecutor` が clear 後に値を確認し、残っていれば typeDriver へ、
   それでも残れば失敗。ref 無し版は `ElementInfo.focused` で対象を突き合わせる
   (`focused` を足したのはこのため。特定できないときは検証をスキップ = 検証不能を失敗にしない)

**Flutter iOS の in-app は非対応**(409 → xcuitest フォールバック)。**Flutter engine への editing state 配送は
評価のうえ不採用**(3回のデバイス実測):`flutterTextInputView:updateEditingClient:withState:` は実在し
(ランタイムのメソッド列挙で確認)、client も state のキー集合も正しいが、**Dart 側の
`TextEditingController` は空にならない**。`replaceRange` も view のローカル状態しか変えない
(併用すると Flutter engine への旧値の再通知が同期配送を上書きする挙動も観測)。**推測で私有 API を
積み増さない**方針(pressEnter の Flutter 対応と同じ規律)に従い、409 で既知の縮退へ落とす。
**pressEnter と違い clear は xcuitest フォールバックが届く**(ref 有/無とも実測。1.1〜2.2s)ので
機能は成立する。**再提案しない**(やるなら Flutter engine 側の公開経路が増えたとき)。

`type(sel, "…", replace: true)` はこの3層をそのまま使う(`StepExecutor` の `performClearInput`/
`performClearInputFocused` を type の前処理としても呼ぶだけ)。clear が失敗すれば type は撃たない。

### キーボードの観測と `hideKeyboard`

**観測(`keyboardIsShown` / `keyboardIsNotShown`)は3経路すべてで動く**が、取得元が OS で違う:

- **iOS xcuitest**: AX ツリー走査中に `.keyboard` ノードを見たか(`app.keyboards` クエリは使わない
  — キーボードが別プロセス扱いでタイムアウトする。`handleType` のコメントと同じ事情)。
  **「非表示」を確定できない**(見なかった = 不明で `keyboardShown == nil`)ため、
  `keyboardIsNotShown` はこのブリッジでは通らない(下記の nil 規約どおり明示的に失敗する)
- **iOS in-app**: **`UITextEffectsWindow` の可視判定**。キーボードはキーウィンドウの外に載るので
  AX ツリー走査では見つからない(閉じても window は残るため、画面内に張り出しているかで見る)。
  **非表示を false で確定できる唯一の iOS 経路**(2026-08-08 に一度 nil へ潰して
  `keyboardIsNotShown` を壊した — false を送り続けるのが契約)
- **Android**: ホスト側が `dumpsys window windows` の `InputMethod` window を見る(IME は別プロセスの
  window でアプリの a11y ツリーに出ない)。**dumpsys は固定費なので毎 snapshot では叩かない** —
  `AppDriver.captureKeyboardStateOnNextSnapshot()` を assert の直前に呼んだときだけ払う。
  採らなかった snapshot は `keyboardShown == nil` = 不明で、**nil を「非表示」と解釈しない**
  (`keyboardIsNotShown` が黙って通る嘘の成功になるため、明示的に失敗させる)

**キーボードが覆う実矩形は別フィールド `SnapshotResponse.keyboardFrame`**(2026-08-08。
取得元・罠・読み手は上記「ソフトキーボードの遮蔽」の表)。keyboardShown が可視性の Bool、
keyboardFrame が遮蔽警告用の矩形で、**申告できる条件が違う**(例: in-app は通知値が無いと
frame を申告しないが shown は言える)ため統合しない。

**`hideKeyboard` は Android・iOS とも動く**(ユーザー方針: 「人が操作できないときだけエラーにし、人ができる操作はツールも
最善を尽くす」。以前は iOS を「空白点タップは透明なタップ領域を踏む副作用があるので採らない・再提案しない」としていたが、この方針で置き換えた)。
出ていないときは何もせず成功する(冪等)。

- **Android**: 戻るキー。**出ているときだけ撃つ**(出ていないと画面が戻ってしまうので、dumpsys で可視を確かめてから送る)
- **iOS(モード非依存・ホスト側 `StepExecutor`)**: 木を取り、キーボードの上の領域を**下から上・左から右**の行で走査して
  「何もない点」を探す。何もない点 = どの要素にも載らない点、または画面幅の操作できない容器だけに載る点。
  **文字・画像の葉の上、操作可能・入力の型の要素の上、`overlayWindowFrames` の上には置かない**。撃つ前に in-app ブリッジの
  `POST /tapprobe`(ブリッジ版 195)で、その点がキーボード・ステータスバー・キーでない window(トースト等)の上でないことを確かめる。
  答えられないブリッジ(XCUITest)は木だけで決め、**木の最上端の要素より上は撃たない**(ステータスバーを避けるため)。
  点が無ければ待って探し直す(ステップの制限時間まで。トーストが消えることがある)。撃った後は最大 1.5 秒キーボードが閉じるのを待つ。
  閉じれば成功で、注記に撃った点を書く(撃った後にキーボードより上の要素が消えていれば、何も発火していないか確かめる注記も添える。
  要素の比較は id があれば id で)。**閉じなければ(または点が無ければ)Enter を送る**(ユーザー決定)。注記に、Enter が欄の
  リターンキーの動作(検索・送信・次の欄)も発火させることを書く。それでも出ていれば失敗
- **木で判定する理由**: Compose・Flutter・RN・SwiftUI は全てのタッチを1つの面で受けるので、OS の hit-test では背景とボタンを
  区別できない。区別できるのは a11y の木だけ。`/tapprobe` は木の判断を覆す裏取り(キーボード・
  ステータスバー・トースト)に限る
- **iOS Simulator での実測**: 背景タップで閉じるのは Compose(E2E-CMP)。Enter で閉じるのは SwiftUI(E2E-iOS)と Flutter。
  React Native は自前 SUT ではどちらでも閉じなかった。sut-ec-mobile の Compose の住所フォームは背景タップで閉じず Enter で閉じる
  (FD-2.5)

**`tap` / `type` / `clearInput` が対象の中心をキーボードの下に見つけたとき**: まず従来どおり容器をスクロールして持ち上げる。
それでも覆われていれば、**副作用のない手段だけ**でキーボードを閉じる(iOS = 上の背景タップから Enter フォールバックを除いたもの /
Android = `hideKeyboard` の戻るキー)→ 木を読み直して対象を解決し直し、注記を添えて操作する。副作用なしに閉じられないときは
何も触らずステップを失敗にする(文言に「リターンキーなら閉じられるが欄の動作も発火するので自動では押さない・意図するなら
ステップの前に `pressEnter()`」を書く。ユーザー決定: ここでは Enter を自動で押さない)。閉じた後に対象が消えた・まだ覆われていれば失敗。
**Android**: キーボードが出ている間に対象が見つからないとき(窓が縮み、下の要素が木に無い。Android は枠を申告せず `keyboardShown` だけの
ことがある)は、通常の待ちの後に戻るキーで閉じて**1回だけ**解決し直す。長押し(`holdSeconds` > 0)は従来どおり注記だけ。

**Android の adjustResize は「覆う」ではなく「消す」**(2026-09-05・実測 Pixel 4a): 窓がキーボード
上端まで縮み、覆われていた要素が木から脱落する(iOS は窓が縮まないため要素は木に残ったまま覆われる)。
判定は `TapTargetGeometry.KeyboardOcclusion.windowResizedAboveKeyboard` の1箇所——MCP の
`keyboardCoverageNote` と DSL の `StepExecutor.keyboardResizedHint`(「見つからない」失敗にだけ添える)
がここを写す。witness は `and-e2e_input_keyboard_resized` / `and-form_keyboard`。

### 型付きセレクタ(Sel)

セレクタ式は文字列1本なので、綴り誤りをコンパイラが捕まえられない(実行前の `validationError` が
唯一の防波堤)。これを型で潰す**併設経路**として `Sel`(Sources/FTDSL/Sel.swift)を追加した。
**文字列版は一切変えていない**(署名・ステップ説明文・記録すべて同じ)。

```swift
tap(.id("login_btn"))                            // #login_btn
tap(.id("login_btn").or(.text("ログイン")))        // #login_btn||ログイン
tap(.id("list").find(.type(.cell).nth(2)))       // #list >> .cell[2]
tap(.text("通知").right(.switch))                 // 通知:rightSwitch
select(.id("txt_result")).textIs("dialog=none")   // 検証はセレクタを取らない(下記)
```

- **引数の型が具体型なので先頭ドットで書ける**(`tap(.id(...))`)。`some FTSelectorConvertible`
  のような総称にすると leading-dot が効かなくなるため、各コマンドは String 版と `Sel` 版の
  **2 つの具体オーバーロード**を持ち、共通の impl(FTSelector を取る)へ畳む
- **対象セレクタを取るコマンドは String / Sel が1対1**(2026-07-29 に非対称を解消)。
  (スクロールの別名族は置いていない = 下記)
  **片方だけ足さない** — `Sel` を選ぶと別名族が使えない状態は「型付き経路を選ぶと機能が減る」
  ことを意味し、生成側を Sel 既定に寄せられなくなる。取りこぼしは
  `Tests/FTDSLTests/SelOverloadParityTests.swift` がソース走査で検出する
- **`scrollFrame:` 引数だけは String 固定**(Sel 版を持たない。ユーザー決定 2026-08-04・
  **再提案しない**)。1対1の対象は**対象セレクタ**であって全てのセレクタ式引数ではない。
  理由: `scrollTo` は対象と `scrollFrame` の両方を取るのでオーバーロードが 2×2 になり、
  他20コマンド(`scroll*` / `scrollToEdge` 系 / `withScroll*` / `flick*`)と合わせて語彙が一気に増える。
  一方で `scrollFrame` は**生成コードにほとんど出ない引数**(生成側は文字列版を出す既定)なので、
  「型付き経路を選ぶと機能が減る」の実害が最も小さい場所。
  `SelOverloadParityTests.testScrollFrameRemainsStringOnly` がこの決定を固定する
- **スクロールを関数名で指定する別名族(`*WithScrollDown/Up/Right/Left`・`*WithoutScroll`)は置かない**
  (ユーザー決定 2026-09-19。2026-08-02 の「別名は `maxSwipes:` だけ取る糖衣」という仕様を置き換えた)。
  指定は各コマンドの `scroll:` だけ = 同じことを2通りで書ける組み合わせを作らない(生成側の語彙のブレを消す)。
  Shirates の名前は `UnavailableCommands.swift` がコンパイルエラーで書き方を返す。**別名を再提案しない**
- 組み立てるのは**文字列版と同じ `FlowLocator`**。解決・実行・レポート・ヒールは完全に共通で、
  実行モードは分岐しない(`SelTests` が全構文について「文字列版と同じ FlowLocator になること」を固定)
- フィルタ系メソッド(`text`/`type`/`nth` 等)は常に「**現在の対象**」に AND する:
  相対ステップより前なら基準(アンカー)、後ならそのステップの対象。`nth` も同様に、
  相対ステップの後では ordinal(近い順)になる
- `exact` は match モードを**持たせない**(文字列版 `parseNamedFilter` と同じ正規化)。
  揃えないと同じ意味のセレクタが型付き版だけ別構造になり、比較・往復・ロケータの指紋のキーが割れる
- 表示テキスト(レポート・ロケータの指紋のキー)は `FTSelector.serialize` で**記法へ戻す**。
  `FlowLocator.summary` は表示用で型が `.button` ではなく `button`(=ラベル)に化けるため使わない
- 型付き経路は `FTSelector.structured` が立ち、実行時の構文検証を**通さない**
  (綴りはコンパイラが保証済み。かつラベルに `>>` 等の予約文字が入っても再パースで別物にならない)
- 型名は `SelType` の静的メンバ(OS 共通契約の5型 + エイリアス + 頻出型)。語彙に無いものは
  `.custom("...")`(先頭小文字へ正規化)
- **生成側(`ScenarioCodeGen` / explore 生成 / `/fleetest-scenario`)は文字列版を出す。
  Sel を既定にしない**(ユーザー決定 2026-07-30・**再提案しない**)。生成コードは
  **人が必要に応じてカスタマイズする前提**で、`Sel` は型指定を好む人のためのシンタックスシュガー
  という位置づけ。したがって `Sel` の利用が少ないこと自体は想定どおりで、「未使用だから撤去/既定化」
  という判断にはならない。**再検討条件**: 人がカスタマイズしない領域の生成が出てきたとき
  (そこは綴りをコンパイラに任せられるので `Sel` で生成する余地がある)

### 掴んだ要素の値の読み出し

`exist` の戻り値 `FTElement` から `.text` / `.value` / `.id` で**値そのもの**を取れる
(Shirates の `TestElement.text` 相当)。これが無いと期待値をシナリオに書き切るしかなく、
「注文番号を控えて後の画面で照合」「画面の合計を読んで計算に使う」が書けなかった。

- **新しいコマンドを足さない**。`exist` が既に解決した要素を持ち帰るだけなので、
  **追加のデバイス往復もステップ記録も発生しない**(`CommandDispatchTests` が
  「exist 1 回 = スナップショット 1 回」を固定している)
- 経路: `StepExecutor.resolvedElementThisStep`(`observedCheckedThisStep` と**同じ受け渡し形**)
  → `StepOutcome.resolvedElement` → `FTDriveCore.perform` が返す `PerformResult.element` →
  `FTElement.matched`。**成功時しか立てない** — 失敗・スキップ・dry-run・
  対象が1つに定まらない assert(`notExist` / `countIs` / `screenLooksLike`)では nil。
  アクション(tap 等)は解決時点で立ててしまうので `execute` が `isSuccess` で落とす
  (「掴めなかったのに値が読める」を作らないための契約)
- **再取得しない**(値の出所は最初の `exist` に固定)。最新の値が要るなら `exist` を書き直す
- 型は `String?`。`ValueAssertions` の `FTValue`(`Optional: FTValue where Wrapped: FTValue`)に
  乗るので `exist("#total").text.thisContains("1,200")` がそのまま書ける
- `checked` / `enabled` の**値**は足していない(語彙を増やさない。検証は `.checkIsON` / `.enabledIsTrue` で足りる)
- **チェーンは網羅する**(2026-07-30): セレクタを取り「その要素」を検証する自由関数は
  **すべて同名で `FTElement` にも生やす**。一部だけだと「どれがチェーンできるか」に規則が無く、
  書いてみてコンパイルエラーで気付くことになる。例外は要素を1つに定めない
  `notExist` / `countIs` / `screenLooksLike` のみ。**検証コマンドを足すときは両方に足す** —
  取りこぼしは `vscode-fleetest/test/ftElementChainSync.test.mjs` が検出し、
  繋ぎ先の取り違え(`textContains` が `textStartsWith` を呼ぶ等)は
  `Tests/FTDSLTests/FTElementChainTests.swift` が実行して検出する(**形と挙動で担当が違う**)

### 暗黙の要素保持(`lastElement`)

戻り値を受けていなくても直前に掴んだ要素を読める(Shirates の `TestDriver.lastElement` 相当)。
**鮮度のリスクを承知したうえでのユーザー決定**(2026-08-04。それ以前は「概念を持たない」が承認済み差分だった)。

- **更新点は1か所**: `Commands.swift` の共通経路 `perform(_:_:step:…)`。セレクタを取るコマンドは
  全部ここを通るので個々のコマンドに書き足さない(足し忘れると「どのコマンドで差し替わるか」の
  規則が崩れ、読み手が追えなくなる)。保持先は `FTDriveCore.lastResolvedElement`(DSL スレッド専有)
- **差し替えないのは要素を1つに定めないステップだけ**(`definesSingleElement`: `notExists` / `count`)。
  値の出所は `PerformResult.element` = 上記「掴んだ要素の値の読み出し」と同じ経路なので、
  **凍結・成功時のみ・dry-run は nil** の契約もそのまま継承する
- **掴めなかったときは空要素で上書きする**。前の要素を残すと**別要素の値を「今掴んだもの」として
  読む**ことになり、失敗が沈黙する(「空の結果は成功と見分けがつかない」と同じ型)
- **scene の切り替わりで捨てる**(`runScene`)。前の画面の要素は値も座標も古い
- **一度も掴んでいない読み出しは空要素 + 1回だけの警告**(`warnLastElementUnavailable`)。
  返す空要素には実在しないセレクタを持たせてあるので、チェーンした検証は必ず落ちる
- 規律の固定は `Tests/FTDSLTests/LastElementTests.swift`(差し替える/差し替えない・空になる条件)

### チェーンした検証の初回判定は掴んだ値で行う

`exist(…).textIs(…)` は**掴んだ時点の値で先に判定し、満たしていれば実機を見に行かない**。
満たしていなければ何もせず通常経路へ落ちる = 従来どおり取り直しながらポーリングする。
**ユーザー決定**(2026-08-04。それ以前はチェーンも毎回セレクタから解決し直していた)。

- **判定できるアサートの表は `FTCore/HeldElementAssert`**。比較そのものは
  `LocatorResolver.matchedText` / `negativeAssertSatisfied` を**呼ぶ**(独自に書くと、同じアサートが
  チェーン経路と実機経路で違う答えを出す)。値ベース(text/value/id/enabled)だけが対象
- **除外**: `exists` / `notExists` / `count`(今の画面の話で過去の値から言えない)、
  `checked` / `notChecked`(実機経路が「checked を観測したか」を追跡しており、飛ばすと
  `checkIsOFF` の誤用警告が消える)、`screenMatches` / `keyboard*`(要素の値を見ていない)
- **可視性照合が走る設定では高速経路に入らない**(`visibilityWouldBeChecked`)。条件は
  `occlusionFlip` の入口のうちステップ非依存の部分と同じものを見る。飛ばすと
  可視性検証が有効な run(fmTextVisibilityCheck か ocrTextVisibilityCheck)で誤った緑の検出が**静かに1つ消える**
- 記録は通常どおり1ステップだが、説明に `(from the grabbed value)` を付ける
  (レポートで「取り直していない判定」を見分けられるようにするため。durationMs は 0)
- **残る危険は「古い値が偶然期待に一致して待たずに通る」向き**。`textIs` は本来
  「そうなるまで待つ」検証なので、`lastElement` のように掴んだ場所から離れるほど確率が上がる。
  承知のうえでの決定で、docs/commands.md にも注意として書いてある
- 規律の固定は `Tests/FTDSLTests/HeldValueAssertTests.swift`(往復回数で「見に行っていない」ことを
  直接数える。**古い値では不一致 → 取り直して一致** も必ず通す)

### 検証の対象は「直前に掴んだ要素」に固定

`textIs("#btn_ok", "OK")` の形(セレクタを取る検証の自由関数)を**廃止**し、対象は
`lastElement` に固定した。**ユーザー決定**。3つの書き方が同義になる:

```swift
select("#btn_ok").textIs("OK")                  // FTElement のメソッド(判定の実体)
select("#btn_ok"); lastElement.textIs("OK")     // 保持要素を明示
select("#btn_ok"); textIs("OK")                 // 暗黙(トップレベルの自由関数。委譲のみ)
```

- **対象は31コマンド**(text/value の全対称26 + `enabledIsTrue/False` + `checkIsON/OFF` + `idIs`)。
  **`exist` / `notExist` / `countIs` / `screenLooksLike` はセレクタを取り続ける** —— 要素を1つに定めない
  (`exist` は掴む側なので当然セレクタが要る)
- **判定の実体は `FTElement` のメソッド1か所**。自由関数は `lastElement.<同名>` へ委譲するだけで、
  ステップ記録も往復回数も一致する(`HeldValueAssertTests.testTheThreeFormsAreEquivalent` が固定)
- **セレクタを取る形の unavailable スタブは置かない**(未リリースで移行案内は不要・ユーザー決定
  2026-08-04)。`textIs("#id", "OK")` はコンパイラの素のエラー(`extra argument in call`)になる
- **1引数形にセレクタらしい期待値が来たら実行前に落とす**(`expectedLooksLikeSelector`)。
  `textIsNot("#btn_ok")` のような書き方は「そのテキストではない」が常に真で**黙って緑**になる。
  逃げ道はチェーン形(対象が明示なので曖昧さが無い)
- 3つの書き方の対応は `vscode-fleetest/test/ftElementChainSync.test.mjs` がソース走査で見張る
  (FTElement のメソッド集合 = 委譲する自由関数の集合。旧形の復活も検出する)
- **コード生成も新形で出す**(`ScenarioCodeGen` / `ScenarioDraftCodeGen`)。索引
  (`CommandIndex`)は signature を `select(selector).textIs(expected, ...)` の形で載せ、
  summary に「対象は直前に掴んだ要素」と明記する —— 生成側は JSON しか見ないため

### 否定・状態・個数のアサーション

- **`notExist`** は「消えるまで待つ」。初回で不在なら即成功、在ればタイムアウトまで消滅を待つ
  (`exist` の poll と対称)。可視性(occlusion)は見ない — ツリーから消えたことが唯一の判定。
  **`scroll:` を渡す(または `withScroll*` ブロックに入れる)と意味が変わる**: その向きへ
  探索しながら探し、**見つかった時点で失敗**する(`exist(scroll:)` の裏返し)。
  見つからなければ従来どおり現在のビューポートでの消滅待ちに進む。
  inapp モードでは **不在を確定する側でだけ** `fallbackDriver` を1回照会する(pass 経路の固定費 1 回。
  システム UI のダイアログが primary の snapshot に映らないため。miss 毎に払う `exist` 側とは事情が逆)
- **`checkIsON` / `checkIsOFF`**(セレクタの `checked=`・スナップショットの `checked`/`indeterminate` 表示も同じ源)は
  **`FTCore.CheckStateReading` だけが読む**(オン / オフ / indeterminate / 不明の4値)。ワイヤの `checked` は
  true のときだけ送る(iOS = selected trait / Android = `isChecked || isSelected`)ので、オフと indeterminate は
  value から確定させる。実測(2026-09-18・iOS 27・両モード同値)と一次ソースで決めた規則:
  | 実装 | オン | オフ |
  |---|---|---|
  | Flutter の Checkbox/Switch・SwiftUI Toggle・RN の role=switch・WebKit | 型 switch + value "1" | value "0"(WebKit の indeterminate は "2"。ARIA / RN の語は mixed) |
  | RN の role=checkbox / radio | value に語 `checked` | 語 `unchecked`(OSS の RN は翻訳表が空 = 英語固定) |
  | Compose iOS | selected trait | 何も出さない(Switch だけは型 switch・value 無し = オフと読める) |
  | Flutter iOS の Radio | selected trait | 何も出さない(Flutter engine が value を出さない) |
  | Android | `isChecked`(checkable なら value "1"/"0") | value "0" |
  | DOM(WebView) | value "1" | value "0"(`aria-checked`・`indeterminate` も読む) |
  **value は型で絞って読む**(iOS は switch/checkBox、Android は入力欄以外)—— バッジの数字 "1" や入力欄の
  文字をオンと読まないため。**オンしか報告しない実装**は、同じシナリオで一度オンを見た要素に限り
  報告の欠落をオフと読む(`StepExecutor.checkStateReporters`)。**救えない形**: 状態を a11y に出さない自作の
  部品(SwiftUI の Button 等)/ オンを見る前のオフ / Flutter・Compose・Android の indeterminate(オフと区別不能。CheckStateClassifier の `[INDETERMINATE]` の見本で救える)。
  `checkIsON` を不明な要素に書くと「reports no check state」で落ち、`checkIsOFF` は通して run 終了時に警告する。
  **画像での判定(`FTCore.CheckStateClassifier`。Shirates Vision の移植)**: プロジェクトの
  `vision/classifiers/CheckStateClassifier/<ラベル>/` に見本画像(ラベルが2つ以上)があれば、要素の枠で
  スクリーンショットを切り、Create ML の画像分類器の1位のラベル(`[ON]`/`[OFF]` を含むか)で判定する。
  使う要素は実行プロファイルの `preferCheckStateClassifier`(既定 true = a11y より優先 / false = a11y が
  不明の要素だけ)。**DSL の `checkIsON(prefer:)` / `checkIsOFF(prefer:)` が1コマンドだけ上書きする**
  (`CheckStateSource` → `FlowStep.preferCheckStateClassifier`。優先はステップ指定 > プロファイル)。学習済みモデルは分類器ごとに1組だけ `.fleetest/vision/CheckStateClassifier/` に置き、隣の `digest`
  (画像の中身 + オプション + 学習器の版)が見本と一致しないときだけ学び直して上書きする。確認・学習・読み込みは
  分類器ごとの flock(`train.lock`)の内側で行い、ロックの中で digest を確かめ直すので、見本の更新1回につき学習は1回
  (`VisionClassifier.ensureModel`)。モデルは別名で書いて rename で差し替え、digest は最後に書く。
  学習の待ちは `DeadlineExclusion` で締め切りから引く。**見本は推論と同じ a11y の枠で切ったものを置く**
  (切り方がずれると別物に見える)。**見本に無い種類の部品は2クラスのどちらかへ必ず振られる**ので、
  優先オンでは同じ画面のスイッチ・ラジオの見本も一緒に置く(witness は E2E-iOS の scenario 08)。
  **推論のたびに対照(ラベルの違う見本2枚。学習の点検で正しく答えたものから `controlSamples` が選ぶ)も掛け、
  どちらかが自分のラベルに答えなければ答えを使わない**(`VisionClassifier.Model.classify`。checkIsON/OFF は a11y へ・
  `imageIs` は失敗)。壊れた Vision / Core ML は失敗を返さず、どの画像にも同じラベルを確信度 1.00 で答える
  (2026-09-19 負荷テスト: 手元の ANE が揺れている間に ON の crop を [OFF] 1.00 と 7 回。同じ crop・同じモデルを後で
  掛けると 20/20 [ON])。findImage の縮退の門(白との距離 0)は特徴量の経路だけを見るので、Core ML の経路には
  効かない。対照が2枚そろわないモデルは確かめない。
  **`imageIs`(DefaultClassifier)も同じ学習・推論(`FTCore.VisionClassifier`)を使う** —— 見本は
  `vision/classifiers/DefaultClassifier/` 以下の任意の深さ、ラベルは親フォルダの相対パスを `_` でつないだもの、
  判定は1位のラベルの最後の `[` 以降が期待値を含むか(Shirates の LabelUtility.getShortLabel)。
  同じ短いラベルが2つのフォルダにあるのは設定の誤り。見本に無いラベルは待たずに落とす。
  **`findImage` / `findImages` / `existImage`(`FTCore.FindImage`)は DefaultClassifier の見本をテンプレートに使う**
  (`existImage` は findImage と同じ探索を通り、見つからなかったときだけ失敗にする = 探索を2つ持たない): 候補は a11y 要素を
  枠(画面で切った見えている部分)で切り出したもので、見本とアスペクト比が許容幅(Shirates の式)に入るものだけを
  近い順に Vision の画像特徴量(`GenerateImageFeaturePrintRequest`)の距離で比べる。枠が同じ要素は1つに畳む。
  findImage の1位が閾値を超えたときの分類器による救済は **ラベル一致だけでは採らない**(分類器は見本のどれかの
  ラベルを必ず答える)—— 確信度が閾値以下か、そのラベルの見本との距離が閾値以下のときだけ(Shirates の
  `classifyFull` と同じ条件。`StepExecutor.classificationConfirmed`)。**見つからなくても失敗しない**(select と同じ)。
  見つけた要素の `FTElement.tap()` はセレクタで引き直さず、見つけた枠の中心を座標で叩く。
  **Vision の縮退の門**: 照合1回につき一様な白 32x32 の特徴量を1つ作り、見本との距離が 0 なら失敗にする
  (実物の見本と白紙は 1.44 離れる。2026-09-19 04:29〜04:32 に CMP iOS / RN Android / E2E-Android の別プロセスで
  同時に全候補が距離 0 になり、最初の候補を「発見」して別の行を叩いた。5分後には正常。Vision の失敗としては
  記録されない = 同一の答えなので、距離だけが手掛かり)。縮退中に作ったテンプレートの控えは捨てる。
  **見本の採取は `fleetest vision capture`**(推論と同じ `VisionClassifier.crop` で切る = 切り方のずれを作らない。
  状態に写らないラベル・括弧の無いフォルダ・短いラベルの重複は保存前に断る)。**学習の点検**(`VisionClassifier.selfCheck`):
  学習直後に見本の1枚1枚をモデル自身に掛け、見本と違うラベルを答えたものを `selfcheck.json` に控える。**閾値を
  持たない**(自分の見本を取り違える = 本番でも取り違えうる、という事実だけ)。出口はシナリオ終了時の弱い提案と
  `fleetest vision check`(警告だけ・exit 0)。**分類器の判定で落ちたステップと、見つからずに落ちた `existImage` は、判定に使ったスクリーンショット全体を
  レポートのそのステップ行に添える**(`StepOutcome.evidenceImage`。ファイル名の印は `image-judged-by-classifier` /
  `judged-by-findImage` = 24 文字で切られるので後者は短くしてある。切り出しではなく全体 = 判定した画面が失敗時の
  画面と同じかを見比べられる。通ったステップ・分類器を使わずに落ちたステップは持たない)。
  **`tap(sel, linkText:)` が OCR で文字を見つけられずに落ちたときも、OCR へ渡した最後の絵を添える**(印は
  `read-by-link-text-ocr`。失敗時の絵は判定の後に撮るので、OCR が見た絵とは別物になりうる)
- **状態フィルタ(`checked=` / `enabled=`)は型ではなく `#id` と併用する**(2026-07-26 実測)。
  同じ役割の要素でも型は SUT で割れるため(コントロール画面の無効ボタンは CMP では `button`、
  View/XML では `clickable`)、`.button&&enabled=false` のような型との AND は SUT 固有の式になる。
  `#btn_always_disabled&&enabled=false` なら 4 SUT 共通で通る
- **`enabledIsTrue` / `enabledIsFalse`** は `ElementInfo.enabled`(3 ブリッジとも埋めている)を見る。
  タイムアウトまで状態変化を待つ。「見つからない」と「状態が違う」を別メッセージで返す
- **`countIs`** は**ツリー上の**候補の個数。**可視性は見ない**(覆われた要素も折り返しの下の
  要素も1件に数える)。`exist` が(テキストの可視性検証を有効にした run で)可視性まで確認するのと
  **意図的に違う**: 件数ぶん FM を
  呼ぶことになり(FM は許可枠で制限される共有資源。PT-3.5)、
  リスト検証が実用的な速度でなくなるため。
  `requireVisible` 引数も持たせない。`||` は**候補集合の和**を数える(同じ要素が複数の節に
  マッチしても1度だけ)。スコープと併用してリスト件数を数えるのが主用途。
  **失敗時は節ごとの内訳を出す**(`実際 4(内訳: text=許可 2件 / text=別名 2件)`)。
  総数だけだと「どの節が想定より多く拾ったのか」が分からず、直すのに snapshot の取り直しが要る。
  重複は先に現れた節に数えるので**内訳の合計は必ず表示件数と一致する**(`LocatorResolver.unionByClause`)。
  **親子で同じ条件に当たっているとき**(ボタンとその内側の Text)は、直し方まで添える
  (`型で絞ると 3 件(例 .button&&…)`)。フレームワーク一般の性質で利用者は必ず一度は踏むが、
  メッセージが無いと `countIs("項目", 3)` が 6 を返す理由に辿り着けない(`StepExecutor.nestingHint`)
- **失敗メッセージのロケータ表示は節を `||` で連ねる**(`FlowStep.locatorSummary`)。
  以前は他の節を `(fallback: …)` と呼んでいたが、`||` が和集合になった今は
  「片方だけ使われる」という誤った期待を与えるため用語ごと直した(2026-07-27)

### 部分一致・正規表現・反復

- **`textContains` / `textMatches` / `textStartsWith` / `textEndsWith`** は `textIs` と同じ経路
  (可視性ガードつき)。`textMatches` は**部分一致の正規表現**(全体一致は `^...$`)。
  occlusion-guard には**実際に一致した部分文字列**を渡す(パターン文字列は画面に出ないため。
  `LocatorResolver.matchedText` が唯一の判定者)
- **否定・`value` 側の全対称**(2026-07-27。Shirates 準拠): `text*` の各モードに `*Not` を、
  さらに `text*` の全てに `value*` を対で持つ(`textIsNot` `textContainsNot` `textStartsWithNot`
  `textEndsWithNot` `textMatchesNot` `textIsEmpty` `textIsNotEmpty` `textMatchesDateFormat` と、
  同名の `value…` 一式)。判定は `LocatorResolver.negativeAssertSatisfied` に**1箇所だけ**置く。
  要素は在る前提でタイムアウトまで**値の変化を待つ**。
  **否定系と Empty 系は可視性(occlusion)を見ない** — 「見えていないこと」「空であること」は
  画面照合できないため(`requireVisible` 引数も持たせない)。「見つからない」と「条件不成立」は
  別メッセージ。`*MatchesDateFormat` は `DateFormatter`(`en_US_POSIX` 固定)で解釈できるかを見る
- **`thisIs` 系**(`ValueAssertions.swift`。`Optional where Wrapped == Any` の拡張):
  **デバイスに触れない**値の検証(API 応答・計算結果)。`thisIs/thisIsNot/thisIsTrue/thisIsFalse/
  thisIsEmpty/thisIsNotEmpty/thisIsBlank/thisIsNotBlank/thisContains(Not)/thisStartsWith(Not)/
  thisEndsWith(Not)/thisMatches(Not)/thisMatchesDateFormat/thisIsGreaterThan(OrEqual)/
  thisIsLessThan(OrEqual)`。1件=1ステップとして記録し、失敗は DSL コマンドと同じくシナリオを中断する
  (`FTDriveCore.handleFailure` を通す)。`FTElement.idIs` も同じ意味で「解決した要素の id」を見る。
  **Swift 固有の事情**: Shirates は `Any?` の拡張だが、Swift は非 Optional の値に Optional の拡張が
  生えない(`"abc".thisIs(…)` が型解決できない)。実装は `Any?` 側に1つだけ置き、
  素の値へは `FTValue` プロトコルの転送メソッドで生やす(利用者に `let v: Any? =` を書かせない)
- **`repeatWhileCanSelect(sel, maxLoopCount:)`** はセレクタが解決できる限り本体を繰り返す(上限 maxLoopCount)。
  各周回は `group` と同じ規約で `[名前 #n]` を前置して記録する。上限到達は失敗にしないが、
  **打ち切ったことは記録に出す**(`→ 10 回(上限に達したため打ち切り。まだ残っている可能性があります)`)。
  これが無いと「ちょうど 10 件だった」のか「まだ残っている」のかが後から読めない。
  dry-run は canSelect が常に true を返すため **1 周だけ**回してステップ列挙に留める
- **`doUntilTrue(title, waitSeconds:intervalSeconds:maxLoopCount:)`**(Shirates 準拠の名前):
  ブロックが true を返すまで繰り返す。**ブロックは同期(`() throws -> Bool`)で DSL スレッドで実行する**
  = 中で DSL のコマンドを呼べる(Shirates の基本形 `{ scrollDown(); canSelect(...) }`。`repeatWhileCanSelect` と同じ形)。
  以前はブロックを非同期のクロージャとして performCustom の中(DSL スレッドの外)で走らせていたため、中の DSL が
  全部スレッド違反になっていた(利用者向けの例すら動かなかった)。1周ごとに `"<title> #n"` の group として記録し、
  最後に結果を1ステップ残す。中のコマンドの失敗はシナリオ中断に従って止まる(重ねて記録しない)。
  throw したら**リトライせず**即 NG。**1つのステップではない**ので FTSync のコマンド上限は掛からず、
  `waitSeconds` / `maxLoopCount` だけで止まる。上限は時計で測り、中の操作の前でステップの減速が待った分は
  差し引く(`FTDriveCore.pacedMsTotal`)。dry-run は1周だけ回して中のステップを列挙する。
  Shirates の `retryOnError` / `throwOnError` / `throwOnOverMaxLoopCount` / `refreshCache` / `onTimeout` /
  `onMaxLoop` / `onError` は未実装(docs/shirates-parity.md)
- **`tap(scroll:)` / `type(scroll:)` / `exist(scroll:)`**
  (2026-07-27。Shirates の `tapWithScrollDown` 相当。**関数名の別名は置かない** = 下記「スクロールの語彙」):
  コマンド名の変種を増やさず引数で表す。**探索は同じステップに畳む**(`FlowStep.direction` /
  `maxSwipes` を tap/exists 自身に載せ、`StepExecutor.runScrollSearch` が解決前に走る)。
  実体は `scrollTo` コマンドと共有するので挙動は1箇所にしかない。
  探索終端の空打ちドラッグ(iOS)は**触る点が手前の要素に取られないときだけ**打つ
  (`pointIsTakenByFrontElement`。取られると覆っている要素が反応する。
  docs/verification/traps.md「スクロールした直後のタップ」)。
  **打つ相手の判定(`shouldEmptyDrag`)を起動時プローブの締切に預けない**(2026-08-15):
  あの締切は「suspend したアプリは TCP を受理して答えない」を素早く諦めるための値で、
  冷えた実機ブリッジが収まる保証は無い。外れて `uiFramework` が nil になると
  「不明なら打つ」へ倒れ、RN では横抜き 4pt が `pressRetentionOffset`(既定20pt)に収まって
  `onPress` が成立する = **`scrollTo` しただけで行が選択される**(E2E-RN S0100 を
  プローブ無応答で回して再現。`selected=row_40`)。アプリのフレームワークは
  **`AppUIFrameworkQuery` が静的な材料を先に見る**:**パッケージの目印**(規則は `UIFrameworkMarkers` =
  in-app ブリッジの自己申告と同じファイル。デバイスの応答が要らない。材料は .app / .ipa の両方 = `AppPackageReader`。
  **宣言した bundle ID が対象と一致するときだけ**。Flutter は
  `Frameworks/Flutter.framework`、Compose は実行ファイル(デバッグは `<exe>.debug.dylib`)の中の
  クラス名 `SkikoUIView` —— `compose-resources` フォルダはリソースを使わないアプリに無い。
  RN は React / hermes(vm) の framework か `RCTBridge`、SwiftUI は `App.main()` の呼び出し)→
  シミュレータに入っているバンドル(simctl。置き場と指紋を台帳に控え、同じデバイスなら2回目から撃たない)→
  **bundle ID ごとの台帳**(`AppFrameworkLedger` = `~/.fleetest/app-frameworks/`。規則の版が違う控えは使わない)。
  静的に決まらなければ in-app ブリッジの自己申告(対象アプリ自身の申告のときだけ)、それも無ければ **掴んだ要素のクラス名**(第3段。`AccessibilityClassHint` =
  XCUITest ランナーが XCTest の非公開辞書 `additionalAttributes[5004]` から `ElementInfo.axClass` に載せる。
  Compose / Flutter の要素は `UIAccessibilityElement` = ビューを持たずホストが自前でタッチを処理する側、
  RN は `UIView`・SwiftUI は `NSObject`・UIKit は実クラス名。根の走査に付いてくるので追加の往復は無い。
  UIKit の実アプリにも少数出る(地図 6/111)ので判定は掴んだ要素単位)、それも無ければ nil = **不明なら打たない**(2026-09-12 に反転):
  打って外れると UIKit / SwiftUI / RN の行が押されてアプリの状態が黙って変わる(物理 iPhone 13 で
  `ft_scroll_to` が診断画面を開いた)が、打たずに外れるとタップが吸われて失敗として見える。
  不明になるのは材料も台帳も無い**物理 iPhone だけ**(端末に入ったアプリの中身は devicectl でも
  端末上のランナーからも読めない —— サンドボックスが `Operation not permitted`。2026-09-12 実測)。
  そのときは run の log と MCP の応答に「判定できなかったので撃っていない」と1回残す。
  **別ステップにしない理由**: 利用者が書いたのは1コマンドなので記録も1行にする。
  合成ステップは**ソース行を持たない**ためジャンプも修正提案の照合もできず、説明の要る状態になる
  (2026-07-27 に一度その形で入れて、直した)。
  見つからなければ「N 回スクロールしても要素が見つかりません」で失敗(`select` だけは空要素を返して skipped)。
  既定のスワイプ上限は `FlowStep.defaultMaxSwipes`

### スクロールの語彙

**DSL のスクロールは全て「コンテンツ基準」**(`FTScrollDirection`。`.down` = 下に読み進める =
指は上へ動く)。**唯一の例外が `swipe(.up)`** で、これは生のジェスチャなので指の動き
(`FTSwipeDirection`)のまま。両者の写像は `FTScrollDirection.swipe` の**1箇所だけ**に置く
(`FlowStep.direction` はブリッジへ渡るジェスチャ側の語彙。DSL 引数を保存しないので、
コード生成 `ScenarioCodeGen` は逆写像して `direction: .down` を書き戻す)。

- **コマンド**: `scrollDown/Up/Right/Left(repeat:)`(1画面ずつ)/
  `scrollToBottom/Top/RightEdge/LeftEdge(maxSwipes:)`(画面が変化しなくなるまで。
  `StepExecutor` の `scroll` / `scrollToEdge` アクション)/ `scrollTo(セレクタ, direction:maxSwipes:)`
- **端の判定は「静止してから比較」+「2回連続で変化なし」**(`settledSignature`)。
  フリングの減速中に撮ると動いていないように見え、さらに Android では次のスワイプが
  **フリングの停止だけに消費されて 1 回空振りする**。1回の不変化で打ち切ると途中で止まる
  (2026-07-27 実測: `scrollToTop` が row_22 付近で停止した)。署名は型と **x と y**
  (横スクロールでは y が動かない)。ref はスナップショット毎に振り直されるので使わない
- **署名にラベルを入れてはいけない**(2026-07-31 実測)。SwiftUI List では、静止画面でも
  画面外の再利用セル 2 件が取得のたびに別の行のラベルを名乗り、A↔B で交互に振れ続ける
  (frame は 1pt も動かない)。ラベルを含めていた頃は `settledSignature` が毎回ポーリング上限を
  使い切り、「2回連続で変化なし」も永久に成立せず、**`scrollToTop` が毎回 `maxSwipes` 上限まで
  回っていた**(E2E-iOS/ios-xcuitest で 44〜56s。同じ画面が in-app では 1.5s)。
  判定したいのは「動いているか」なので frame だけで足りる(`settleAfterScroll` も同じ)。
  **ランナー側の `captureSettled` は逆にラベルを外さない** — あちらは tap 直後の「内容が
  更新されたか」を待つので、レイアウト不変でテキストだけ変わる更新を取りこぼすと stale を返す
- **用途でジェスチャを変える**(`FTSwipeIntent`。2026-08-02)。同じ「上へ払う」でも要求が違うので、
  ホストが用途を `/swipe` へ伝えてブリッジがジェスチャを選ぶ。**ブリッジに用途の知識を集約する**形
  (`SwipeRequest.scroll` と同じ方針):
  - `gesture`(DSL の `swipe`)= 何も送らない。ジェスチャ自体が目的(向きの検出をアプリに見せたい)
  - `search`(`scrollTo` / `scrollDown` 等)= 何も送らない。**1回の飛距離がビューポート高を
    超えると要素を飛び越す**ので欲張らない
  - `edge`(`scrollToEdge`)= Android は `durationMs`/`fling`、iOS は `velocity` を送る。
    行き過ぎても無害なので最速で端まで送ってよい
  - **Android は距離を送らない・広げてはいけない**(速くするのはストロークだけ。距離はブリッジの
    軸別既定 縦 0.4・横 0.6 のまま)。スワイプは画面中央基準の全画面固定なので `distance` を
    0.8 にすると始点が画面の 10% になり、**スクロール領域の外から始まって1ミリも動かない**。
    iOS は速度のノブなので同じ事故は起きない(XCTest が要素の中で始点を決める)
  - **ラッパードライバは用途を必ず素通しする**(既定実装は用途を捨てる。`SwipeForScrollForwardingTests`
    がソース走査で検出)。数値の根拠と計測手順は PT-3.16 / PT-3.17
- **`maxSwipes` は暴走を止める上限で終了条件ではない**(端用の既定は `defaultMaxEdgeSwipes` = 50)。
  上限で抜けたときは**ステップに注記を出す**(黙って成功にすると「scrollToBottom したのに
  末尾が無い」の原因が読めない)
- `scrollDown(repeat: N)` は**各スワイプの間で静止を待つ**(待たないと同じ理由で空振りし、
  N 画面ぶん進まない)
- **ブロック**: `withScrollDown { }` 系は `FTDriveCore.scrollContextStack` に積み、
  ブロック内の `tap`/`type`/`clearInput`/`select`/`exist`/`notExist` が `scroll:` 未指定なら
  **その向きで探索**する(`notExist` だけは意味が裏返る。上記「否定・状態・個数のアサーション」)。
  `withoutScroll { }` は積んだ文脈を1段打ち消す。1コマンドだけ打ち消すのは **`scroll: .noScroll`**
  (`FTScrollOption` = 4方向 + `.noScroll`。`*WithoutScroll` という関数は置かない。**省略(nil)= 文脈に従う、とは別の値**)。
  明示の `scroll:` 引数が常に最優先(`FTDriveCore.effectiveScroll` の1箇所で解く)。`FTScrollDirection` に
  `.noScroll` を混ぜないのは、向きを取る側(`scrollTo(direction:)`・`withScroll*`・MCP)に書けてしまうため
- **`textIs` 等の検証コマンドに `scroll:` は持たせない**(ユーザー決定 2026-07-27)。
  静止した画面を詳細に検証するためのもので、条件が揃うまで自動でスクロールする挙動は望まれていない。
  **再提案しない**
- **`scrollFrame` でスクロール領域を指定できる**(2026-08-02。Shirates と同じくセレクタ式で受ける)。
  `scroll*` / `scrollTo` / `withScroll*` の引数で、`withScroll*` に渡すとブロック内の `scroll:` 探索が継承する。
  **指定時だけ**ホストが領域の矩形から座標を計算してブリッジへ渡す(`FTCore/ScrollGeometry` =
  shirates-core `ScrollingInfo` の移植。容器 ∩ 画面 → `startMarginRatio` / `endMarginRatio` で削る)。
  **マージン比の既定値の一次記載はここ**(`FTScrollDefaults`。Shirates の既定は踏襲せず fleetest の
  実測で決めた = 承認済み差分)。**直後の「縦 0.4 / 横 0.6」はスワイプ距離の既定であってマージン比
  ではない** —— 混同しないこと:

  | 用途(`FTSwipeIntent`) | 縦のマージン比(始点・終点とも) | 横 |
  |---|---|---|
  | `search`(`scrollTo` / `scrollDown` 等) | 0.25(スパン 0.5・重なり 50%) | 0.2 |
  | `gesture`(DSL の `swipe`)/ `edge`(`scrollToEdge`) | 0.2(スパン 0.6) | 0.2 |

  探索だけ保守側に取るのは、**慣性を消せないので刻み = 実移動量にはならず**、行き過ぎが探索の失敗に
  直結するため(速度を落として慣性を消す案は Android に同じノブが無く、2026-08-02 の実測で収束しなかった)。
  片側の上限は `FTScrollDefaults.maxMarginRatio` = 0.45(= スパンの最小 0.1)。
  **未指定は従来どおりブリッジ側の軸別既定**(縦 0.4 / 横 0.6 の全画面固定)—— 全画面固定のまま
  スパンを変えると始点がスクロール領域の外に出て 1 ミリも動かない(PT-3.16 の実害)。
  **画面に1件も無い scrollFrame は従来経路へ落とさず失敗させる**(2026-08-08。
  `StepExecutor.scrollFrameUnresolved` の fail-fast。1本も振らないので `scrollFrameFailFastMessage`
  は「送られなかった」と言い、送信中に容器が消えた場合だけ文言を差し替える。黙って全画面スワイプへ
  退化させていた頃はカード上のボタンを発火させる実害があった。`select` 系だけは空要素を返す契約が
  優先し skipped)。**容器は解決したが margin で動かせる幅が潰れたときだけ従来経路へ落ちる** ——
  こちらは容器自体が見つかっているので fail-fast を通らず、`resolved but leaves nothing to move`
  の注記を残して全画面スワイプになる(Shirates も明示 scrollFrame は**矩形の供給元**であって、
  スクロール可能かの判定はしない)。
  **in-app は座標を「対象 + 移動量」として読む**(始点で UIScrollView を特定し、始点と終点の差を
  contentOffset へ)ので**マージンも効く**。**端送り(`SwipeRequest.edge` = scrollToEdge)だけは
  移動量を無視して端まで一度に寄せる**(2026-08-19): この経路にジェスチャは無く慣性も無いので
  「1回 = ビューポートの 85%」は実機の体感に寄せた刻みでしかなく、端が目的なら刻む理由が無い。
  長文(利用規約等)ではホストの往復がページ数に比例していた。**`edge` を探索(`intent: .search`)
  へ広げてはいけない** —— 1回で端まで飛んで途中の要素を全部飛び越す。
  **Compose/Flutter は「枠が一致するスクロール容器」だけを in-app で送る**(v112。`FTSwipePath.region` =
  scrollFrame の要素の枠を `ScrollRegionMatch` で突き合わせ、一致した容器を根に AX の scroll を走査で撃つ)。
  2 点(始点・終点)からは hitTest も AX も領域を絞れず、指定領域の外を指しても画面本体が動いた
  (2026-08-02 に E2E-Flutter で実測)ので、**一致しなければ従来どおり 501 で XCUITest へ回す**
  (witness = E2E-Flutter 05 scene 11 / E2E-CMP 05 scene 9 の固定ヘッダ)。実装で踏んだ2点:
  ①Compose の容器そのものは scroll を断り、受理するのは内側の要素(容器を根に走査する)
  ②UIAccessibilityScrollDirection は縦がスクロールバーの向き(指と逆)・横は指の向き(反転していた頃は
  横カルーセルが逆へ送られ端で断られた)。効果(手元の iOS in-app): CMP の `scrollToLeftEdge` 6.6 → 2.0 秒・
  `scrollLeft ×2` 4.3 → 0.47 秒、Flutter の `scrollToLeftEdge` 8.9 → 1.7 秒・`scrollDown ×2` 5.5 → 0.53 秒。
  **scrollFrame 無しは画面中央に揃える**(v113): XCUITest / Android は画面中央を払うが、in-app は UIKit 系が
  「画面のどこかの余地のある最大の容器」、自前描画が「木の順で最初に受理した要素」を動かしていたので、縦リストが
  中央にある画面で横に払うと画面下のカルーセルが動いた(in-app の Flutter・SwiftUI・RN だけ。4 SUT × 3 構成で実測)。
  いまは UIKit 系が「画面中央を含み余地のある最も内側」、自前描画が「枠が画面中央を含まない要素を部分木ごと飛ばす」
  (`ScrollPointReach`。枠 0 の入れ物は通す)。witness = 05_スクロール S0091 scene 5。
  時間指定は持たない(上記の承認済み差分)。
  **未指定のときに容器を特定して座標化する案は撤回済み**(2026-08-02 実装 → 撤回 →
  08-03 に条件を変えて再投入 → 再び撤回。**3度目は無い**)。2度目の撤回理由は2つ:
  狙いだった Compose の飛び越しに**効かない**(Compose の容器は xcuitest で `other` として出て
  `scrollable` を申告できず、そもそも対象に選べない)/ in-app では**到達距離が縮んで既定
  `maxSwipes` に届かなくなる**(E2E-iOS/ios-inapp の `tap("#row_40")` が失敗)。
  判定コードは `StepExecutor.scrollContainer` に残り、**`scrollFrame` 未指定なら必ず nil を返す**。
  暗黙対象を選ぶ `implicitScrollTarget` は **2026-08-05 に関数ごと削除した**(production から
  呼ばれておらず、生きているように見えるだけだったため。規則と再検討条件は
  PT-3.19 に残っているので、必要になったら書き直す)。
  **未指定でも見切れ判定は容器基準で行う**: Compose は**容器の外に子(ghost)を報告する**ので、
  viewport を画面全体にすると容器の外の要素を「見えている」と誤判定して探索がそこで止まり、
  タップが飲まれる。`scrollable` の申告が無くても、スナップショットの `depth` から
  **clip 元の祖先を復元**して viewport に使う(`ContainerGeometry.clippingContainer`。
  **これは見切れ判定専用で、スワイプ座標には使わない**)。2026-08-03 修正・
  詳細は docs/verification/judgment.md「Compose の探索直後タップ」。
  **スクロールできない領域を指定したときは注記で申告する**(座標は正しく作られ 200 が返るが
  何も動かない = 端に達したのと区別できず署名では検出できないため)。判定は
  `ElementInfo.scrollable`(Android=`isScrollable` / xcuitest=型 / in-app=版57から
  `isScrollableContainer` = UIScrollView(content 0x0 は除外)or `UIFocusItemScrollableContainer`
  への**インスタンス毎の準拠**。Compose の AccessibilityElement は `conformsToProtocol:` を
  自前実装しスクロール可能なノードでだけ準拠を名乗る —— 公開プロトコルなので私有 API ではない。
  2026-08-08 PoC: sut-ec-mobile 3画面 + E2E-Flutter で誤検知0・見逃し0。id 無しの容器も
  snapshot に出すようにした)。**申告できないブリッジ(Compose/Flutter の XCUITest ブリッジ)では
  黙る** —— 使ってよいのは true を見つけたときだけで、
  「false = スクロールできない」と読むと誤報になる
