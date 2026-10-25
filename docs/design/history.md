# 設計の経緯と実装で得た知見

| 種別 | 範囲 | 読む場面 | 扱わないこと |
|---|---|---|---|
| 記録 | マイルストーン・リスク・M2〜M4 と並列実行の知見・Swift DSL の実装で得た知見・FM ヒールの撤去の理由(DS-7・8・8.5〜8.8・22・23) | 設計の経緯や、過去に踏んだ実装の罠を確かめるとき | 現在の仕様(→ このフォルダの他のファイル) |

現在の仕様ではない。日付はその時点のもの。

## 目次

- DS-7 マイルストーン
- DS-8 リスクと対策
- DS-8.5 M2(FM 探索)は廃止済み
- DS-8.6 M3実装で得た知見
- DS-8.7 M4実装で得た知見(Android)
- DS-8.7.1 更新: Android もブリッジ化
- DS-8.8 並列実行の実装知見
- DS-22 FM ヒールの実装で得た知見と撤去の理由
- DS-23 Swift DSL の実装で得た知見

## DS-7 マイルストーン

| M | 内容 | 完了条件 | 状態 |
|---|---|---|---|
| **M1** | ブリッジ + 手動駆動 | CLI から SampleApp を起動し、curl 相当で tap/type/snapshot/screenshot が通る | 達成済み |
| **M2** | FM 探索によるシナリオ自動生成(`fleetest explore`) | — | 廃止済み(DS-1.2) |
| **M3** | 決定的再生 + 自己修復 + トリアージ | id 変更を仕込んだ SampleApp でシナリオが自己修復され、意図的バグで失敗が section/command/failureKind 付きで記録に残る | 自己修復は指紋照合で達成(DS-10「ロケータの指紋」)。**FM ヒール(採用門 confidence == high)は本番で実測 0/272 しか開かず、2026-09-15 にヒールキャッシュごと撤去**(DS-10・MN-22)。FM トリアージは同日撤去 → MN-21 |
| **M4** | Android ブリッジ + ドライバ | `AndroidDriver` で FTFoundationModels/FTCore を無変更のまま Android アプリのシナリオを再生する(実装は自作 instrumentation ブリッジ。UIAutomator2/Appium は不採用。DS-4.5, DS-8.7) | 達成済み |

M1・M3・M4 は達成済み(M2 の FM 探索機能は後に廃止。DS-1.2)。2026-07 には固定 sleep をブリッジ内蔵の a11y 静穏検知に置き換える高速化を実施し、
Android シナリオで約 33%、iOS シナリオで約 27% 所要を短縮した(DS-8.7.1、詳細は
[パフォーマンスチューニングガイド](../performance-tuning/README.md))。

---

## DS-8 リスクと対策

| リスク | 対策 |
|---|---|
| Apple Intelligence 未有効 / FM 利用不可 | `fleetest doctor` で `availability` を事前診断。**PCC/外部 LLM への差替は行わない**(DS-1.2)—— `screenLooksLike` は判定されずに通り、テキストの可視性検証は OCR だけで判定して走る |
| 4K コンテキスト超過 | スナップショット圧縮 + 1 ステップ 1 セッション + 応答の構造化。FM 呼び出しの失敗は `FMHealth.record` に記録して諦める(再試行はしない) |
| 巨大な画面ツリーで snapshot が遅い | ランナー側でフィルタしてから返す(ホストに生ツリーを送らない) |
| xcodebuild ランナーの不安定さ | `bridge up` にヘルスチェック+自動再起動。`/status` ポーリング |
| Vision 入力の HW 要件(AFM 3 Core Advanced) | ホストは Apple Silicon Mac 前提なので通常問題なし。`doctor` で検査 |

---

## DS-8.5 M2(FM 探索)は廃止済み

FM がアプリを自律探索してシナリオを生成する explore モード(`fleetest explore` / ExplorerProfile)は
廃止した。3B モデルの迷走対策(数値参照の束縛ミス・greedy サンプリングの縮退ループ・ステップ上限・
サルベージ機構等)を含む実装知見はここでは割愛する。

## DS-8.6 M3実装で得た知見

- **マルチモーダルAPI**(macOS 27+): `Attachment(cgImage)` が `PromptRepresentable` なので
  Promptビルダーに画像を直接混ぜられる。`session.respond(generating:options:) { "説明文"; Attachment(cgImage) }`。
  **Attachment だけが macOS 27+ で、FM 本体(テキスト・`@Generable`)は macOS 26+**。Package の最低は
  macOS 26 に置き、視覚系(occlusion-guard / screenLooksLike)を実行時に落とす:
  判定の単一点は `FTCore/FMVisionSupport.swift`(StepExecutor が呼ぶ前に skip/素通りへ)で、
  実 API 側は `FTFoundationModels` の `#available(macOS 27, *)` が保険
- **screenMatches(視覚検証)は実用レベル**: 「果物の商品名と価格が並ぶリスト」の一致/不一致を
  スクリーンショットから正しく判定し、不一致時は理由(エラーメッセージの存在)も説明できた
- **アサーションに type+index フォールバックは危険**(実測で誤った緑が発生): 別画面の無関係な要素に
  マッチする。再生器は assert 解決時に id/label を持たないフォールバックを除外する
- **(歴史的経緯)自己修復の FM 版は elementText 方式で安定**していた: 壊れた `id=login_btn` に対し
  「サインイン」ボタンを high confidence で提案・修復できた。修復フローは `dirty: true` + note に
  修復理由を残す設計だったが、本番の採用門(confidence == high)は実測で 0/272 しか開かず、
  2026-09-15 に FM 版を撤去して指紋照合のみに一本化した(DS-10・MN-22)

## DS-8.7 M4実装で得た知見(Android)

- **adb 直叩きで十分**: `uiautomator dump`(ツリー)+ `input tap/text/swipe` + `screencap` で
  AppDriver を完全実装できた。UIAutomator2 サーバや Appium は不要(依存ゼロ方針を維持)
- **型語彙を iOS と揃える**: Android クラス名(EditText/TextView/Switch...)を iOS 側の
  型名(TextField/StaticText/Switch...)へマップすることで、FM プロンプト・ガードレール・
  Flow DSL が完全共通化できた。**FTFoundationModels と FTCore は1行も変えずに Android で動いた**
- **リスト行のテキスト昇格**: Android は「クリック可能な無名コンテナ+非クリックのテキスト子」
  構造が支配的。ドライバ側でクリック可能ノードへ子孫テキストを昇格させて解決する
- **CLI プロセスは短命**: iOS はランナー常駐だが Android ドライバは CLI 内に住むため、
  ref→座標対応表を一時ファイルに永続化して手動駆動コマンドをまたげるようにした
- 既知の制限: `adb input text` は ASCII 中心(日本語はIME経由が必要)。実機は `--serial` 指定
- **クロスパッケージ画面は launchApp の前面判定を壊す**(2026-07-14 実例、以後ブリッジ側で自動復旧):
  Android 16 の設定「セキュリティとプライバシー」は別パッケージ(SafetyCenter/permissioncontroller)の
  画面で、開いたまま残ると force-stop は bundleID しか殺さないため以後の
  `launchApp("com.android.settings")` が「画面が表示されませんでした」で全滅する罠があった。
  `handleLaunch` は前面判定タイムアウト時、前面に居座るパッケージ(bundleID/ブリッジ自身/HOME を
  除く)を force-stop+HOME で掃除して1回だけ再試行するようになり、カスケード全滅はしなくなった
  (事後復旧であり予防ではない。ストール自体は初回1回は起きうる)。手動復旧は
  `adb shell am force-stop com.google.android.permissioncontroller`+HOME のまま残す(フォールバック)。
  検証(2026-07-18、Pixel 9a/Android 16 実機): 設定→「Security & privacy」タップで SafetyCenter を
  settings と同一タスクに積んで launchApp settings すると、v6 は 10s タイムアウトで error・SafetyCenter
  居座り、v7 は同条件で自己復旧して settings 前面化(前面判定タイムアウト→掃除+再試行の before/after 確認済み)。
  **版 67 から、前面がシステムダイアログのパッケージ(permissioncontroller / packageinstaller / systemui。
  ホストの `systemDialogPackages` と同じ集合。Android 側だけ chrome も追加で含む —— Custom Tab を
  force-stop するとアプリ側の遷移が壊れるため)で、かつ対象アプリの窓が `getWindows()` に見えている
  ときは「ダイアログ越しに前面」として掃除せず成功を返す**(権限ダイアログを force-stop すると権限フローが
  壊れる)。対象アプリの窓が見えない全画面の居座り(上の SafetyCenter の形)は従来どおり掃除+再試行

### DS-8.7.1 更新: Android もブリッジ化

snapshot の 2 秒(uiautomator dump 自体のコスト)がフロー実行の支配項になったため、
iOS と同型の常駐ブリッジを追加した(`AndroidRunner/`、自作 instrumentation APK)。

- **共通コア部分は iOS ブリッジと同一プロトコル**(DS-4.5) → ホストは `BridgeClient` を無改修で流用
  (`adb forward tcp:0 tcp:8123` 経由)。AppDriver/FTFoundationModels/FTCore は引き続き無変更
- 純フレームワーク API の Java のみ(androidx/gradle 不要、SDK 付属ツールでビルド、
  prebuilt APK を同梱)。初回操作時に自動インストール・自動起動(`AndroidBridge.swift`)。**他のセッション(run・MCP)が
  使っているデバイスでは作り直さない**(force-stop がそのセッションのブリッジごと落とす)。呼び手がそのデバイスを持つ
  run(とその子のシナリオ)なら MCP から引き取ったデバイスでも作り直す(`RunnerAccessibilityHealth.hasForeignLeaseUnlessOwnRun`)
- 実測: snapshot 2.0s → 8.7ms(中央値)、フロー8本 87s → 38s。日本語 type も
  ACTION_SET_TEXT で IME 不要(ADBKeyboard は不使用)
- ブリッジ単一実装。adb 直叩き経路(uiautomator dump/input/screencap、Unicode IME 自動導入)は持たない。
  操作毎の `/status` 事前プローブも持たず、接続拒否系エラー時のみ自動再プロビジョン+1回リトライする
- 落とし穴: (1) UiAutomation は `am instrument -w` 必須(UiAutomationConnection が am
  プロセス側に住む)→ デバイス内で `&` バックグラウンド化して常駐 (2) a11y 接続は実質1本
  → ブリッジ稼働中は他の a11y クライアント(uiautomator dump 等)が Killed される
  (3) **adbd の再起動(`adb tcpip` / `adb usb`)で UiAutomationConnection(shell・screenshot・
  入力注入の口)だけが死ぬ** —— a11y は生きたままなので `getRootInActiveWindow()` は取れ、
  `executeShellCommand` は RemoteException を握って空のパイプを返す(例外にならない)。
  実測 2026-09-05・Pixel 4a: `DeadObjectException` ×47 のまま `/status` が `ready:true` を返し続け、
  launch/screenshot が全部 500。版 63 から `/status` が `echo ft-alive` の往復で口の死活を見て
  `ready:false` + `reason:"uiautomation-dead"` を返し、**自ら exit する**(ホストは connection refused
  → `ensureBridge` の再セットアップへ倒れる。長寿命プロセスの `.active` キャッシュもこれで消える)。
  版 64 から**操作系も同じ門を通る**(`BridgeRouter.assertConnectionAlive`): shell の出力が空・
  `takeScreenshot` が null・`injectInputEvent` が false のときに死活を確かめ、死んでいれば
  503 で落として exit する —— `/status` を誰も呼ばない長寿命プロセス(MCP・モニター)でも、
  死んだ口に tap が黙って通ることが無い

### Android のテキスト注入の規律

`InputInjector` の4経路(`setTextAppendingAt` / `clearTextAt` / `setTextAppending` /
`clearFocused` = ref なしの `clearInput()`)が守る規律。
**破ると「入ったのに値が壊れる」「成功を返すのに入っていない」が高負荷でだけ出る**
(8台並列で約40%再現・単独実行では8回中0回。解決後は10周×37シナリオで0件)。
**ref なしの `clearFocused` だけが1発の `performAction` で 409 を返していた**(2026-09-06 に
揃えた。ブリッジ版 65): Flutter のパスワード欄で実機 Pixel 4a の 10 周中 5 周が
「does not accept ACTION_SET_TEXT」で赤。logcat プローブで確定した原因は
**`findFocus(FOCUS_INPUT)` が半分の確率で欄ではなく FlutterView の入れ物
(`android.widget.FrameLayout`・editable=false・text=null・子 1 つ)を返す**こと —— Flutter の
a11y ブリッジが入力フォーカスのセマンティクスノードを持っていない瞬間は、フレームワークが
フォーカスを持つ View 自体へ倒す。入れ物に SET_TEXT を撃てば拒否(旧 409)、「空」と読めば
黙って成功(再試行だけ足した中間版では「reported success but the value remained」で 5/10)。
直し方は **`focusedEditable`**: findFocus の結果が編集可能でなければ木から `isFocused && isEditable`
を探し、無ければ期限(4 秒)まで引き直す。読む前に refresh・空を読めたら成功・受理だけでは
成功にしない、は他の3経路と同じ。`pressImeEnter` も同じ選び方(入れ物への ACTION_IME_ENTER は
必ず失敗し keyevent へ落ちていた)。修正後 10 周 0 件(うち 1 周は木から見つけて成功)

- **`performAction(ACTION_SET_TEXT)` の `true` は「受理された」であって「入った」ではない**。
  タップがキーボードに吸われてフォーカスが立っていない Compose の TextField は、受理しても
  反映しない(a11y ノードは座標で見つかるので受理はされる)。**必ず読み返して確認する**
- **`combined` は最初の確定読みから1回だけ作る**。再発火は常に同じ値=構造的に冪等。
  読み返すたびに作り直すと、**パスワード欄の a11y 読みはマスクされている**ため伏せ字を値として
  書き込み(`password=•••…secret42`)、遅延適用と重なれば二重追記になる(`hello123hello123`)
- **中身のあるマスク欄へは追記そのものを撃たない**(`rejectMaskedAppend`。2026-08-06 追加)。
  上の規律は「作り**直す**と伏せ字を書く」だったが、**初回構築も同じ穴**だった ——
  追記は `既存の読み + text` を書き戻す形で、パスワード欄の「既存の読み」は伏せ字そのもの。
  実測: 空欄へ `abc` → 続けて `def` で、アプリ側の echo が **`•••def`** になり、
  ツールは "Typed" と成功を返した(値が壊れたことは後段の検証まで分からない)。
  読める術が無い以上ここは追記できないので **422 で弾く** ——
  置換したいなら呼び手が先に `clearInput` する(空への置換は冪等で安全)。
  空欄への1回目は `current` が空なので従来どおり通る。
  **弾いた判断は `catch (RuntimeException)` で再試行に化けさせない**(BridgeException だけ
  先に再スローする)。しないと 4 秒待って「ノードが無効化された」という無関係な 500 になる
- **適用確認はマスク欄だけ長さ一致**で見る(値そのものは読めない)
- **SET_TEXT はフォーカスが立っているときだけ撃つ**。立たないときは座標でなく `ACTION_CLICK`
  でフォーカスを要求する(キーボードの開閉で adjustResize が走ると**座標は当てにならない**)。
  猶予後の未フォーカス発火は最後の1回だけ・検証付き
- **対象の追跡は `ref` → resource-id 表**(`SnapshotBuilder.Result.refIds`)で毎周回取り直す。
  点だけを頼ると再レイアウトで別ノードに化ける
- **フォーカス済みでも 700ms 反映されないなら IME セッションが腐っている**(前のアプリ
  インスタンスに紐づいた残留)。BACK で IME を閉じ、最新 bounds の中心を**実タップ**して
  張り直す。`ACTION_CLICK` では張り直らない(実測)。BACK は
  `UiAutomation.getWindows()` に `TYPE_INPUT_METHOD` があるときだけ撃つ(無いと画面が戻る)
- **`performAction` / ノード読みは try/catch で「取り直し」に変換**する。レイアウト変化中の
  ノードは内部で NPE を投げる
- **読む前に `AccessibilityNodeInfo.refresh()` する**(2026-07-31 追加)。a11y ノードは
  キャッシュから供給されるので、`getRootInActiveWindow()` を毎周回取り直しても
  **`getText()` は変更前の値を返し続ける**ことがある。とくに WebView(Chromium)は DOM 変更の
  a11y イベントを数秒遅れて出す。取り直さないと「SET_TEXT は効いているのに読みが古く、
  期限切れで 500」= **実際には入っているのに失敗**になる(WebView 入力欄で 20% 再現。
  期限時のノードは `focused=true` で `text=""` なのに、ホストのスナップショットは
  `hello123` を読めていた)。`SnapshotBuilder.collect` が `insideWebView` で同じことを
  していたのに、注入側だけ漏れていた。**副産物として速くなる**: 確認が即座に成立するので
  WebView の type は 2,000→300ms、通常欄も中央値 864→520ms
  (キャッシュが古いあいだ待っていたぶんが消えた)
- **この規律は WebView 限定ではない**(2026-08-01 に範囲を拡大)。IME 等が前面にあると
  ネイティブ画面でも数秒古いツリーが返り、**アプリは正しいのに検証だけが落ちる**
  (逆に、遷移前の状態を期待するアサーションは**誤って成功する**)。`SnapshotBuilder.collect` は
  全ノードで `refresh()` する。**`isVisibleToUser()` より前に呼ぶこと** —— 可視性が古いと
  実際は見えているノードがサブツリーごと消え、`getChild()` も古い子リストを返す
- **`refresh()` の戻り値を見る**(2026-09-20 追加)。false は「取り直せなかった」で、
  **ノードの中身は古いまま残る**。その読みを「値がまだ入っている」の根拠にすると、
  反映済みの欄を期限切れで落とす(refresh を入れる前と同じ誤りが、refresh 済みの顔で残る)。
  注入の4経路(`setTextAppendingAt` / `clearTextAt` / `setTextAppending` / `clearFocused`)は
  **false の周回では読まず・撃たず**、次の周回で木から引き直す。`SnapshotBuilder` は対象外 ——
  あちらの仕事は「今ある情報を返す」ことで、失敗の判定はしない
- **期限切れの失敗には判別できるだけの事実を載せる**(`failureFacts`): 最後に読み返した値
  (**マスク欄は長さだけ**・40 文字で切る)/ 直前の `refresh()` の成否 / `ACTION_SET_TEXT` が
  受理された回数 / IME ウィンドウが前面か。これが無いと「読みが古かった」のか
  「アプリが本当に値を戻した」のかが記録から割れない(2026-09-20 の誤った赤 →
  MN-39.1)
- **Android の 409 / 500 に受け皿は無い**。ホストが `typeDriver` へフォールバックできるのは
  iOS の inapp モードだけ(`ScenarioRunnerMain` が iOS の分岐でしか渡さない)なので、
  ブリッジのこの判断がそのままシナリオの合否になる

**評価して不採用(再提案しない)**: `ACTION_FOCUS` でフォーカスを立てる案は **NPE を誘発して
失敗率が 2/5 → 5/5 に悪化**した(フォーカス移動でノードが無効化される)。ホスト側での事前・事後の
キーボード回避(閉じてから打つ/失敗したら閉じて再試行)は**発動しても効果が無い** —
対策はブリッジの注入ループ内でなければ届かない。

## DS-8.8 並列実行の実装知見

- **ポート注入**: FT_PORT はビルド時に xctestrun へ焼き込まれるため、並列化は
  「xctestrun のコピーに PropertyListSerialization で FT_PORT を書き換えて注入」で実現
  (ビルド1回で任意台数)。**コピーは必ず元と同じ Build/Products/ に置くこと** —
  `__TESTROOT__` は xctestrun ファイルの場所基準で解決される(別の場所に置くと
  "Missing test product" で起動失敗する。実測済み)
- **コールドブート直後は危険**: 起動直後のシミュレータに並列負荷をかけると
  アクセシビリティ IPC がタイムアウトし(kAXErrorIPCTimeout)、ランナーごと落ちる。
  ウォームアップ(launch+snapshot 1周)後は安定
- **フローは解像度非依存**: ロケータ再生なので iPhone 17 Pro(402pt)で生成したフローが
  Pro Max(440pt)でそのまま通る(実測済み)
- 実測(M1 Max): 3フロー(iOS×2 + Android×1)逐次 55.2秒 → iOS 2ワーカー+Android 1ワーカー並列で
  31.2秒。壁時間は最長フローに漸近する(理想スケーリング)
- **期限付き実行(`withDeadline` / `raceWithDeadline`)に `withTaskGroup` を使わない**: 構造化並行は
  スコープ終端で**敗者 task の完了を待つ**ため、ウェッジした op(無応答ブリッジ・固着した VT セッション)
  から離脱できず期限そのものが効かなくなる。だから非構造化 Task + 1回限りガード
  (`DeadlineGuard` / `RecordingRaceGuard`)で組む。
  **その代償が前方参照の競合**: op 勝利時に満期スリーパーを cancel するには task 参照を前方参照する
  必要があり、`Task { }` の本体は囲みの同期区間と**並行に開始し得る**ので素の `var` では競合する
  (「代入は同期区間で完了するのでレースしない」は成り立たない。ThreadSanitizer で実測・2026-07-30 修正)。
  `DeadlineTaskBox` は lock で守り、**代入前に来た cancel を覚えて後から適用する**
  (取りこぼすとスリーパーが seconds 秒居座り、この箱を置いた目的が消える)。
  前方参照を持たない `RecordingSupport.raceWithDeadline` にはこの箱が要らない
- **CLI での `Task.detached` fire-and-forget はプロセス終了と競合する**: 短命 CLI(fleetest run 等)で
  副作用(adb reboot 等)を detached Task に逃がすと、直後に throw → プロセス即終了する経路で
  **発行前にプロセスが死ぬ**(まさに副作用が最も必要なエラー経路で消える)。発行が速い外部コマンドは
  同期発行にする(実例: 難治型凍結の guest reboot。ProfileWorkerFactory.excludeOrRepairBlankScreenWorkers)。
- **サブプロセス kill と `waitUntilExit()` の reap 競合(1本の詰まりが run 全体を凍結)**:
  `ScenarioHost.run` の watchdog kill で `Process.isRunning` を使うと内部の `waitpid` が子を
  **reap** し、直後の `waitUntilExit()` が終了通知を取りこぼして**永久ハング**する(SIGTERM を
  無視した子で実測: ワーカー全体が `waitUntilExit` で停止)。**生存確認は reap しない `kill(pid, 0)`**
  を使うこと(`process.isRunning` は使わない)。この凍結は scenarioTimeout(当時の既定 90s)を超えるシナリオでのみ
  顕在化する潜在バグで、inapp モードの suspend 誤ルーティング(PT-8)が引き金だった。
- **inapp モードの in-app suspend**: system-UI シナリオと in-app シナリオを混在実行すると、背面の
  注入先アプリが iOS に suspend され in-app ブリッジが無応答になる。ドライバ選択は provision 時の
  注入先 bundleID で分岐する(詳細と対策は PT-8「suspend 時のルーティング」)。
- **規模並列(20台級)は timeout flaky を生む**: 競合で画面ロードが遅れ、本来通る `exist` が既定
  タイムアウトを超えて落ちる(実測: 自動入力画面の Switch ロード遅延、Files/連絡先の初回起動、
  Wi-Fi 詳細の描画等が単発で NG)。**規模ランの単発失敗を「シナリオ不良」と即断しない**。切り分けは
  当該シナリオを空き機 1 台で `heal:false` 再実行し、決定的ラベル破綻か flaky かを分ける(20台の失敗
  17件中、実バグは陳腐化ラベル2系統のみで残りは flaky/ロケール/デバイス状態だった。2026-07-16)。
  空き機は fleet(モニター所有)に触れず別途起動: Android は空き AVD を `-port 5590 -no-window` で
  起動→`ft_run_scenario --serial`、iOS は空きシムを boot→一時 machine/run プロファイル
  (`iosMode:"xcuitest"`、fleet と衝突しない空きポートを device.port に明示)→`--profile`。

## DS-22 FM ヒールの実装で得た知見と撤去の理由

2026-09-15 に撤去した FM ヒール(`LocatorRepairSuggestion` / ヒールキャッシュ /
`FT_FAKE_HEAL_CONFIDENCE_HIGH`)の実装で得た知見を圧縮して残す。撤去そのものの理由・
測り方は MN-22。

- **confidence は採否の根拠に使えなかった**(2026-09-02・`Scripts/fm-verify.sh` を5周。
  `sampling: .greedy` で全周同一出力)。誤要素(NavigationBar 等)を高確信で選ぶことがある一方、
  正解も低確信になることがあり、**信号が両方向に外れていた**:

  | シナリオ(撤去済み) | 提案 | 正誤 | 自己申告 |
  |---|---|---|---|
  | `90_自己修復` | `#btn_heal_v2` | **正解** | low(5/5) |
  | `93_triage` | `#nav_selector` → `#nav_input` | **誤り** | medium→low(5/5) |

  (`93_triage` と FM トリアージ機能は同じ理由で 2026-09-15 に撤去 → MN-21)。
  閾値の調整では解けない(`medium` へ下げると誤答が通り、`low` へ下げると何でも通る)——
  自己較正は小さいモデルが最も苦手とする能力で、確信度を採否の唯一の門にする設計自体が
  無理だった。一方「一覧から役割の同じ要素を選ぶ」こと自体は実測で足りていた(正解を 5/5 で
  指した)ので、採否をロケータの指紋という決定的な根拠へ移した(前項)
- **本番の門は実測で1度も開かなかった**(2026-09-15 時点: 日英 272 件で high 0 件・E2E の
  `90_自己修復` は 9/2 以降の全 run が `heal-proposal-rejected`。提案そのものは正解だった)。
  デバイスで1度も通らない経路を検証するため、陽性対照の注入口
  `FT_FAKE_HEAL_CONFIDENCE_HIGH=1`(`FTCore.HealConfidenceInjection`。`FrozenInjection` と
  同じ規律)を置いていたが、これも撤去した(採用門ごと消えたため)
- ヒールが黙って諦める経路(セレクタが書けない/confidence 不足/答えを木へ引き戻せない)
  それぞれに注記(`heal-unwritable` は現存、`heal-proposal-rejected` /
  `heal-answer-unresolved` / `heal-confidence-injected` は撤去)を置いていた設計だった。
  `heal-unwritable` は指紋照合でも意味が同じなので残した(DS-10「ロケータの指紋」)
- プロンプトに壊れたロケータを名指しして「それを答えにするな」と書く工夫(`healPrompt`)や、
  `FMReplayDelegate.healAttempt` の非オプショナル設計などは、フック自体の撤去に伴い不要になった

## DS-23 Swift DSL の実装で得た知見

- **swift-syntax 603 + prebuilts**: マクロ導入によるクリーンビルド増は SwiftPM の
  prebuilt swift-syntax が効き、初回全体で +20 秒程度に収まった(増分ビルドへの影響なし)
- **objc_copyClassList 走査**は Swift の日本語クラス名でも問題なし(String(describing:) で取得)
- **extension マクロのテスト**は MacroSpec(conformances:) を渡さないと protocols が空になり
  「conformance 済み」判定で extension が生成されない(assertMacroExpansion の仕様)
- **`.macro` ターゲットには Package.swift 冒頭の `import CompilerPluginSupport` が必要**
- iOS 27 のパスワード保存シートはタップ時にアニメーション中で座標がずれることがある →
  シナリオ側で `wait(1)` を挟むのが確実(コードで書けるようになった利点)
- **xcuitest の `launchApp` も既定で simctl 化**(FastLaunchDriver・2026-07-21)。
  XCUIApplication.launch()(約4.6s)の代わりに simctl terminate+launch+activate 接続(約2.4s)で
  再起動する(シナリオ wall −14〜19%)。`FT_NO_FAST_LAUNCH=1` で従来動作へ戻せる。
  attachOnly(整定なし接続)を launch に使わない理由は PT-6
- **inapp の `launchApp` は毎回 `simctl launch --terminate-running-process` で terminate+relaunch する
  が、アプリのデータは消さないためアプリがディスクへ永続化した直前ルートを復元し得る**(プロセス
  再利用ではない)。決定的なナビ状態リセットはアプリ側の責務で、ツールは状態リセットの注入
  (`SIMCTL_CHILD_FT_RESET` 等)を意図的に提供しない(ユーザー決定・2026-07-20)。
  シナリオ側は scene1 で対象タブをルートへ正規化して吸収する
- **`launchApp` は全モードで常にプロセスを再起動する**(前面化ではない。Android は
  ブリッジの force-stop+起動、xcuitest は FastLaunchDriver の terminate 込み launch)。
  「起動済みならプロセス温存でエントリー画面へ」の warm 化は 2026-08-08 に実装・検証まで
  行ったうえで**中止・破棄**した: Android は `am start --activity-clear-task` で成立するが、
  **iOS には起動済みプロセスをエントリー画面へ戻す OS 機構が無く**、前面化(activate)だけでは
  「起動直後の最初の画面」という契約を満たせない(片 OS のみの機能では意味が無いという判断)
- **in-app の木は可視な窓を全部歩く**(2026-08-20。それまではキーウィンドウ1枚だけ)。
  **別 UIWindow に載るモーダル**(アプリ内メッセージ SDK 等)が木から見えないと、
  画面を覆っているのにテストは何も失敗しない —— タップは `activate`、スクロールは
  `contentOffset` の直接書き込みで**どちらも hitTest を経由しない**ので**覆いが障害物にならず**、
  `irregularHandler` も照合対象が無いので発動しない = **誤った緑になる**
  (受け手報告。自前 SUT の `OverlayWindow` で再現 → `bridgeProtocolVersion` 75 で修正)。
  **`UIAlertController` は自分の窓を key にする**ので以前から載っていた。載らなかったのは
  **key にしない**窓で、そこが SDK 系オーバーレイの形。
  並びは **windowLevel の昇順**(手前を後ろに置く。ホストの遮蔽判定が「後に出るものが上」を
  前提にしているため)。**キーボードの窓だけは除く**(キーが大量に写り込むうえ、表示判定と
  実矩形は `keyboardIsVisible` / `keyboardFrameIfVisible` が別に申告する既存の設計)。
  **覆われた要素は落とす**(`InAppSnapshot.isCovered`): 前後の窓を両方載せると
  「覆われているのに `exist` が通る」が残る。判定は**その位置で手前の窓がタッチを受けるか**
  (`hitTest`)。**「手前の窓だけ見せる」にはしない** —— 画面の一部だけを覆う形(上部バナー・
  ハーフシート)で**触れる背面まで消える**か、逆にバナー自体が見えず `irregularHandler` で
  閉じられなくなる(2026-08-20 に両形の witness で確認)。
  限界: 判定は**タッチが届くか**であって**目に見えるか**ではない —— `isUserInteractionEnabled = false`
  の不透明な飾り窓は背面を残す(触れる以上、操作の前提としては正しい側)。
  witness は `E2EAppIOS` の `OverlayWindow`(全画面モーダル / 上部バナーの2形)と
  `TestProjects/E2E-iOS/scenarios/15_別ウィンドウのモーダル.swift`
- **操作の宛先も窓で決める**(2026-08-20 の追加報告。版 76)。木だけ複数窓にすると
  **見えているのに閉じられない**が残る —— `activate` が不発で合成タッチへ落ちた瞬間に
  **キーウィンドウ(= 背面のアプリ)へ撃つ**ため。ref を持つ操作は
  **その要素が載っている窓**(`InAppBridge.window(of:)`。`accessibilityContainer` を辿る。
  **`value(forKey:)` は使わない** —— 未定義キーの例外は Swift で捕まえられず対象アプリを落とす)、
  座標だけの操作とスクロールは**いま指が当たる窓**(`frontmostTouchableWindow`)へ送る。
  **スクリーンショットも可視な窓を重ねて描く** —— キーウィンドウ1枚だけだと
  「モーダルが写っていない証跡」を残すことになる
- **inapp は Compose Multiplatform(iOS)の swipe/scrollTo/press を駆動できない**
  (2026-07-22・`TestProjects/E2E-CMP` で切り分け確定)。同一アプリ・同一シナリオの両モード差分:
  - inapp: `tap`/`type` は通る。`swipe` 4方向・`scrollTo`・`press`(長押し)が**すべて無反応**
  - xcuitest: 同じシナリオが**全て成功**

  原因は2段構えで、**合成タッチの品質の問題ではない**:
  1. `/swipe` の主経路はタッチ合成ではなく **`UIScrollView.contentOffset` の直接操作**
     (UIKit/SwiftUI ではジェスチャ認識器が合成タッチを受理しないため、意図的にこうしてある)。
     Compose の画面にも**本体のスクロールとは無関係な UIScrollView が存在する**ので、
     それを動かしても描画は一切変わらず、エラーも出ない = **黙った空振り**になっていた
  2. 経路を合成タッチ(`FTSynthSwipe`/`FTSynthPress`)へ向け直しても Compose は受理しない。
     イベント間でランループを回す・moved の HID マスクに RANGE|TOUCH を足す・静止 moved を
     刻みながら押下保持する、はいずれも**効果なし**(実験済み・不採用)。単発 down/up の
     `FTSynthTap` だけが通る

  対処は3層(1 はブリッジ側、2〜3 はホスト側)。**UIKit/SwiftUI 側の経路は一切変えていない**:
  1. **ブリッジ**: Compose/Flutter 検出時、**ジェスチャ目的**の `/swipe` と `/press` は **501**
     (`InAppBridge.handleSwipe`/`handlePress`。判定は `/status` と同じ `compose-resources` /
     `Flutter.framework` マーカー)。黙って空振りするより「12回スクロールしても見つかりません」の
     ような誤診断を防ぐ方が価値が高い。
     **409 ではなく 501 なのは意図的**: 409 はキーウィンドウ不在等の一時的競合にも使われるため、
     フォールバック判定に使うと「アプリが前面に無い」状況を隠して別画面を操作しかねない
     (`/terminate` が既に 501=このブリッジでは未対応 を返している慣習に合わせた)。
     **スクロール目的(`SwipeRequest.scroll`)だけは 2026-07-31 から in-app で通る** ——
     UIAccessibility の scroll アクション経由(上の「Compose/Flutter のスクロールは
     UIAccessibility の scroll アクションで駆動する」の節)。この段の記述は**ジェスチャ目的に限る**
  2. **事前ルーティング**(2026-07-23 導入 / 2026-07-31 に swipe を除外): inapp モードは in-app ブリッジと
     XCUITest の両ブリッジを張るので、起動時プローブの **`/status.unsupportedActions`**
     (ブリッジが「この対象アプリでは実行できない」アクション名を申告する)に該当し typeDriver
     ありなら**最初から** typeDriver(`AppAttachDriver`)へ回す
     (`StepExecutor.typeDriverGestures`)。409 の往復はゼロ。
     **申告は現在 `["press"]` だけ**(以前は Compose/Flutter で `["swipe","press"]`)。
     swipe を外したのは、可否が**目的と画面で割れる**ようになり「一律不可」では表現できない
     ため。swipe の可否判定は `handleSwipe` に一本化してある
  3. **事後 501 キャッチ**: プローブ不達で 2 が立たなかった場合の安全網。1回 501 を受けたら
     ラッチして以降は直接 typeDriver へ(`scrollTo` は maxSwipes 回まわるので毎回往復させない)。
     `type` の 409 安全網と同じ形。**press は ref がブリッジごとに別名前空間**なので
     typeDriver 側で snapshot し直して再解決する(`pressViaTypeDriver`)

  これにより **inapp モードでは Compose でもジェスチャが通る**(`TestProjects/E2E-CMP` の `ios-inapp` が
  18/18・37.3s。導入前は3シナリオ失敗・93.9s)。tap/type/スナップショットは高速な in-app のまま。
  409 が表面化するのは **typeDriver が無い構成**(XCUITest ブリッジが無い・xcuiPort 無し)ときだけ。
  そのときはメッセージが xcuitest プロファイルへ誘導する。
  なお `type` の事前ルーティング(`preferTypeDriver`)は別物で廃止済み — Compose でも inapp の
  type が可能かつ高速(266ms vs attach 1.0〜1.3s)なため。ジェスチャは inapp が**不可能**なので
  トレードオフの向きが逆になり、事前ルーティングが常に得になる
- **「in-app で不可・XCUITest で可」は常に XCUITest へ回す**(2026-07-28 にユーザー決定で一般化)。
  判定は `DriverError.isBridgeIncapable` の1箇所: **501 と「ルート不明の 404」(本文 `not found:` 前置)
  だけ**。**409 は含めない**(上記の理由。in-app の 404 には ref 不明もあるため本文で見分ける)。
  対象は3つ:
  - `home` / `appSwitcher`: in-app は自プロセス外を触れないので**原理的に不可**。inapp モードでは
    501 の往復を作らず最初から XCUITest へ直行する(`FTDriveCore.systemDriver`)。XCUITest 側の
    `/home`・`/appswitcher` は**セッション不要**なので attach も activate も挟まない
  - `drag`(スクロール探索直後の**空打ち極小ドラッグ**): in-app は drag を実装しない。回さないと
    Compose の容器がタッチを1回吸ったままになり直後の tap が空振りする。**ラッチは swipe と共有
    しない**(`dragFallbackLatched`。共有すると drag の 501 だけで全 swipe が XCUITest 実スワイプ化し、
    バウンス由来の flake を持ち込む)。空打ちは補助なので両経路の失敗はステップの失敗にしない
  - `swipe` / `press`: 既存の申告+事後キャッチ(上記 2〜3)。判定だけ共通化した

  **入力系(`pressEnter` / `type(ref: nil)` / `clearInput(ref: nil)`)だけは別の判定で 409 も回す**
  (`DriverError.isTextInputFallback` = 409 / `isClearInputFallback` = 409 + 422 + isBridgeIncapable。
  422 は XCUITest ランナーが同じ事情に使う status —— あちらは 409 を使えない(DS-4.3))。
  **DSL(`StepExecutor`)と `HybridFallbackDriver`(ライブ操作。MCP は iOS を XCUITest だけで動かすので通らない)が同じ判定を通る** ——
  2026-09-23 まで DSL 側だけがインラインで持っていたため、**同じ inapp モードの同じ操作が
  シナリオでは通るのに `ft_type`(`pressEnter`)/ `ft_clear_input` では 409 で落ちた**
  (MN-45.1)。**`withFallback` の既定は変えない** —— あれは tap/swipe/hideKeyboard を
  含む 14 操作と共有で、409 を既定に入れると全部を巻き込む(hideKeyboard は「409 では回さない」と
  決めている)。**`ref` ありは回さない** —— ref はブリッジごとに別名前空間で、この層には
  取り直す手段が無い(DSL は `typeViaTypeDriver` が typeDriver 側の snapshot で取り直す)
- **MCP(`ft_*`)の iOS の構成**(経緯: 2026-08-04 に「実行プロファイルのモードに追従する」= inapp モードも
  使う形にしたが、利用者の決定で取り消した。in-app を主にした合成 `HybridFallbackDriver` は今はライブ操作だけが使う)
  - **MCP の iOS は常に XCUITest**(ユーザー決定。in-app は使わない)。profile 無しで in-app のポートに繋いでも
    `ExploreDriverResolver` が同じデバイスの XCUITest へ振り替え(用意できなければ in-app へは落とさず断る)、
    udid だけの呼び出しは XCUITest のポートを先に採る(`MCPServer.explorationOrder`)。profile ありもモードを
    xcuitest に差し替えて供給する(`resolveProfileTarget`)。理由: in-app の合成タッチは注入される前提で作られて
    いないアプリ(Apple マップの経路カード)で効かないまま ok を返し、別アプリ・システムアラートの扱いでも
    ブリッジを意識させた。システムアラートは `ft_tap alertButton:`(SpringBoard へ向けて押し、`attach` で戻る)
  - **宛先そのものも探す**(`BridgeDiscovery`。2026-08-06)。`port` 未指定で既定 8123 が無応答なら
    範囲(8123〜8154)を走査し、**生きているブリッジが1本だけなら自動採用**(採用理由を stderr へ)・
    **複数ならデバイス名付きで列挙してエラー**(別デバイスを黙って操作させない)・0本なら
    `fleetest bridge up` を案内する。既定固定だと `bridge up` が別ポートを選んだ瞬間
    (稼働中ブリッジの再利用・pid ファイルの残り)に全ツールがタイムアウトする。
    **`port` を明示したときは探索しない**(宛先を利用者が決めている)。
    Android の `serial` 未指定も同じ規律(`AndroidSerialResolver`。1台なら自動採用・
    複数なら AVD 名付きで列挙。`-s` 無しの adb は複数台で "more than one device/emulator" になる)。
    `ft_run_scenario` の `profile` 無し経路も同じ解決を通す(片方だけ賢いと食い違う)
  - **タイムアウトは確かめてから断定する**(`MCPServer.connectionLostHint`。2026-08-12)。
    接続拒否(`bridgeConnectionRefused`)は「誰も待受していない」が確定なので従来どおり即断するが、
    タイムアウト(`bridgeUnreachable`)の素の文言は「未起動 / 遅い / suspend」の**3択を並べるだけ**
    だった —— 実アプリ監査で ft_type がこれで落ち、直後の ft_status は「そのポートにブリッジが無い」と
    一意に答えられた(判定材料はあるのに操作系が使っていなかった)。判定の順序が要:
    **先に当のポートを `BridgeDiscovery.isBound` で見る**。bound のときの言い分は**ブリッジで分ける**
    (`bridgeBusyHint(connection:bridge:)`)—— xcuitest は busy(整定待ちは実測 33.7s /status 無応答 >
    interaction timeout 20s)なので「まだ繋がっている・リトライせよ」だが、**in-app は suspend でも
    kernel が handshake を返すので bound のまま** = リトライは永遠に当たらない助言になる。
    こちらは「ft_launch で前面へ戻すか、その機の xcuitest ポートを使え」。どちらも
    **forgetConnection はしない**。bound でないときだけ全ポートを走査し、消えていれば死亡と言い切って
    忘れる —— 走査を先にすると busy なブリッジは /status に出ないため「exited」と誤診し、
    健全なブリッジの再構築へ誘導してしまう(`bridgeUnreachableVerdict` = 唯一の判定点・純粋関数・
    テストで固定)。
    掴んでいるポートは `connectedPorts` に持つ —— **表示用の `connections` の文字列から読み解かない**
    (表記を整えるたびに判定が壊れる)
  - **宛先は port だけでなく udid まで書く**(`MCPServer.connectionLabel`。2026-08-12)。
    ブリッジは落ちても monitor が別ポートで起動し直すので**同じセッション中にポートが動く**
    (実測: -03 が 8128→8126、-07 が 8136→8147)。port だけを覚えて使い回す読み手には、
    その port が今どの機かを確かめる手段が無かった。udid を申告しない旧ブリッジでは port だけ
    (「不明」と書くより短く、嘘も混ざらない)。**先頭は必ず `port `**(表示の整形規則。
    iOS/Android の判別はこの文字列からではなく `connectedPorts`/`connectedAndroidSerials` の
    記録で行う——後述)
  - **「応答しない」を「死んだ」と読まない**(`BridgeDiscovery.isBound`。2026-08-06)。XCUITest は
    整定待ちでブリッジのスレッドを数十秒ブロックする(外部ログで実測 33.7s)。/status が返らなくても
    **カーネルは accept する**ので、待受があるうちは乗り換えず「今は忙しい・少し待て」を返す。
    ここを緩めると、自動採用が防ぐはずの**別デバイスへの取り違えを自分で作る**
  - **未インストールのアプリを launch させない**(`MCPServer.installedVerdict` が判定材料を集め、
    可否そのものは `FTBridgeClient.InstalledAppCheck.launchGuard` の1箇所へ委ねる —— 2026-08-06。
    **2026-09-22 にライブ操作(`api live serve` の launch/activate)と共有する形へ統合**、詳細は
    DS-13.3)。`XCUIApplication.launch()` が未インストールで失敗すると、その issue は main queue 上
    (テストのスタック外)で記録されるため**ランナーごと落ちる** —— `requireLiveApp` が防いでいるのと
    同じ経路で、対処も同じ「XCUI に触れる前に弾く」。実測: 遊休ブリッジへ直接
    `POST /session {"bundleID":"<未インストール>"}` を投げると、無応答(待受のみ)を約5秒挟んで
    10秒以内にランナーが消える。**判定できないときは素通し**(実機・同名デバイス複数・simctl/adb 不調)。
    システムアプリ(springboard/Safari)は `get_app_container` が runtime のパスを返すので弾かれない
  - **inapp モードでも別 bundle(springboard・他アプリ)を開いたら読み書きごと XCUITest へ寄せる**
    (2026-08-06)。`HybridFallbackDriver.launch` は従来**必ず primary(in-app)** へ投げていたが、
    **in-app ブリッジは自分のプロセスの中しか見えない** —— `ft_launch com.apple.springboard` は
    「Launched」と成功を返したうえで、続く snapshot が**アプリ自身の古い木**を返していた
    (実測: ホーム画面を読もうとして 30 要素のアプリ画面)。
    寄せ先は `AppAttachDriver`(fallback)では駄目 —— あれは固定 bundle への attach 専用で
    `launch` が意図的に no-op。**セッションを張れる素の BridgeClient** を別に持たせる
    (`foreignApp`)。自分のアプリへ launch し直すと in-app 主へ戻る。
    モードを inapp に固定しても直らない問題なので、**モードの選択では解けない**
  - **ホーム画面・システム UI は `ft_launch com.apple.springboard` で読む**(XCUITest 経路のみ)。
    セッションはアプリに閉じているので、未起動での `ft_snapshot` は 409、`ft_navigate home` 後は
    木の読みの前面確認(`requireForegroundApp`)の 422 になる。`BridgeRouter.handleLaunch` は
    springboard を**起動せず参照だけ張る**特別扱いを持つので、これで木が読める
    (409 には `MCPServer.springboardHint`、home の後は `backgroundingNavigationNote` が案内し、
    422 はランナーの本文自身が springboard の読み方を言う)
  - **MCP の snapshot は必ずキャッシュを捨てて撮る**(`MCPServer.freshSnapshot`。2026-08-06)。
    Android の a11y ノードはキャッシュ供給で、**Compose のスクロール後は木が古いまま固まる** ——
    実測(E2E-CMP / Pixel 9・Android 15)では `ft_swipe` 後の画面が行08〜16 なのに木は行01〜10 のままで、
    撮り直しても数分待っても直らず、`ft_tap(#row_03)` が **`selected=row_10`** を返した。
    ブリッジ側の既定(WebView 内だけ `refresh()`)は**シナリオ実行**の実測
    (全ノードで snapshot +65ms・E2E-Android の sum +43%)に基づくもので、MCP は1手ずつ撃つ経路なので
    往復のほうが桁で大きく、この上乗せは見えない。**「ジェスチャの後だけ」のフラグ運用にしない**
    (立て忘れたツールが1つでもあると黙って古い木に戻る)。
    出るのは **Android の Compose だけ**(RecyclerView と Flutter は同じ手順で再現しない)
  - **ref は撃つ直前に撮り直して照合する**(`RefGuard` / `MCPServer.verifiedRef`。2026-08-06)。
    **ref はスナップショットごとに振り直される**ので、覚えた番号のまま撃つと別の要素に当たる。
    覚えた要素の同一性(identifier → ラベル+型 → 型+frame)で引き直し、
    **動いていれば新しい ref へ撃ち直す/消えていれば撃たずに理由を返す**。
    identifier を持つ要素がその identifier で引けないときは**ラベルへ落ちない**(別要素を掴む)。
    ghost 判定は `ContainerGeometry.isOutsideContainer` を共有する(MCP 側に別の閾値を置くと
    DSL と「ghost の定義」が割れる)。**ghost は撃つが黙っては撃たない**(下記)。
    **identifier で引き直したらラベルの変化も見る**(`RefGuard.labelChangeNote`。2026-08-10)。
    identifier だけで引き直すと、検索候補が更新された画面では**同じ id・別の行**を掴むことがある
    (実測: 「立川駅、最近表示した項目」を狙ったタップが「立川駅 南口、立川市」に化けた)。
    動いた距離とは無関係に出す(位置が同じでもラベルだけ変わった形は同じ危険)。
    再ターゲット後に実際に操作を撃つ経路(`verifiedRef` / double_tap・pinch・drag(fromRef) が
    通る `verifiedElement`)には同じ警告を入れ、存在確認だけの経路(スクロール探索の着地表示・
    フォーカス待ち)には入れない
  - **`ft_scroll_to` は DSL と同じ `StepExecutor` に委ねる**(2026-08-06)。整定待ち・キャッシュ回避・
    容器基準の刻み・ghost の掴み直し・飛び越しの拾い直し・打ち切りは全部あちらに入っており、
    **同じ知見の2つ目の実装を作ると必ず割れる**。MCP は FlowStep を1つ組んで投げるだけ =
    MCP で届く要素はシナリオでも届く
  - **実機ブリッジは `/status` で udid を申告しない**(2026-08-13。iOS 実機の初監査)。
    iOS 16 以降 `UIDevice.name` は伏せられ機種名("iPhone")しか返らず、`SIMULATOR_UDID` も
    存在しないため、`status.device` を鍵にした一致(`liveIOSBridges`)も `Found.udid` も
    原理的に実らない(`ft_list_devices` が実機を必ず「no bridge」と報告し、`udid:` で実機を
    指せない)。ホスト側へ `.fleetest/bridge-<port>.device` = port→実機 udid の記録を新設した。
    **書くのは `IOSDeviceTransport.establish` の1箇所**(lan/usb 両方が通る実機専用経路)、
    **消すのは `teardown` の1箇所**(`bridge down` から無条件に呼ばれる。仮想デバイスでは
    no-op)。`BridgeDiscovery.scan` は**`status.udid` の申告を必ず優先**し、nil のときだけ
    記録で補う(仮想デバイスは自分で正しい udid を出すので古い記録に引きずられない)。
    記録の無い旧ブリッジは従来挙動へ静かに落ちる。あわせて `scan(repoRoot: nil)` を修正した
    —— 記録を読めず 127.0.0.1 へ落ちていたため、lan トランスポート(LAN IP 直叩き)の
    実機ブリッジは一度も疎通されていなかった。
    **この記録は `ft_list_apps` の宛先解決にも使う**: 実機を **`port:` だけで指した**呼び出しは
    `udids[key]` が nil のまま(`ExploreDriverResolver` は `SimulatorCatalog` しか引かない)なので、
    `connectedPorts[key]` からこの記録を引いて実機 udid を得る。**実機かどうかの判定は
    `bootedSimulatorUDID` より必ず前**に置くこと —— あちらは実機で throw するので、
    後ろに置くと実機判定へ到達しない(`udid:` 経路で実際に踏んだ)
  - **`ft_list_apps` の実機経路は `devicectl`**(`IOSPhysicalAppCatalog`。2026-08-13)。
    `simctl` は実機 udid を渡すと `Invalid device` で落ちるので
    `xcrun devicectl device info apps --include-all-apps --json-output` を使う。
    **user/system は `bundleIdentifier` の `com.apple.` 接頭辞で分類する** ——
    devicectl の既定一覧(`--include-all-apps` 無し)は `builtByDeveloper` だけで
    App Store アプリが漏れ、`url` の `/System` でも分類できない(Safari も Apple マップも
    `/private/var/containers/...` に居る。実測: 全287件・非Apple 206件)
  - **接続断からの回復は表示ラベルでなく記録で振り分ける**(`connectedPorts` /
    `connectedAndroidSerials`。2026-08-14)。`connectionLostHint` は `connections[key]`
    (表示用ラベル)の接頭辞 "port"/"serial " で iOS/Android を判別していたが、`profile:`
    経由のラベル(例 `"iPhone wave(実機) port 8144"`)は**どちらの接頭辞にも一致せず**、
    profile: のセッションは iOS も Android も回復機構(`forgetConnection`)に一度も
    入っていなかった。同じ根が3箇所 —— `connectionLostHint` の iOS/Android・
    `forgetConnection` の Android(serial をラベルから `dropFirst` で切り出していた)。
    **表示文字列で制御を分岐しない**のが教訓(表記を整えるたびに判定が壊れる。上の
    `connectionLabel` の注意と同型)。あわせて `connectedPorts[key] = probePort` を
    `probePort ?? provisioned.port` に修正(`probePort` は実機で常に nil。同じ根の消費側が
    2つあり片方だけ直っていた掃討漏れ)。**純粋関数・単体テストが正しく緑でも、この配線の
    手前で弾かれていれば何も改善しない**(教訓の詳細は docs/verification/ 参照)
  - **ブラウザの取りこぼしは「空白の幾何」で言う**(`MCPServer.webViewGapNote` /
    `gridWithoutHeaderNote`)。ブラウザは画面に描いているものを a11y へ出さないことがあり
    (Android の Chrome が顕著)、**木に無い要素は待つことも探すことも指すこともできない**のに
    応答からは気付けなかった。判定は幾何だけ = webView の中で**どの葉とも交わらない連続帯**。
    2つの規律がある:
    - **閾値を超えた帯は全部数える**(2026-08-13)。最大の1本だけを返していた頃、Yahoo!天気の
      週間画面では 345px の帯だけが報告され、**黙って落ちた 268px のほうに週間表の日付・
      気温・アイコンが丸ごと入っていた**。読み手は「警告された1箇所以外は揃っている」と読むので、
      1本だけ言うのは黙るより悪い。名指しは3本まで(`webViewGapBandsReported`)・残りは件数で言う
    - **格子の見出し欠落は「見出し行が入る余地」まで見る**(2026-08-13)。値のセルが揃っている
      のに列見出しだけ無い形は `gridWithoutHeaderNote` が名指しするが、**見出しが値と centerX で
      揃っていると見出し自身が格子の最上行として鎖に取り込まれる** —— 「直上が空か」だけでは
      見出しの在る格子と区別が付かず、実アプリで誤検知2件(同じページの2つの表)を出した。
      直上の空き ÷ **行間の中央値**が `gridHeaderRoomRatio`(2.0)以上のときだけ言う
      (実測比: 誤検知 1.16 / 0.54 に対し真陽性 4.4)。中央値なのは、実測の格子が途中に
      別セクションを挟んで間隔を飛ばすため(平均だと1本の飛びで閾値が跳ね上がる)
    - **webView ノードごと無い形は別の注記が要る**(2026-08-13。`missingPageContentNote`)。
      `webViewGapNote` は `type == "webView"` の**中**しか測れず、`emptyTreeNote` は
      `elements.isEmpty` **ちょうど**が条件なので、**Chrome が自分の chrome しか公開しない**
      画面では両方が黙る —— **状況が悪化したほうが黙る**逆転になっていた(直前の読みでは
      webView ノードがあり `webViewGapNote` が出ていた。実測 = 画面は表で埋まっているのに
      木は19要素、のち1要素)。判定は幾何のまま**画面全体**へ広げ、
      `unrepresentedScreenFraction`(どの要素とも交わらない最大の帯 ÷ 画面高)が 0.5 以上・
      URL バー在り・webView 無しの3条件。**URL バーを条件に入れるのは必須** ——
      オーバーレイが背景を落とす形(`and-overflow` 56.4%)は正常なので、これが無いと誤検知する
      (コーパス実測: witness 88.6% / URL バー有り webView 無しの次点 `and-browser_urlmenu` 5.9%)
  - **注記が載る応答は目録の `contexts` で決める**(`NoteCatalog.Context`)。**`ft_scroll_to` には
    「この一覧をそのまま報告してよいか / この行を指せるか」を言う注記を載せる**
    (`urlishLabelsNote` / `ambiguousLabelsNote` / `duplicateIDsNote` / `emptyTreeNote` ほか。
    2026-08-13)。`ft_scroll_to` は「swipe + snapshot の繰り返しの代わりに使え」と自ら勧める
    経路なので、**警告が落ちる側が常用経路になる** —— 実測では `link "13101"`(実際の描画は
    「千代田区」)を無警告で返し、同じ画面を `ft_snapshot` で撮り直して初めて出た。
    手数が増えるだけの注記(`unlabeledClickablesNote`)やスクロールで変わらないもの
    (`addressBarNote`)は載せない。**増やすときは Scripts/mcp-bench.sh の手数で決める**
  - **横スクロールの残骸は「同じ y・違う x で繰り返す区間」で言う**(2026-08-13。
    `duplicateRegionNote`)。WebView の表を横へ送ると、**スクロール前の行が古い x のまま木に残り、
    新しい行が並んで入る** —— 実測(気象庁)は同じ y の行が 200pt ずれて二重に並び、左端は
    x=0 へクランプされ、**約55行のうち印が付いたのは4行**だけだった。既存の3経路はどれも
    構造上当たらない: `outsideDeclaredScroller` / `isUntappableGhost` は「容器と**交差ゼロ**」が
    条件で x=0 は容器の**内側**、`stackedRefs` は「**同一矩形が3個以上**」が条件で複製は2個。
    しかも **WebKit の横スクロール div は `scrollable` を申告しない**(iOS の `scrollableTypes` は
    scrollView/table/collectionView のみ)ので、内側の容器そのものが木から見えない。
    **幾何条件を落とさないこと** —— 素の「最長反復区間」にすると、**1ページ内の2つの表が
    同じ見出し行を共有しているだけ**の形を掴む(実測で11行。設計中に気付いて足した)。
    実測は witness 10 に対し他フィクスチャ最大3。
    `ContainerGeometry.hasClampedCoordinates` は流用できない(あちらは**同一矩形・同深さ3個以上**が
    条件で、ここは矩形が違い x だけ揃う形)
  - **「変わっていない」の判定は木の**外**の数字も見る**(2026-08-13。`looksUnchanged`)。
    `SnapshotResponse.elements` は**ブリッジが上限で切った後**の列で、落とした数は
    `truncatedCount` に別で載る。要素だけを比べていたため、**上限より下だけが変わった操作**を
    「変化なし」と報告していた(実測: 表を横送りするタップで113要素増えたのに、上限120の内側が
    バイト一致で `waitForChange` が空振り)。**呼び手は回避できない** ——
    `maxElements` は `ft_snapshot` にしか無く、待ちの中の `freshSnapshot` は常に既定値で走る。
    併せて、**木が空同然の画面では「変化なし」が常に真になる**(空の木は空の木と一致する)ので、
    `unrepresentedScreenFraction` が 0.5 以上のときは判定に
    「『動かなかった』と『公開されていない』を区別できない」但し書きを付ける
    (実測: `scrollDown ×4` が実際に数画面送ったのに `ft_batch` が「どのステップも画面を
    変えていないかもしれない」と言った)。**判定はこの1本のまま**(2つ目を書かない)
    **手ごとの「何も起きていないかもしれない」も結論で言う**: ok の tap の前後で木の内容が同じ(次の tap の撃つ前の木・最後の木と
    比べる。署名は飲まれたタップの診断と同じ `StepExecutor.sameContent`)か、disabled な要素への touch なら、その行に警告を添え
    結論を「passed」と言わない(実測: シートが出てくる途中の tap が飲まれ、disabled の「完了」も ok で "All 4 step(s) passed")。
    失敗にはしない(DSL と同じ)・打つ前に待たない。木が空同然の画面(上の但し書きと同じ閾値)では手ごとに名指さない。
    **比べるのは tap の手だけ**(select / waitForSettle のような掴むだけの手は直前の tap の記録が残るので、その手で比べると誤る)
  - **スクロール残像(ghost)は拒否せず、警告して撃つ**(`RefGuard.ghostWarning`)。
    Compose iOS は容器の外へ出た行をフルフレームで木に残し、`ios-xcuitest` はそれを座標で叩く
    (実測では下部タブへ遷移して "tap done" を返した。`ios-inapp` は要素起動なので当たる =
    モードで割れる)。**応答に「何に当たったかもしれないか」を添え**、一覧の行にも
    `⚠️scroll-leftover` を出す(`MCPServer.ghostNote` / `ghostFlags`。先頭の注記だけでは、
    行から ref をコピーする動作に届かない)。

    **印は2種類に割る**(2026-08-09)。`⚠️scroll-leftover` は「撃つと別の物に当たる」
    (沈黙した誤操作)、`⚠️offscreen` は「今そこに無い」だけ。**割る基準は打ち手ではなく危険度**
    —— どちらも対処は `ft_scroll_to` で出し直すことだが、同じ重さで並べると本物の残骸が
    埋もれる(実測: Apple マップの経路詳細で、シートを広げた後の `y=-59` の行まで
    「別の物に当たるかも」と警告されていた)。判定は `TapTargetGeometry.offscreenAdvisory`
    (中心が画面の外)で、**画面外を先に見る** = `RefGuard.preTapWarnings` の優先順位と同じ。
    揃えるのは、同じ要素について**ツールごとに言うことが変わらない**ようにするため。
    **`⚠️offscreen` の一覧注記は方向まで言う**(2026-08-10。`MCPServer.offscreenDirection`):
    中心のはみ出し量が大きい軸(below/above/right/left)で方向グループに分け、
    `ft_scroll_to` の `direction:` へそのまま渡せる語(down/up/right/left)を添える。
    旧文言「scrolled past」は削除した —— 実測(Apple マップの経路候補・横ページャ)で、
    一度も表示していない右隣ページの要素に「スクロールで通り過ぎた」は不正確だった。
    **左右方向の `⚠️offscreen` があり、かつ画面に `pageIndicator` が居るときだけ**、
    横ページャが1ページずつしか描画しないこと・`ft_scroll_to` で届くことを1文添える
    (`MCPServer.ghostNote` の `pageIndicatorHint`)。縦方向だけの offscreen やページャの無い画面では
    何も足さない

    当てる相手は `OcclusionGeometry.occluder`(中心を覆う別要素。実体は FTCore で DSL の
    タップ前警告と共有・`RefGuard` は転送)。**遮蔽と数えないものが7つ**ある:

    | 除外 | 理由 | 外すと起きること(すべて実報告) |
    |---|---|---|
    | ① 相手自身が ghost | **描かれていないものは何も覆えない** | 設定アプリの「閉じる」が、画面外へ出たリスト行 `clickable (16,484 370x52)` に弾かれる |
    | ② 何も描いていない葉コンテナ | label も value も子も無い `other` は画面に何も描いていない | 起動直後の「スキップ」と検索サジェスト先頭が `#compass_container`(全幅・非 clickable・葉)に弾かれる |
    | ③ 自分を丸ごと包む、**画面規模の**相手 | 全画面の暗幕・toolbar は遮蔽ではなく容器 | 同じ「閉じる」が全画面の `#AdditionalDimmingOverlay` / `Toolbar` に弾かれる |
    | ④ 自分の祖先と子孫 | 自分を含む容器を数えない | 「自分より深いものだけ」に絞ると、残像に重なる下部タブ(**浅い**)を見落とす |
    | ⑤ **奥に描かれている相手**(`drawnAbove`) | 奥にある物は覆えない | Apple マップの `#MapsSearchBar` が中の `#userProfileButton` を覆う扱いになる(2026-08-07) |
    | ⑥ **矩形がぴったり同じ相手** | 同寸同位置は「上に載った物」ではなくラッパーか入れ替わり。本物の積み重なりは `stackedRefs` が別に見る | 出ていない `#SearchAutocompleteView` が出ている `#ResultsViewTable` を覆う扱いになる(同 (0,62 402x812)) |
    | ⑦ **いちばん内側の入れ物より外の枠**(`enclosesAnInnerWrapper`。**z が無いブリッジだけ**) | 「自分を包むもっと小さい何か」ごと包む相手は外枠 | `#HomeView` が `#MapsSearchTextField` を覆う扱いになり、素の `ft_type` が毎回警告付きになる |

    **⑤の「奥/手前」はブリッジの申告(`ElementInfo.z`)が最優先で、無ければツリー順へ落ちる**。
    ツリー順は描画順の代理として使ってきたが production では裏返る —— Google マップは
    地図の chrome(ref 81〜86)をシート(ref 17〜61)より**後**に出すのに描画はシートが手前で、
    シートの裏の `#mylocation_button` を無警告でタップして裏の広告を踏み、**Chrome が起動**した
    (2026-08-07 実測)。Android は `getDrawingOrder()` を根から積んで
    `SnapshotBuilder.assignPaintOrder` が通し番号にして送る(**段ごとの値ではホストで合成できない**
    —— 出力ツリーは中間ノードを間引くので2要素の共通祖先が残っていない)。
    iOS(XCUITest / in-app)は描画順を読む API が無いので**ツリー順のまま**で、⑦の推測が要る。
    **z があるときは⑥⑦を使わない** —— 真値がある場に当て推量を混ぜると真値を打ち消す
    (実測: 地図側の容器が「内側の入れ物」に当たってシートの遮蔽が消えた)。

    **①を③より先に見る** —— ③の包含判定は 1pt の差で外れるほど際どい
    (実測: 閉じる `y483..521` 対 残像 `y484..536`)。閾値では守り切れない。
    本物の遮蔽は**一部しか重ならない**ことが多い(残像 `#row_11` (16,790 370x56) に対し
    下部タブ `#tab_controls` (134,792 134x48))。

    **③に「画面規模」の条件が付いているのは、包含を無条件に容器と読むと逆側へ倒れるから**
    (2026-08-07)。app bar の下へスクロールで潜り込んだ行はまさに「丸ごと包まれる」形で、
    無条件に除外すると**タップしても何も起きないのに警告も出ない**
    (実測: `#transit_station_title_name` (285,0 510x85) が `#header_container` (0,0 1080x290) の下)。
    包含する相手のうち**面積が画面の `fullScreenContainerAreaRatio`(0.5)以上**のものだけを
    容器とみなす —— 暗幕・全画面 toolbar は 100%、app bar は 12% で分かれる。
    **②と③は表と裏**(②を足すと鳴りすぎが止まり、③を緩めると黙りすぎが止まる)なので、
    片方だけ動かすと残る側が悪化する。

    **これでも誤検知は残る**。木の幾何だけでは「実際に描かれているか」を決められない ——
    最後に出たのは**キーボードの下**にある普通の行で、キーボードはスナップショットから
    丸ごと除外している(キー1つ1つが Button として写り込むため)ので frame すら取れない。
    だから**拒否ではなく警告**にしてある。ここを再びブロックへ戻さないこと。

    **教訓(この検知で誤検知を5形出した)**: `isOutsideContainer` は DSL では
    「掴み直して送り直す」= やり直しの合図で、外れても次の周回で回復する。
    **同じ判定を拒否へ格上げすると、外れがそのまま機能の喪失になる**。
    強度を変えて再利用するときは、外れたときの損害が同じかを確かめる。
    なお5形とも**利用者の実アプリで出た** —— 4 SUT 全画面(84画面)の掃討では1件も出ていない。
    **2026-08-07 に同じことが繰り返された**: 実アプリ(Google マップ)の1セッションで誤検知が
    3種類(上の②、③の緩和で塞いだ見逃し、積み重なりの件数判定)出たが、同じ日の
    自前 SUT 掃討では**3 SUT とも 0 件**だった。この検知系で「自前 SUT の誤検知 0」は
    production を代表しない。掃討は `Tests/Fixtures/RealAppSnapshots/` の固定コーパス
    (`SweepHarnessTests`)で実アプリにも当てる。
  - **容器の中に居ても別の物に当たる2形**(2026-08-06。`RefGuard.overlapWarning`)。
    上の ghost 判定は `isOutsideContainer` を**入口条件**にしているため、この2形を1つも捕まえない:

    | 形 | 実測 | 判定 |
    |---|---|---|
    | 上に描かれた overlay に覆われている | E2E-iOS のホームで `#nav_heal` (16,788 370x62) が下部タブ `#tab_controls` (134,778 134x62) の下。ref タップが**コントロールタブへ遷移**して "tap done" | `overlayCovering`: `occluder` のうち**木の順序で後ろ**にあるものだけ(先に並ぶ大きな背景パネルを遮蔽と読むと、拒否をやめる原因になった誤検知に逆戻りする) |
    | 同一矩形に積まれている | E2E-iOS のスクロール画面で `行 09`〜`行 40` の staticText **29 個が全部 (16,270 330x56)**(= `行 01` の位置)。ref タップが `selected=row_01` | `stackedRefs`: 同じ矩形を共有するもののうち、**label か value を持つものが3つ以上**。**入れ子の一本鎖は数えない**(Android のダイアログは `action_bar_root`→`content`→`parentPanel`→`customPanel`→`custom` が全部同じ矩形) |

    **数えるのを「中身を持つもの」に限るのは、件数だけだと普通の木が鳴るから**(2026-08-07)。
    同一 bounds のラッパー連鎖は Android ではありふれていて、実測では
    `#expandingscrollview_container`/`#cardui_cardlist`/`#recycler_view`/`#home_bottom_sheet_container`
    の4件(中身は普通の可視ボトムシート)が積み重なり扱いされた。元の実測ケース(行01へ畳まれた
    staticText 29 個)はどれもテキストを持つので、この制限でも引き続き捕まる。

    どちらも**拒否せず警告**(ghost と同じ理由)。積み重なりは一覧にも `⚠️scroll-leftover` を出す ——
    利用者から見ると原因も打ち手も ghost と同じなので**印を2種類に割らない**。
    **例外はキーボード被覆**(ユーザー決定 2026-09-14。`MCPServer.keyboardRefusal`): 中心がソフト
    キーボードの下にある要素への ref 操作(tap / long_press / type / clear / double_tap・batch の1手目)は
    **両ブリッジとも断る**。ghost と違って結果が確実で副作用がある —— XCUITest はキーの上に指が落ちて
    焦点の欄に文字が入り(実機 SE3・`#tab_about` で「o」)、in-app は 422 で断っていた = ブリッジで
    割れていた。判定は ref 形・DSL と同じ `KeyboardOcclusion`(chrome 除外済み)。**座標形は断らない**
    (キーを押す意図があり得る。`keyboardCoordinateWarning` で警告)。**DSL の tap は据え置き**(注記)
    誤検知ゲートの回し方は docs/verification/(**自前 SUT だけでは足りない** ——
    `Tests/Fixtures/RealAppSnapshots/` の固定コーパスで実アプリにも当てる)。
  - **自分の子孫が中心を横取りする形**(2026-08-09。`TapTargetGeometry.nestedActionCoveringCentre`)。
    上の `occluder` は**祖先と子孫を除外する**(親子の重なりは正常な入れ子で、数えると何でも
    遮蔽になる)ので、この形を1つも捕まえていなかった。実測(Apple マップの検索候補):
    `#Maps.PlaceTableViewCell` (20,138 362x155) の中心 (201,215) が、同じセルの中の
    `#FeaturedInMultipleGuidesContextLineItem` (80,202 205x18) の内側にあり、ref タップは
    **場所カードではなくガイド一覧を開いて**無警告で "done" を返した。兄弟の重なり
    (`#FavoriteButton` × `#TransitDepartureRow`)では警告が出ていたので、**差は「子孫かどうか」だけ**。
    条件は「親が対話的」「子孫も対話的」「面積比 < `nestedActionAreaRatio`(=0.25)」の3つ:
    比の上限は**行を包み直すだけのラッパー**(同セル内の無名 button は 0.99)と**行の主ラベル**
    (`#MultiTextView` は 0.31〜0.49 で、押しても行と同じ場所が開く)を外し、
    **行の中に別の遷移先を持つ小さな帯**だけを残す値。コーパス全数(18枚)で発火は
    `#PinnedItemSection` ← `#PinnedTile`(帯を撃つとタイルが開く = 真陽性)の1件だけ。
    非対話の容器は `missesItsOwnContent` の担当なので**排他**(二重に言わない)。警告のみ
  - **申告されたスクロール容器の外へ送り出された行**(2026-08-09。
    `TapTargetGeometry.outsideDeclaredScroller`)。ghost 判定(`ContainerGeometry.isOutsideContainer`)は
    容器を**木の並びから推測する**ので、申告のある UIKit/SwiftUI では推測が中間ノードに当たって
    nil に落ち、1件も付いていなかった。実測(Apple マップの場所カード): カードを送ると
    `#MUScrollableStackView` (0,72 402x802) の上へ抜けた行が frame ごと木に残り、
    `link "ウィキペディア"` (16,-2 85x18) への ref タップが "done" を返して、実際には
    中心 (58,7) = ステータスバーに当たり**カードが先頭へ飛んだ**。
    こちらは推測せず **`scrollable` を申告している祖先だけ**を見る。
    **ただし depth からの祖先復元はブリッジの間引きで嘘になる** —— Google マップの検索結果では
    カード容器が落ちた結果、本文(depth 20〜22)が直前の写真カルーセル `#recycler_view`(depth 19)の
    子孫に見え、素の判定では**10件まとめて誤検知**した。そこで `clippingContainer` と同じ
    「その depth の兄弟が2つ以上、容器の中に居る」を条件に足す(間引きで繋がっただけの相手は
    仲間が容器の中に1つも居ない)。一覧の印は ghost と同じ `⚠️scroll-leftover`
    (原因も打ち手も同じなので**印を割らない**)
  - **`ft_pinch` は座標(`x`/`y`[+`radius`])でも対象を指せる**(2026-08-09)。地図やキャンバスは
    要素として木に無いので `ref` を渡せず、対象を省くと指が画面全体に開く —— 実測(Apple マップ):
    場所カードを半分出したまま `scale 0.4` を撃つと**地図は 1px も動かず、シートが全画面に展開した**。
    既定の半径は**画面の短辺の 22%**(座標系が iOS=pt / Android=px で桁が違うので固定値にしない)、
    画面の内側へクランプする(外へ出た指は届かず、要求より小さいズームになる)。
    **XCUITest も 2026-09-22 から座標で撃てる**(`CoordinatePinch`。それまでは
    `XCUIElement.pinch` しか無く領域を読めなかったので「x/y は honour できない」と断っていた)——
    公開 API に座標版が無いので**非公開の `XCPointerEventPath` / `XCSynthesizedEventRecord`** で
    経路を組む。**実行時に存在を確かめ、無ければ要素ピンチへ縮退して戻り値で必ず言う**
    (黙って退化させると「狙った場所を撃ったつもりで手前のシートを掴む」= この修正の動機そのもの)。
    **ホスト側で先回りして「無視した」と言わない** —— 縮退したかを知っているのはブリッジだけ
  - **ソフトキーボードの遮蔽は木からは原理的に判定できない**(2026-08-08)。iOS xcuitest は
    `.keyboard`/`.key` サブツリーを木から除外しており、残る外側コンテナ(`inputView`)は
    子孫ゼロの空葉になって**空葉除外(誤検知対策)に正しく弾かれる**。Android は IME が
    別プロセスの別ウィンドウで木に出ない。実害は両 OS で実測済み: iOS はキーボード下の
    候補行への ref タップが顔文字キーに化けて検索欄を汚し、Android は Gboard の
    レイアウト選択シート下の候補タップが IME の「QWERTY」選択に化けた —— どちらも無警告。
    だから**ブリッジが `SnapshotResponse.keyboardFrame` で実矩形を申告する**:
    | ブリッジ | 取得元 | 罠 |
    |---|---|---|
    | iOS xcuitest | 走査中に見た `.keyboard` ノードの frame | — |
    | iOS in-app | `keyboardWillChangeFrame` 通知の最新値 | **TextEffects window の frame を使ってはいけない**(開いていても全画面 (0,0 402x874) が返り、画面上部の要素まで誤警告する。`UIInputSetHostView` のクラス名走査も iOS 27 で不発 — どちらも実測)。通知値が無ければ frame は申告しない(誤検知側に倒さない) |
    | Android | `UiAutomation.getWindows()` の TYPE_INPUT_METHOD の bounds(要 `FLAG_RETRIEVE_INTERACTIVE_WINDOWS`) | — |
    判定は `TapTargetGeometry.keyboardCoveredAdvisory`(中心が keyboardFrame 内)1箇所で、
    DSL はステップ注記・MCP はタップ警告 + `ft_snapshot` / `ft_scroll_to` の note に使う
    (note は覆う矩形を常に申告し、その下に操作対象が居るときだけ ref を列挙する)。
    **警告のみで拒否しない**(新しい検知は警告から)。旧ブリッジは申告しない = 黙って従来どおり。
    Android は `getWindows()` を毎 snapshot 叩く(dumpsys と違い a11y 内 API で安い。ただし
    `FLAG_RETRIEVE_INTERACTIVE_WINDOWS` をブリッジ起動時に恒久で立てる副作用がある)。
  - **iOS の `keyboardFrame` はキー面だけで、実際に覆う面積より狭い**(2026-08-13)。
    `.keyboard` ノードの frame をそのまま申告しているが、上のサジェストバー
    (`SystemInputAssistantView`)と地球儀/Dictate 行を含む `inputView` の下端を含まない
    (実測: 仮想デバイス iPhone 17 Pro / 402x874 で申告 y=583..816 に対し木の chrome は y=538..874。
    実機 iPhone 15 Pro でも上45pt・下58pt が同様に欠ける)。中心点判定
    (`keyboardCoveredAdvisory`)は正しいのに、**渡す矩形が狭いせいで隠れた要素を見落とす**
    ——「キーボードは何も覆っていない」という偽の全クリアが出た(witness: `#tab_home` が
    キーボードに完全に隠れているのに note は無警告で、直後の `ft_tap` 自身が別要素への
    誤爆を警告するという2機構の矛盾)。**中心点判定は変えない**(矩形1pt重なっただけの入力欄まで
    警告すると誤検知になる) —— `FTCore.KeyboardOcclusion` が申告と木の chrome
    (`inputView`/`SystemInputAssistantView`。**申告と交差するものだけ**)を足し込んで実効矩形を作り、
    MCP/DSL の呼び出し側全員(MCPServer+Snapshot.swift / MCPServer+Hints.swift /
    MCPServer+GesturesTools.swift の ftDoubleTap / StepExecutor+Actions.swift)がこの型を通す。
    chrome が木に無ければ申告どおり(Android は既に画面下端まで届いており対象外。ブラウザの
    WebView 内キーボードは chrome がツリーに出ないため同様に対象外)。
    **広げるだけでは雑音になる**: キーボード自身の部品(地球儀キー・変換候補バー)まで
    「キーボードの下に隠れている」に該当し、**注記は先頭8件しか名指ししない**ので本命が枠から
    押し出される。chrome 自身とその部分木(木は親→子順+`depth`)は除外する ——
    覆っている側を「覆われている」とは言えない。実測(`ios-maps_suggest_keyboard`):
    16件(修正前・見落とし)→ 30件(広げただけ・雑音)→ **20件**(除外後)で、増分4は
    **本当にキーボードに隠れた5件目の検索結果** `#Maps.PlaceTableViewCell`(y=836..906)。
    **拾い直しが要る**: `SystemInputAssistantView` は申告矩形と縁が接するだけで交差しないので
    最初の走査に入らない —— 実効矩形で chrome を引き直さないと、その部分木が除外から漏れる
  - **「セレクタを書けない」と言う前にスコープ記法を試す**(2026-08-09)。ラベルも id も無い
    clickable の注記は「ref か座標でしか指せない」と言い切っていたが、**id を持つ祖先があれば
    `#container >> .clickable[n]` で書ける**(スコープ記法。docs/commands.md)。実測(Google マップ
    の経路画面): 移動手段タブは id もラベルも無い clickable だが `#directions_mode_tabs` の中に
    居り、この形で一意に指せる —— タブのラベルは「58 分」のように**検索ごとに変わる**ので、
    ラベルで書くこと自体が誤り。`MCPServer.scopedSelector` が組み立て、**祖先の id が画面で
    一意でなければ nil**(`#recycler_view` が4つある画面で別の容器を掴むため)。
    祖先も名無しなら従来どおり「ref か座標」と言う
  - **半開きシートを広げる操作を座標の手計算にしない**(2026-08-09)。`ft_drag` が
    `fromRef`(要素の中心から。撃つ直前に撮り直して照合する)と `dx`/`dy`(移動量)を受ける。
    実測では `#Card grabber` の frame を人が読んで `ft_drag (200,664) → (200,120)` を組んでいた。
    **シートが折りたたまれていること自体は注記にしない** —— 状態を持つのは
    `#Card grabber` の value のような**アプリ・ロケール固有の文字列**で、それを条件にすると
    Apple マップの日本語表示にだけ効く判定になる。気付ける場所は探索が止まった瞬間なので、
    そちらは scrollTo のヒント(下記)で塞ぐ
  - **scrollTo の「シートを広げろ」ヒントは scrollFrame 未指定でも出す**(2026-08-09)。
    以前は `step.scrollFrame != nil` を入口にしていたため、同じ画面でも**指定した2回目にしか
    出なかった**(実測: Apple マップの経路手順で、未指定の1回目は「content no longer moved」
    としか言わず、scrollFrame を渡した2回目のヒントで初めて解けた)。未指定のときは
    `StepExecutor.partialHeightSheetExists` が**申告のあるスクロール容器の高さ**で判定する ——
    帯は画面の 15〜80%(下端はチップ行・横カルーセル ≒5% を落とし、上端は全画面リストを落とす)。
    実測でヒントが要った容器は 22%(`#TransitDirectionsListView`)と 37%(`#directions_group_list`)
  - **細帯(sliver)の注記**(2026-08-08): 幅・高さのどちらかが 10 以下の、極端に細いラベル付き要素
    (実測: 右端で 9x137 に切れたタブ「サンライズ瀬戸」)は掴めないことが多いので
    `ft_snapshot` が note で名指しする。判定は `TapTargetGeometry.isClippedSliver`
    (ラベル2文字以上 + 細い辺 ≤10 かつ対辺 ≥30。アイコン 9x13 等は対辺条件で除外)。
    **判定は要素自身の細さだけ**(縁で切れた結果か、元々細いだけかは幾何を見ないので判定しない)。
  - **明示した scrollFrame が解決できないときは、スワイプを1本も送らずに失敗する**
    (`ScrollSearchResult.scrollFrameMissing`。2026-08-08)。以前は「matched nothing →
    全画面スワイプ」へ黙って退化しており、Apple マップで snapshot が scroll と申告した
    `#MUScrollableStackView` が直後に 120 件 cap で木から落ち、退化したスワイプが
    カードの「計画」ボタンを発火して画面遷移した。cap 側の対策(scrollable の cap 免除)と両輪。
    範囲と細部:
    - **scrollTo 探索だけでなく `scrollDown` 等の単発スクロール・`scrollToBottom` 等の
      端送り・flick 系・`withScroll*` 配下の探索も同じ**(全画面退化はどれでもボタン誤発火に
      なり得る)。**`select` 系だけは例外** — 「掴めなければ空要素を返す」契約が優先し、
      fail-fast も skipped になる(失敗はしないが探索もしない)
    - **探索中に容器が消えた場合も失敗**にするが、文言は分ける(スワイプ済みなら
      「disappeared after N swipe(s)」— 0本のときだけ「実行していない」と言う。
      動詞は呼び手ごと: search was not run / swipe was not sent / flick was not sent)
    - **判定はセレクタ照合そのもの**(`Self.match`)で行う。`scrollContainer` の nil を
      流用してはいけない — あちらは `FT_SCROLL_TARGET=legacy`(座標スクロールの殺しスイッチ)
      でも nil を返すため、殺しスイッチが「全 scrollFrame シナリオ即死」に化ける。
      **legacy 時は fail-fast ごとスキップ**して従来挙動へ落とす
    - **容器は解決したが動かせる幅が無い**(margin で潰れた等)場合は従来どおり全画面へ
      落ちるが、注記(`resolved but leaves nothing to move`)で申告する
    - scrollFrame 未指定の全画面スワイプは従来どおり(正当な既定)。
  - **`ft_swipe` にも `scrollFrame` を置き、実装は `StepExecutor` へ委ねる**(2026-08-12)。
    動機は実機観測: web ページの中の**横スクロールする表**を動かす手段が無く、`ft_scroll_to` も
    使えなかった(狙う見出しがそもそも木に無い)。**FlowStep(action: "scroll") を組んで投げるだけ**に
    する —— DSL の `scrollDown/scrollUp/scrollLeft/scrollRight(scrollFrame:)` と同じ形で、
    `ScrollGeometry` の呼び出し・マージン定数・容器解決・fail-fast は全部あちらに1本化されている。
    **直に `driver.swipe(_:intent:path:)` を叩いてはいけない**: in-app ブリッジは Compose/Flutter で
    領域指定つきスクロールを 501 で拒否する設計で、その 501→XCUITest フォールバックは
    `StepExecutor.swipeWithFallback` にしか無い(直叩きだと in-app ブリッジ単独で 501 のまま終わる)。
    **`direction` は指の向きのまま渡す**(action `"scroll"` は指の向きとして読む。逆写像は不要)。
    - **`scroll` アクションは `scrollFrameRect` を見ていなかった**(2026-08-12 に発見・修正)。
      `flick`/`scrollTo` は rect を先に見るのに `scroll` だけが locator しか見ず、木を撮る条件も
      locator の有無で決めていたため、**ref 形の scrollFrame が黙って全画面スワイプへ退化**していた
      (`scrollContainer` は rect を先に返すが、木が無いと viewport が無く path ごと nil になる)。
    - **効くのは「木に出ている容器」だけ**。web ページの入れ子 `overflow-x` のように容器が
      木に現れない相手には効かない(実測: ページ全体を渡すと中心線が表の外を通り、`ok` を返して
      1px も動かない)。**その場合の逃げ道は `ft_drag` の座標指定**で、これは実測で動いた。
      ツール定義にもこの2点を書いてある
  - **`ft_scroll_to` は「返す木にそれが居るか」を確かめてから成功と言う**(2026-08-06)。
    探索のスワイプは**タップ可能な行を発火させることがある**(SwiftUI の SUT で実測)。
    そのとき executor は途中の観測で passed のまま、撮り直した木は別画面になり、
    「scrolled to "#nav_diagnostics"」+ **その id が居ない診断画面の木**が返っていた
    (E2E-iOS のホームで決定的に再現)。照合は `matches`(waitFor と同じ = DSL と同じ)で行う ——
    `scrollTo` は `StepOutcome.resolvedElement` を載せないので、そちらを当てにすると一度も走らない。
    - **この撮り直しは節約の対象ではない**(2026-08-12 に最適化を実装して**撤回**)。
      iOS の `ft_scroll_to` は対象が既に画面内(0スワイプ)でも 5.35s かかり、内訳は
      **探索 2.0s + この撮り直し 2.0s**(注記の生成は主因ではない —— `FT_MCP_NOTES_OFF=all`
      でも差が出ない)。executor が解決に使った木を持ち帰って撮り直しを省く実装を入れたところ、
      **既存の回帰テスト2本が落ちて構造的な穴が見えた**: 撮り直しを省くと、この照合と
      「中心が画面外へ動いた」ゲート(`MCPScrollToOffscreenGateTests`)が**どちらも定義上通る**
      ようになる(返す木 = 照合した木なので必ず一致する)。後者は **0スワイプの witness を持つ**
      (Apple マップの経路ページャは読み取りの合間に自分で動く)ので、スワイプ数では守れない。
      **2枚目を読むこと自体が砦**なので、速さと引き換えにしない。
  - **木が「起動したアプリのもの」かを突き合わせる**(`MCPServer.switchedAppNote`。2026-08-06)。
    Android のブリッジは session を**前面ウィンドウ**から採る(`root.getPackageName()`)ので、
    back でアプリを出ると session ごと別アプリへ移り、`backgroundedSessionNote` は
    **構造上まったく発火しない**。4 SUT は id・ラベルが共通契約なので木を見ても気付けない。
    ホスト側で最後の `ft_launch` を覚えるのが唯一の検知経路(詳細は docs/verification/)。
  - **繋いだブリッジの版を照合し、ズレは既定で拒否する**(`MCPServer+Driver.swift` の
    `enforceVersion` / `bridgeVersionSkew`。2026-08-06 導入・2026-08-09 に警告から拒否へ反転)。
    profile 無しの iOS 経路は `ExploreDriverResolver` が**生きているポートへ素で繋ぐ**だけで
    provision を通らないため、`bridgeProtocolVersion` を上げても旧ランナーが使われ続ける
    (実害: ランナー側の修正2件が `bridge down && bridge up` まで反映されなかった)。
    MCP の出力はシナリオへ書く文字列の供給源なので、古いブリッジの注記から誤ったセレクタが
    書き込まれるほうが「セッションが止まる」より高くつく("Refusing to operate…" を throw)。
    押し通すには `allowVersionSkew: true` で、その場合は**毎回の応答に警告が付き続ける**
    (1度言って黙らない)。版を返さない旧ブリッジ(nil)は判定できないので黙る。
  - **`ft_navigate back` は「画面が変わった」と断言しない**(2026-08-06)。iOS の back は端の swipe で、
    自前ナビの画面(`#btn_back` を持つ SwiftUI 等)では**1px も動かない**(E2E-iOS で2回とも不変)。
    アプリの外へ出ることもあるので、両方を注記に書く。
  - **モード切替の案内には「アプリが起動し直る」まで書く**(`iosModeHint` 末尾。2026-08-06。
    2026-08-08 に苦情を受けて1文へ圧縮したが、この事実は残した)。
    dylib は起動時にしか差し込めないので、in-app ブリッジの初回起動はアプリを再起動する。
    書かないと、案内に従った瞬間に探索中の画面が消え、**ホーム画面へ同じ座標のジェスチャが撃たれる**
    (実測: マップ画面での double tap がホームから `#nav_scroll` を開き `行 05` を選んだ)。
  - **スクロール容器は行に `scroll` を出し、2つ以上あるときだけ先頭で名指しする**
    (`ScrollFrameCandidates`。2026-08-06)。**id を持たない ScrollView/Table/CollectionView も
    版58から木に出る**(xcuitest の `isEligible` が容器型を id 必須から免除。in-app は
    版57で対応済み。id が無い容器は矩形で名指しされる)。当初 `ft_scroll_to` の `scrollFrame:` は
    セレクタ文字列しか取らないのに、一覧はどれが容器かを言っていなかった —— 引数説明が
    「複数あるときに渡せ」と言うだけで、**渡す値の探し方が無かった**。専用ツールを足さないのは、
    欲しくなるのが常に snapshot の直後(データは既に届いている)で、ツールは説明文が毎リクエストに乗るため。
    **`scrollFrame:` は ref(整数)も受ける**(2026-08-10。MCP 専用 — DSL の `scrollFrame:` は
    従来どおり文字列のみで、この決定に触れない): id が重複・欠落した容器はセレクタで一意に
    指せないため、`ft_snapshot`/`ft_scroll_to` が返した ref をそのまま渡せば `MCPServer.scrollTo`
    が既存の stale-ref 再照合(`resolveSessionRef` → `RefGuard.relocate`)を通したうえで frame を
    `FlowStep.scrollFrameRect` に入れる(`StepExecutor.scrollContainer` が locator より rect を
    優先し、rect は常に解決済み扱いなので scrollFrame の fail-fast には掛からない)。
    `ScrollFrameCandidates.note` は id が重複・欠落した候補を含む画面でだけこの逃げ道を一言添える。
    規律は `scrollFrameNote` と同じ **true を見つけたときだけ喋る** —— Compose/Flutter の in-app は
    申告できないので、そこで「容器なし」と言うと嘘になる。名指しは **id → ラベル(40字以内)**の順で、
    どちらも無ければ矩形を出して「書けない」ことを明示する(存在しないセレクタを勧めない)。
    1つだけの画面で黙るのは、iOS in-app では `scrollFrame` を渡すと XCUITest フォールバックを
    払うため(選択の余地が無い画面で勧める価値がない)。
    飛び越しの拾い直しの注記も**総称でなく実物の名前**を出す(`suggestedScrollFrame`。
    推測した容器に申告済みの容器が IoU 0.5 以上で重なるときだけ)。
    実画面での確認: 3 SUT(E2E-Android / E2E-CMP on Android / E2E-iOS)の 35 画面で
    印が出たのはスクロール画面3枚だけ・いずれも設計どおりの2容器(縦リスト+横カルーセル)で誤検知0。

    **印が出ない理由は2つあり、混同しない**(2026-08-06 に iOS 設定アプリで実地確認。
    ネイティブの `scrollView`/`table`/`collectionView` 自体は直前の版58/57の免除で
    identifier 無しでも残るようになったため、②は現在では主にブリッジがそもそもスクロール容器と
    認識しない相手(web ページの入れ子 `overflow-x` 等)で起きる):
    ①**ブリッジが申告できない**(Compose/Flutter の自前描画容器)/
    ②**容器がスナップショットに載っていない**。認識されない容器は `BridgeRouter.isEligible` の
    `default` 分岐、in-app は `.other` へ写るので、**identifier が空なら除外**される
    (Android も resource-id が無い容器は同じ)。**`scrollFrame:` は名前を要求するので、
    ②の容器はそもそも指定できない** = 印が無いことと書けないことが一致していて矛盾は無い。
    容器を型で指定できるようにする(`.scrollView` を書けるようにする)には**ブリッジのフィルタを
    緩める**しかなく、版上げ + `clippingContainer` の推測結果が変わるため 4 SUT の E2E が要る。
    価値は中程度(容器推測が既に大半を吸収している)なので**保留**
  - **`ft_status` は session と「いま前面か」を分けて出す**。session はブリッジが掴んでいるアプリで、
    `ft_navigate home` の後も変わらない。前面判定は XCUITest の `/appstate`(1往復)。
    iOS は**任意の前面 bundle ID を取れない**(`foregroundAppID` は nil を返す)ので、
    「session のアプリが前面か」だけを言う
  - **棚卸し・診断・スクリーンショットの3点**(2026-08-09。他ツールの MCP との比較で出た穴):
    `ft_list_devices` は実行プロファイルの `devices` から台帳を組む(`--profile` 指定時はその
    実行プロファイルの enabled な devices、無指定ならプロジェクト内**全実行プロファイルの和**
    ——`FTCore.MachineInventory`)。`/fleetest-mcp` の受け手のように runs/ に一つもデバイスを
    持たないプロジェクトもある。解決できなければ素のカタログ(`SimulatorCatalog` /
    `AndroidSerialResolver`)へ落ちるが、**落ちた理由を必ず本文に書く** —— 黙って代替すると、
    登録マシン名とプロファイル名の不一致(実在した)を受け手が永久に発見できない /
    `ft_logs` は**ブリッジを一切通らない**(要る場面はアプリが落ちてブリッジごと消えた直後)。
    iOS はホストの DiagnosticReports、Android は adb だけを見る。`udid` は入口で畳まず(畳み込みは
    ブリッジを走査する)、セッションの記憶と `.fleetest/bridge-<port>.device` だけで解決する ——
    実機と分かれば待たずにそう答え、シミュレータならそのデバイスのレポートに絞る。ここで踏んだ罠が2つ:
    **①クラッシュ直後はまだ .ips が無い**(ReportCrash の書き込みは非同期。見つからないときだけ
    数秒待って引き直す)/ **②既定の窓 300s には前の run のレポートが残っている**(実測で 11 分前の
    ものを掴んだ)ので**経過時間を必ず出す**。Android 側は `pidof` が空のときテキスト一致へ
    落とすと**クラッシュの原因行を捨てる**(`FATAL EXCEPTION` とスタックはパッケージ名を含まず、
    名指しで残るのは `Process:` の1行だけ)ため、crash バッファでは絞らず「絞れなかった」と明示する /
    `ft_screenshot` は既定で縮小 JPEG(`maxWidth` 600)。**費用は画素数で決まる**ので
    バイト数で形式を選ばない —— 平坦な UI では原寸 PNG のほうが JPEG より小さいことすらあり、
    バイト比較で選ぶと大きな画像を返してしまう。600 は実測(1179px の iPhone で CJK 本文も
    ステータスバーも読め、画素は 1/2.4)。密な画面は `maxWidth` / `fullSize` で逃がす
  - **`ft_batch` は StepExecutor に委ねる**(2026-08-10)。MCP の dispatch を順に回す案は採らない ——
    複数手の実行は探索ロジックなので、2つ目の実装を作らず StepExecutor へ渡す規律(`ft_scroll_to` と同じ)。
    委譲の主目的は**「バッチで通った = そのまま書けばシナリオでも通る」を成立させる**こと
    (下書きの検証に、ファイル作成と swift build を払って `ft_run_scenario` する以外の道が無かった)。
    **steps は DSL の手を並べた文字列1本・表記は最小記述の1つだけ**(2026-08-10 ユーザー決定):
    `"steps": "type '#f' 'abc'; scrollTo '#item' direction: .down"` —— 引数は引用符+
    空白区切り・手は `;`(改行も同義。どちらも引用符の中では区切らない。`BatchLineParser.splitSteps`)。
    MCP の arguments はオブジェクト必須なのでキー自体は消せない(`ft_batch { tap … }` のような
    素のブロックはプロトコル上表現できない)。ここへ至る経緯: 14キーのオブジェクト形 →「行そのもの」
    (`tap("#a")` の正形)→ 正形+緩い綴りの併存 → **併存をやめ最小形のみ**。廃止した表記
    (括弧・引数カンマ・配列 steps)は**書き換え方を添えて拒否**する —— 黙って受けると表記が
    再び分裂し、黙って落とすと1往復増える。**文字列の引用符だけは `'…'` と `"…"` の両方を等価に
    受ける**(同日の追決定 —— JSON の `\"` 経由で `"…"` が届くのは自然な書き方なので拒まない。
    案内する推奨は JSON エスケープの要らない `'…'`)。**限定文法のパーサ**(`BatchLineParser`。
    純粋関数・デバイスにも MCPServer の状態にも依存しない)が `name arg*` / `arg := [label ":"] value`
    / `value := string | number | bool | .ident` だけを解釈する —— 入れ子呼び出し・配列・演算子・
    クロージャは構文的に受け付けず明確なエラーにする。
    シナリオへの変換は draft が担う —— 記録は FlowStep からの再生成なので、正形
    (括弧+`"`)の DSL が出て「バッチで通った=シナリオでも通る」の契約は崩れない。
    バッチ文法が executor/codegen の全ステップを表せることは `testRoundTripThroughScenarioCodeGen`
    が守る(正形→最小形の機械変換を挟んで往復)。位置引数の名前は**シグネチャ文字列
    (`DSLCommandIndex.signature`)から導出する**(`BatchArgSpecTable`。名前の一覧をハードコード
    しない)。シグネチャが引数リストの形をしていない `swipe(.up / .down / .left / .right)` だけは
    小さな明示表(`positionalOverrides`)に載せ、辞書キー語彙が DSL 自身のパラメータ名と食い違う
    唯一の箇所(`swipeElementToElement(from, ...)` → バッチの辞書キーは他コマンドと同じ "selector")
    も同様に1件だけの表(`dictKeyAliases`)で吸収する。**未対応ラベルは黙って捨てない**——
    各ビルダに「実際に読むキー」を宣言させ(`BatchStepBuilder.keys`)、シグネチャには載っているのに
    ビルダが対応していないラベル(例: `tap` の `containerInference:`)は名指しで拒否し、シグネチャに
    すら無いラベルは別の文言(`ft_dsl_commands` へ誘導)で拒否する。
    **探索の `scroll:` / `maxSwipes:` は `tap` / `type` / `clearInput` / `select` が受ける**(2026-09-25。
    DSL の「スクロールの指定は `scroll:` だけ」に揃えた。バッチには `withScroll*` の文脈が無いので
    `.noScroll` は省略と同じ。`maxSwipes:` だけ・セレクタ無しの `scroll:` は効かないので拒否する)。
    `swipePointToPoint` も1手として受ける(DSL と同じ StepExecutor のアクション = 1:1 で書き戻せる)。
    書き戻し(`ScenarioCodeGen`)は操作系の `waitSeconds:` を**値があれば必ず**出す —— 検証系と違い
    省略時は 5 秒ではなく約 0.7 秒なので、5 を省くと別の意味に化ける
    **ref は1手目でだけ書ける**(2026-08-12。それ以前は全面禁止だった) —— 禁止の理由
    「ref はそれを撮ったスナップショットに対してだけ有効で、各手が木を変えるので後続の手の ref は
    黙って別の要素に当たる」は2手目以降にしか当てはまらない。**1手目はまだどの手も画面を
    変えていない**ので、ft_tap と同じ経路(`verifiedRef` = RefGuard の再照合。gone は拒否・
    ghost/移動は警告付きで続行)で解決してよい。実アプリでは重複 id・曖昧ラベルだらけで
    一意に書けるセレクタが存在しない要素が多く、全面禁止だと ft_batch がほとんど使えなかった
    (2026-08-12 の Apple マップ監査)。解決した ref は**そのまま書けるセレクタへ変換してから**
    実行する(`SelectorNaming.graded` = ft_tap の推奨セレクタと同じ実装)——
    変換できない要素は拒否する。「バッチで通った=そのまま書けばシナリオでも通る」は
    セレクタで表せることが前提で、ref はシナリオに書けないため。**何に解決したかは応答に出す**
    (出さないと読み手はシナリオ行を書けない)。記録(`InteractionLog`)も解決後のセレクタで残す。
    **2手目以降の ref は採用しない**(2026-08-16 ユーザー決定。**再提案しない**)——
    一意なセレクタが無い要素をバッチで叩く手段としては**座標タップのほうが筋が良い**。
    ref はシナリオに書けないので「バッチで通った=そのまま書けばシナリオでも通る」の契約から
    外れるが、`tap x: y:` は `ScenarioCodeGen` が 1:1 で書き出せる(2026-08-16 に解禁)。
    拒否文言も `tap` のときだけ座標形を逃げ道として案内する。
    2手目以降の ref は従来どおり拒否し、**文言で理由と書き換え方まで返す** ——
    「そんな引数は無い」で終えると渡し方を探してもう1往復する(2026-08-10 のデバイス確認)。
    通すのは operation/scroll カテゴリだけで、判定は `DSLCommandIndex` から導出する(名前を
    ハードコードしない)。ライフサイクル・破壊的なコマンドは弾く = 1回の承認でデータ消去へ届かせない。
    **検証は実行より前に全手へ通す**(途中で弾くと前半の手だけがデバイスに残る)。
    最初の失敗で止め、**木は最後に1回だけ**返す(毎手の木を積むとバッチにした意味が消える)。
    その最後の木だけは MCP の描画経路を通すので、遮蔽・ghost 等の MCP 固有の注記は付く
    - **「全部通ったのに画面が1ピクセルも変わっていない」を言う**(2026-08-12)。最後の木を
      `snapshotBody` へ直接渡していたため、操作系ツールの settle-lite(`snapshotAfterBody`)を
      通らず、**空振りしたバッチが無条件に成功と表示されていた**(実測: iOS Safari の横スクロール表で
      `swipeBy` が `ok` を返し、木は操作前とバイト一致。同じジェスチャを `ft_swipe` で撃つと
      ちゃんと警告が出る = ツールによって同じ空振りが見えたり見えなかったりしていた)。
      判定は `MCPServer.looksUnchanged` を再利用し(2つ目を書かない)、起点はループより前で
      捕まえる(`recordSnapshot` が上書きするため)。**断定はしない** —— 縁に着いていて
      正当に動かない回がある
    - **`scroll` は codegen が書き戻せなかった**(2026-08-12 に発見・修正)。`ft_batch` は
      `scrollDown/Up/Left/Right` を実行できる(カテゴリ `scroll` は許可済み)のに
      `ScenarioCodeGen` に `case "scroll"` が無く、`// (unsupported step: …)` に落ちていた ——
      **「通ったバッチは 1:1 でシナリオ行になる」という契約が破れていた**
  - **引数語彙は操作系の全ツールで揃える**(2026-08-10 の見直し): 長押しは `holdSeconds`
    (DSL の `tap(holdSeconds:)` と同語彙。旧 `duration` は黙って既定値へ落とさず改名を案内して拒否)、
    `snapshotAfter`/`waitFor`/`timeout`/`expandBulk`/`interactiveOnly` は操作系ツール
    (tap/type/drag/swipe/double_tap/press/pinch/navigate/**open_url**)全部に載せる(無いツールだけ
    毎回 ft_snapshot の1往復=承認1回を余計に払っていた。`ft_open_url` は 2026-08-12 に追加 ——
    URL を開くのは開いた先を見るためなので、往復が必ず1回増えていた。**1行目の文面は
    `snapshotAfter` の有無で出し分ける**: 木を返すのに「後で撮り直せ」と言うのは矛盾する)。
    集合は `MCPServerToolDefinitionsTests` が守る。
    **繰り返し載るプロパティ説明は短文に留め、ニュアンスは initialize の instructions へ1本化**
    (`MCPServer.serverInstructions`。プロパティ側に書くと全ツールへ複製され毎セッションの
    コンテキスト費用になる —— udid/allowVersionSkew の長文複製だけで約9k文字あった)
  - **ref の再ターゲットは「なぜ動いたか」の手掛かりまで返す**。原因は断定できないが、
    **同じ深さの兄弟が同じ分だけ動いたか**は手元の2枚から言える(揃っていれば容器のスクロール、
    その要素だけならレイアウト変化)。**画面全体で数えてはいけない** —— 固定ヘッダやタブが
    多数派になり、実測でスクロールを「動いていない」と誤答した(動かない 13 対 動いた 7)
  - **失敗と曖昧さの返し方**(2026-08-06 の外部フィードバック):
    `ft_status` は **Android で複数台のとき失敗させず全台を並べて返す**(読み取り専用なので
    「曖昧なまま操作させない」規律に触れない。操作系は従来どおりエラー)/
    `ft_scroll_to` の空振りは**止まった画面で引けるものの一覧**と「素のラベルは完全一致・
    部分一致は `*…*`」を添える(往復を省き、記法の誤りに気づかせる)/
    残像は**一覧の行そのもの**にも `⚠️scroll-leftover` を出す(先頭の注記だけでは、
    行から ref をコピーする動作に届かない)/ プロファイル解決の警告は
    **stderr に捨てず次の応答へ載せる**(MCP クライアントは stderr を見ないので、
    デバイス名の不一致が実行するまで表に出なかった)/ `ft_doctor` は FM 不可のとき
    **止まる機能と代わりの書き方**まで返す(`FMDoctor.unavailableImpact`)
  - **既にある逃げ道は、払った場所で名指しする**(2026-08-16 の外部評価。指摘4件のうち3件が
    「機能はあるのに応答が名乗っていない」形だった。実バグ0):
    **⑴ 待ちの上限**(`MCPServer.waitTimeoutRemedy`)—— 上限(当時は `timeout`、2026-09-25 から `waitSeconds`)は全ての待ちに 2026-08-10 から
    あるのに、**外れた回の文がどこにもそれを名指していなかった**ため「5秒固定」と読まれ、
    外れると分かっている待ちにも毎回満額を払わせていた(評価の1セッションで 10 秒)。
    3経路(ft_snapshot の waitFor / snapshotAfter の waitFor / waitForChange)に同じ1文を出す。
    **当たった回には出さない** —— 逃げ道は払った場所だけで言う。
    **⑵ 木の畳み方の継承**(`MCPServer.inheritingSnapshotFilters`)—— `snapshotAfter` は継承して
    名乗っていたが、**`ft_scroll_to` は継承そのものをしていなかった**(黙って全行を返す)。
    interactiveOnly を渡した後、**どのツールで読むかで出力量が変わる**のは、指定が効いていない
    ように見える。**木を返す口はすべてこの1関数を通す**(2つ目の継承規則を書かない)。
    2026-10-11 に**素の `ft_snapshot` と `ft_batch` も同じ継承**にした(ft_snapshot の省略を「記憶を消す」に
    していたため、「以後は黙って引き継ぐ」と宣言した直後の素の ft_snapshot が全行を返し宣言が嘘になった)。
    外すのは `interactiveOnly: false` の明示だけ。**宣言は値が変わったときに1回**(同じ値を明示し直しても言い直さない)。
    操作の応答(snapshotAfter・ft_scroll_to・ft_batch・ft_rotate)では曖昧ラベル・重複 id の表の**明細を畳む**
    (`snapshotBody(foldsSelectorTables:)`。事実 = ×N は残す)。操作の応答では**操作できる要素を含む群だけ**を並べる
    (`NoteCatalog.Input.actionResponse`。レイアウト容器だけの群は撃つ相手にならない)。満額は `ft_snapshot` だけ = セレクタを書くために読む口。
    **ベンチ(`Scripts/mcp-bench.sh`)での手数の確認は未実施**(計測4回続けて全エージェントが冗長と指摘した量の削減)。
    **初出だけ満額の注記(`once` / `onceNonEmpty`)の鍵はデバイス(sessionKey)ごと**(`MCPServer.noteScope`)——
    1つのサーバを2つのエージェントが別のデバイスで共有すると、2人目は初出を見ていないのに「初出の注記を見よ」と言われた。
    **ft_launch / ft_clear_app_data でそのデバイスの鍵を忘れる**(`resetOnceNotes`)—— サーバはプロセスの寿命で鍵を持つので、
    前の呼び手が初出を見ていると次の呼び手は最初の操作から短縮形を受け取った。表の定型フッター(「Tap these by ref…」)も初出だけ
    **重複ラベル・重複 id の表は、操作の応答では行の名前が直前に出した表に含まれていれば出さない**(`MCPServer.unlessCovered`。
    件数は比べない = スクロールで件数が変わっても「一意に指せない」事実は同じ)。`ft_snapshot` の満額は覚えない(直後の操作の応答にも ×N を残す)。
    **似たラベル**は、部分一致の候補が無いとき「no label contains it; short labels on screen: …」と言う(2文字の語は編集距離で
    何にでも当たるので「似ている」と言わない)。**通貨の表記の注記**は「この画面では」と限り、待ちの中では部分一致に数えない
    (止まった画面を上限まで待っていた)
    **⑶ シート展開救済の名乗り**(`MCPServer.sheetRescueMarker`)—— 散文は出ていたが、所要時間の
    内訳(`sheet-expand rescue +1.4s`)と語が違い、**1つの文字列では拾えなかった**。
    構造化フラグの要望だったが、**この応答の宛先はエージェントの本文1本**なので機械可読チャネルは
    増やさず、4形(記憶で省いた/伸びなかった/展開だけで出た/再試行した)の先頭の語を固定する。
    **⑷ `ft_type` の `replace: true` は仕様どおり素の type の約2倍**(実測 6.1s 対 2.3s)。
    内訳は clear の1往復と**打った結果の読み返し**(in-app iOS は clear/type の成否を検証せず
    YES を返すので、読み返さないと「replaced」が嘘になる)。`snapshotAfter`(かつ `pressEnter`
    無し)ならその1枚と共有するので、値段と避け方をスキーマに書いた
  - **「書けるセレクタが無い」を黙らない**(2026-08-07。実アプリの探索で出た4形):
    同じ id を複数の要素が持つとき行内に `×N`(`SnapshotRenderer`。生成側は一覧を読んで
    コードを書くのに、そのセレクタが曖昧だという信号がどこにも無かった)/
    **ラベルも id も無い clickable** の件数と ref(座標でしか指せないことを伝える。
    実測: 経路の移動手段タブがアイコンのみで、書ける手段が何も無かった)/
    3件以上が共有するラベル(素のラベルでは一意に指せない)/
    `ft_scroll_to` にも複数スクロール領域の注記(`scrollFrame:` を渡すべき当人に出ていなかった)
  - **`checked` は行に出す**(2026-08-07)。`disabled` は出すのに `checked` は一度も
    描画しておらず非対称だった。これが無いと、タブの選択状態は `checkIsON` では表明できるのに
    **MCP からは観測できない**。`true` のときだけ出す(印が無い = オフと状態を持たないの両方)
  - **別パッケージの木は、相手がシステム UI なら案内を変える**(2026-08-07)。
    許可ダイアログ(`permissioncontroller` 等)で従来の「`ft_launch` してから ref を信用しろ」を
    そのまま実行すると、**ダイアログを放置したままアプリを再起動してループする**。
    既知のシステム UI では「これを操作すれば元へ戻る」と言う(`MCPServer.systemDialogPackages`)
  - **`ft_type(ref:, pressEnter:)` はフォーカスが立つのを待ってから Enter を撃つ**
    (`MCPServer.awaitFocus`。2026-08-06)。直前に別の欄へ入力していると移動が間に合わず、
    Enter が**前の欄**へ飛んで黙って何も起きない(Android で観測)。
    **報告しないフレームワークで待ち続けない**のが要点 —— Compose iOS の a11y 要素は UIResponder では
    ないので in-app は `focused` を一度も返さない。「木の中に誰も `focused` を名乗らない」を
    報告しない経路と読んで即座に諦める。DSL の pressEnter も同じ待ちを持つ(定数は
    `FTCore.FocusWait` で共有。あちらはロケータが無いので「どこかの focused / keyboardShown」を合図にする)
  - この追従によって、**マップ系ジェスチャの MCP と実行の食い違いが消えた**(2026-08-04)。
    `profile` 付きなら iOS の Compose でもダブルタップが、Flutter でもピンチが効く。
    `profile` 無しは XCUITest 経路のままなのでこの2つが効かず、応答テキストに切り分けを添える
    (`MCPServer.iosModeHint`)。表と実測は docs/commands.md
- **XCUITest ランナーは「操作の失敗」でプロセスごと落ちる**(Xcode 27 beta のツールチェーン不具合。
  2026-07-28 にクラッシュレポートで確定)。XCUI の失敗は `_XCUIFailWithError` が issue を記録するが、
  ブリッジのハンドラは **main queue 上 = テストメソッドのスタックの外**で動く
  (`BridgeHTTPServer.dispatchToMain`)ため XCUITest が「現在のテスト」を特定できず
  `XCTFallbackIssueHandler` へ回り、そこから XCTest↔swift-testing 相互運用が**無限再帰**して
  スタックオーバーフロー(実測 950 段超)で SIGSEGV する。**`continueAfterFailure` も
  `FTCatchObjCException` も効かない**(issue がテストケースに届かない / ObjC 例外ではない)。
  ランナーが死ぬとブリッジが消え、**その run のワーカーが離脱**して振り直しになる。対処は2層:
  1. **ランナー**: 操作系(tap/type/pressEnter/swipe/drag/press)は `requireLiveApp()` で
     `app.state` を確認し、起動していなければ XCUI に触れず **503** を返す
     (409 はセッション消失専用・501/404 はフォールバック判定に使用済みのため空いている 503)。
     snapshot/screenshot には入れない(`state` は IPC で毎回コスト・取得系は issue を出さない)
  2. **ランナーのテストは XCUI の失敗を記録しない**(`FleetestBridgeTests.record(_:)` がログにだけ残す。v119)。
     今の版では失敗はテストケースへ届くが、**記録すると1件でも Tear Down してランナーが消える**
     (2026-09-19: 入力の途中で WebView の中身を止め、消えた欄への typeText 1件で消えた。毎回再現 →
     上書き後は同じ手順5回で生存・失敗はログに12件)。操作の失敗は各ハンドラが HTTP のエラーで返す。
     消去(/clear)は欄に触る直前に `exists` で在るかを確かめ、消えていれば 422(`requirePresent`)
  3. **ホスト**: `AppAttachDriver` が ref 無し操作の前に `ensureAttached()` で
     **セッションを自分の bundleID へ揃える**(1インスタンス=1シナリオにつき1回)。
     XCUITest ブリッジは run 内で使い回されるため、セッションが**前のプロジェクトのアプリ**を
     指したまま来ることがある(実測: E2E-iOS の次に回った E2E-Flutter の `scrollTo` が
     `com.ftester.e2e.ios` を掴み、それが未起動で上記クラッシュに至った)。
     409/503 は「attach し直せば通る」として activate+1回再試行

  効果(`--ios --ios-inapp` フル構成): 離脱がベースライン 2回中2件 → **2回中0件**。
  追加の activate は1シナリオ1回・ジェスチャを XCUITest へ回すときだけなので、
  **run 時間に有意差なし**(3 SUT の合計で ±1s 以内・2026-07-28 実測)。
  なお**トリガは他にもあり得る**(要素が hittable でない等の XCUI 失敗)。恒久対策は
  ランナーから swift-testing を外せるかの調査が要る(未着手)
- **XCUITest のセッション消失は snapshot 境界でだけ自動回復する**(`SessionRecoveryDriver`)。
  ランナー再起動で `BridgeRouter.requireApp()` が 409 を返すと以前は全操作が落ちていた。
  この経路の 409 はセッション消失専用(409 を投げる箇所が1つしかない)なので状態コードだけで判定でき、
  `activate`(**`launch` ではない**。launch はアプリを再起動してナビ状態を飛ばす)で張り直す。
  **ref を使う操作(tap/type/press の ref 指定)は再試行しない**: セッション確立は `refFrames` を
  クリアするため、同じ ref での再試行は別要素を操作しかねない。セッションだけ張り直して 409 を返し、
  次のステップの snapshot で ref が振り直されて復帰する(StepExecutor は各アクションの前に必ず
  snapshot するので、実際の損失は最大1ステップ)。ref を使わない操作(snapshot/screenshot/swipe/
  座標指定 tap/press/drag/home/appSwitcher)だけ 1 回再試行する。
  inapp モードの経路には入れない(InAppDriver の 409 は意味が違う)
- **`.型[n]` の n は「現在画面に見えている同型要素のツリー順」**。圧縮スナップショットは画面外要素を
  含まないため、序数は**スクロール位置と画面クロム(戻るボタン・下部タブ)に依存する**。
  レイアウト変更で黙ってずれるので、序数セレクタは実スナップショットで採取してから書く
- **型は「役割」に正規化する**(2026-07-26)。ブリッジが返す型はネイティブのクラス名ではなく役割で、
  **OS を跨いで保証されるのは `button` / `staticText` / `textField` / `secureTextField` / `switch` の5つ**。
  Android 側の正規化規則は 3 つ(`SnapshotBuilder`):
  ① clickable なノードが**同一 bounds の無名 `android.widget.Button` 子**を持てば `button`
     (Compose は Role.Button をこの形でしか出さない。testTag が付く当のノードは `android.view.View`)
  ② `checkable` な汎用ノードは `switch`(Compose の Role.Switch は legacy className を持たない)
  ③ 葉 + contentDesc のみの汎用ノードは `staticText`(Flutter は canvas 描画でテキストも
     `android.view.View`。これが無いと **id を振っていないテキストが丸ごと落ち**、ラベルを
     アンカーにした方向セレクタが使えない)
- **`checkBox` / `slider` / リスト行は揃えられない**(iOS 側が役割を出さない: Compose の Checkbox/Radio は
  iOS で `button`、Slider は `other`。2026-07-26 に同一アプリ・同一画面で実測)。**型で指さず `#id` を使う**。
  これは「情報が無い側に合わせるしかない」ケースで、ブリッジ実装では解消できない
- **Android は「別ウィンドウ」に描画される UI(`AlertDialog` 等)にテスト用 id が出ない**
  (2026-07-22 実測)。`testTagsAsResourceId` はルートに1回付ければ子孫全体に効くが、ダイアログは
  ルートの子孫ではないため効かず、**ダイアログ内だけ `#id` が全滅する**(ラベルは引ける)。
  アプリ側でダイアログにも `Modifier.semantics { testTagsAsResourceId = true }` を再適用させる。
  iOS は testTag が自動で accessibilityIdentifier になるため起きない(Android 固有)
- **テキストの可視性検証の run(実行プロファイル `fmTextVisibilityCheck` / `ocrTextVisibilityCheck` のどちらか。**既定はどちらも true**)では、
  `exist`/`textIs` は既定 `requireVisible: true` のため、ソフトキーボードに覆われた要素は
  「`text visibility check failed (on screen)`」で失敗する**。入力を伴う画面では検証対象・操作対象を入力欄より**上**に置く
  (TestProjects/E2E-CMP のテキスト入力画面がこの配置。2026-07-22 実測)
- **in-app ブリッジは注入先アプリのプロセス内常駐**なので、アプリがクラッシュ/終了すると HTTP が
  `DriverError.bridgeConnectionRefused`(「Could not connect」)になる。xcuitest/Android はブリッジが
  別プロセスのためこの切断は起きない(inapp 固有)。切断時は `InAppDriver` がホストの
  `~/Library/Logs/DiagnosticReports` から対象 bundleID の直近 `.ips` を探し、レポートのエラー行に
  クラッシュレポートのパスと終了理由を1行で添付する(`SimulatorCrashReport`。JSON 形式優先・旧テキスト
  形式もフォールバック解析)。`.ips` が**見つからない**ときは「OS 終了/メモリ圧/自発終了・混在実行の
  suspend の可能性」を切り分け文言として添える(クラッシュ以外の切断と区別する)

---
