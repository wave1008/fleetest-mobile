# 検証: 切り分け(全滅・誤った赤・画面が変わらない)

| 種別 | 範囲 | 読む場面 | 扱わないこと |
|---|---|---|---|
| 手順 | 症状から原因を切り分ける手順 | テストが全滅したとき・成功しているのに失敗と報告されたとき・操作が効かないとき | 個々の制約の詳細(→ [constraints.md](constraints.md)) |

症状から引く。各節は「何を見るか」から始まる。

## 既知の間欠失敗(2026-08-13 時点)

**単発の失敗を「退行」と読む前にここを見る。** どれも**実装の退行ではない**と反復で確かめてある。

| シナリオ | 頻度 | 症状 | 判定 |
|---|---|---|---|
| `E2E-iOS / フリックが正しく動くこと.S0010` | 並列負荷時 1/3 程度 | `flickRightToLeft(the screen did not settle)` → `scrollLeft ×3` → `#tag_01` not found。横カルーセルが戻り切らない | 既知。単独実行では 5/5 成功 |
| `E2E-RN / 待機とタイムアウトが正しく効くこと.S0010` | **1/10**(2026-08-13 に実測) | `#btn_delay_1` タップ後の `exist "#txt_delayed"` が 5s で落ちる | **flake**。同じ周の別シーンでは同じ操作が成功しており決定的ではない |

| `E2E-CMP / テキスト入力が正しくechoされること.S0040`(android) | **2/7**(08-12)+ 1/4(08-13) | step 5 の `type (replace)` が `clearInput reported success but the value remained: "単一行"` で落ちる。同じログに `Another window is in front of the app: InputMethod` | **既知の Android テキスト注入の間欠失敗**。**ただしメッセージは原因を取り違えている**(下記) |
| `E2E-CMP / 否定と個数と方向セレクタが正しく動くこと.S0010` | 凍結機が居る間だけ 4/5 | `#btn_delay_1` タップ後の `exist "#txt_delayed"` が 5s で落ちる。同じログに `-01 dropped out because of a frozen screen` | **凍結機**。下の「退行に見えた」を読むこと |

**「クリアが失敗した」と読める文言が、実際には「直前の入力が届かなかった」を指すことがある**
(2026-08-13)。上の CMP/android の1件がそれ —— `clearInput reported success but the value
remained: "単一行"` と出るが、**「単一行」はこの欄のヒント文字列**であって残留した入力ではない。
step 4 の `type "abc"` が IME に飲まれて届かず、欄が**空のまま**(= `value` にヒントが見えている)
だったので、`clearInput` は空の欄に対して正しく何もしていない。
`residualClearValue` は `before != placeholder` で守っているが、**Android の CMP は
`placeholder` を送らない**ので素通りする。**この文言を見たら、まず直前の入力が届いたかを疑う**。
**空の欄の `value` にヒント・ラベルが見えていた実体はブリッジのテキスト昇格**(2026-10-01)——
名前の無いクリック可能な入れ物に子孫の文字を写す処理が入力欄にも効き、子のヒント/ラベルの TextView を
値として写していた(生の a11y では `text=''`)。Android ブリッジ v85 で入力欄を対象外にしたので、空の欄は
空と読まれる。**この型の間欠失敗は以後、clearInput ではなく後の検証(echo の `textIs` 等)で落ちる**
(同日の E2E で S0020 が `clearInput` 緑・`textIs "password="` 赤の形で1回出た。修正あり・HEAD とも
6台×3周で 0/18 = 帰属は決まらず)。

**「A では落ちて B では通る」を、順序を反転せずに退行と読まない**(2026-08-13)。上の CMP の1本は
変更後のツリーで 4/5 落ち、HEAD のツリーでは 4/4 通ったので**退行に見えた**。
**順序を反転したら HEAD のほうが同じ形で落ちた** —— 先に走ったほうが凍結機
(`-01`)を引き、**その run が凍結を記録するので後続はその機を避けて通る**。
交互に回すと**先攻が負ける**だけの構図で、コードは無関係だった。
**A/B の前に、A と B を入れ替えた対照を取る**(片方向だけの比較は、共有資源の状態を
「変更の効果」として読む)。

**RN の iOS in-app は全ステップが `activate 不発 → 合成タッチ` に退化する**(ログに毎回出る)。
合成タッチはタイミングに弱く、上の flake の温床と見られる。**落ちる位置は毎回同じではない**
(フル実行ではステップ7・反復ではステップ14)ので、**「特定のステップが壊れている」と読まない**。

## ブリッジの「誤った赤」を疑う手順(成功しているのに失敗と報告される)

**症状**: ステップは失敗するのに、直後にスナップショットを撮ると**期待どおりの状態になっている**。
2026-07-31 の Android WebView `type` がこれで、原因は a11y ノードのキャッシュを取り直さずに
読んでいたこと(値は入っていたが読みが古い)。同型は「キャッシュ・遅延イベント・整定の打ち切り」の
どれかを疑う。

1. **まずホスト側から状態を撮る**。失敗した直後に `/snapshot` を撃ち、期待値になっていれば
   誤った赤が確定する(「入っていない」のか「読めていない」のかはここで分かれる)
2. **シナリオ経由で追わない**。1 run に1回しか通らない操作は再現率が低すぎる
   (実測 111 run で 2 件 = 1.8%)。**ブリッジを直接叩くハーネス**をホストと同じ手順
   (snapshot → ref 解決 → 操作)で書き、全デバイス並列で数十回まわすと同じ事象が
   **20%** まで上がった。負荷は合成 CPU 負荷では足りず、別スイートの並走が要る
3. **ブリッジ側に一時診断を足す**(期限切れの瞬間に何が見えていたか: ノードの有無・text・
   focused・bounds・候補の全列挙)。**版を上げないと旧ブリッジが再利用されて意味がない**
4. 直したら**同じ負荷・同じ回数**で前後比較する(修正前の実測が無いと「効いた」と言えない)

**失敗レポートだけで誤った赤を確定できることがある**(2026-08-01・Android ネイティブ画面)。
レポートは**要素一覧(a11y)とスクリーンショット(ピクセル取得なので a11y を通らない)を両方**
載せるので、**この2つが食い違っていたら読みが古い**と即断できる(再現を待たなくてよい)。
さらに強い判定材料は**要素一覧の内部矛盾**: 同じアプリ state から描かれる2要素(例 echo と
入力欄の値)が同一フレームでは両立しない組み合わせで出ていたら、ツリーはキャッシュ混じり。
「タップが落ちた」仮説とはここで切り分けられる —— タップが落ちただけなら他の要素は新しいままのはず。

**この失敗クラスは WebView 限定ではない**: IME 等が前面にあるとネイティブ画面でも数秒古いツリーが
返る。逆向き(遷移前の状態を期待するアサーションが**誤って成功する**)は沈黙するので、
`notExist` や「クリア後の初期値」を見るステップが怪しく緑になっていないか疑うこと。

**全ノード refresh は既定にできない**(2026-08-01 実測)。`SnapshotBuilder.collect` で
`node.refresh()` を全ノードに広げると **snapshot 1回あたり +65ms**(アサーション中央値
6〜22ms → 43〜99ms)、scenario sum は **E2E-Android +43%**(208.3→297.3s)・E2E(Compose)+2.5%。
ノード数の多い View/XML SUT ほど重い。既定は WebView 内だけに留め、**ホストが期限切れで失敗と
決める直前の1回だけ** `/snapshot?refresh=1` を要求する。

## 操作は ✅ なのに画面が変わらないとき

`tap` がエラーにならず成功として記録され、次の検証だけが「期待と違う」で落ちる形。
**ロケータの問題ではない**ので、セレクタを直そうとすると時間を溶かす。

**まず3つのクラスに分ける**(2026-08-05 に過去の失敗レポート 487 件を全数分類して整理した。
機構が違うので混ぜると追えない):

| クラス | 見分け方 | 状態 |
|---|---|---|
| **A. 座標が可視領域の外**(報告された frame が壊れている) | 失敗時の要素一覧で、対象の frame が容器の縁をまたぐ/外に居る。E2E-CMP S0110 の失敗 21 件中 **11 件**がこれ(`#row_30` が `y=206 h=26〜45`・容器の上端は 230 = **中心が容器の外**) | 機構は確定。**未対処**(下記「画面外要素の frame は信用できない」) |
| **B. ghost(容器の外に並ぶ子)** | ステップに `the element is still reported outside its scroll container` の注記が付く | 対策済み(再解決+追加スワイプ)。取りこぼしが 21 件中 2 件 |
| **C. 座標も正しく、イベントも受理され、アプリが反応しない** | A でも B でもない。注記も付かない | **真の未解明**。ただし混入していた環境要因が1つ判明(下記) |

**C を追う前に環境を疑うこと**(2026-08-05 の教訓): C だと思っていた失敗のうち、
**iOS シミュレータの画面凍結**(下記の節。真っ黒なのに a11y は健全でタップだけ届かない)が
混ざっていた。今は失敗レポートに blank frame 警告が出るので、まずそこを見る。

既知の原因は次のとおり。

1. **アプリが別プロセスの window に覆われている**(システムダイアログ・IME の案内・通知シェード)。
   アプリの a11y ツリーには他プロセスの window が出ないため、要素一覧は正常に見える。
   **2026-07-27 以降は失敗時に自動で警告が出る**(コンソールとレポート。
   `⚠️ アプリより手前に別の window があります: …`)。出ていたらこれが第一の容疑
2. **アプリ内メッセージ**(お知らせ・キャンペーンのモーダル)。**同一プロセスなので 1 の検出では
   捕まらない**。こちらは失敗メッセージに `(対象は #… に覆われています)` が付く(幾何判定・FM 不要)。
   繰り返し出るなら `irregularHandler` を宣言して自動で閉じさせる(../design/dsl-execution.md「割り込みハンドラ」)
3. **スクロール探索の直後**(下記の節)。こちらは修正済みだが、同じ症状の別原因として覚えておく
4. **座標が要素の外**(下記「画面外要素の frame は信用できない」)。報告された frame の中心が
   実際の可視領域の外にあり、タップが隙間や別の要素へ落ちる

**2026-08-05 以降は「飲まれたタップ」を失敗文言が名指しする**: 直前のタップの**直前に解決で
使った木**を覚えておき、失敗した検証が手元に持っている木と突き合わせて、**1ピクセルも変わって
いなければ** `(the preceding tap … did not change the screen at all; the interaction may have
been swallowed)` を添える(`StepExecutor.tapDiagnosisHint`)。
- **iOS では「別プロセスのアラートを出した」可能性も併記する**(`, or it raised a system alert …`)。
  iOS の木は in-app / XCUITest ともアプリのプロセスだけなので、権限の要求など SpringBoard の
  アラートを出したタップも「無変化」に見える(M1mini の E2E-iOS 16 S0010 で、アラートが待ちの
  5 秒に間に合わなかった赤を「飲まれた」と誤誘導した)。Android は権限ダイアログが木に載るので添えない
- **追加のスナップショットは撮らない**。実行中に I/O を足すと事象そのものが消える
  (下記「Compose の探索直後タップ」の heisenbug で 13 周回して再現しなかった)ため、
  これは設計要件であって最適化ではない
- **判定は変えない**(注記だけ)。「押しても画面が変わらないのが正しい」操作もあるため
- 署名には**ラベル・値・enabled・checked も入れる**。飲まれたタップの実例は
  `selected=-` のままか `selected=row_30` になるかの違いで、**座標は1ミリも動かない** ——
  `settledSignature` の署名(frame だけ)を流用すると黙って取りこぼす。逆にラベルの振れ
  (iOS の再利用セル)は「変わった」側に倒れるので、**誤って「無変化」と言うことはない**
- 記録は `select` では消さない(`tap → select → textIs` が失敗の定型)。画面を変える他の操作で消える
- **タップ点を手前の別要素が取っていた**ときは、無変化と同時に成立したときだけ名前も添える。
  単独で出さないのは、画面外要素の frame がクランプされるフレームワーク(下記)では
  **正常なタップでも普通に非 nil になる**ため
- **木が変わっていて、かつ対象があの後動いていたら移動量を出す**(2026-08-05 追加)。
  `(the target has moved (0,-100) since the preceding tap …)`。これが
  **「座標が古くなった」と「本当に無反応だった」を分ける唯一の材料** ——
  失敗時の幾何だけでは両者が同じ絵になり、実際に取り違えた(「掴んだ時点で壊れていた」と読んで
  探索側を直したが、10周回して**一度も発火しなかった**)。閾値は 8pt(整定の揺れで出さない床。
  実測の取りこぼしは 98pt 級)。対象が消えていたら黙る

実例: Gboard の「タッチペンを試してみる」が送信ボタンを覆い、03_テキスト入力(旧 05)が間欠失敗した
(抑止は `AndroidBridge.disableStylusHandwriting`)。**この手の教育用ポップアップは今後も増える**ので、
1 の警告が出たら SUT ではなくデバイス設定側を疑う。

**切り分けの定石(iOS)**: 同じシナリオを `ios-inapp` プロファイルでも回す。in-app は ref で、
xcuitest は座標でタップするので、**片方だけ落ちるならタップ経路の問題**、両方落ちるならアプリ側か
セレクタの問題と切り分けられる(スクロール直後のタップの機序特定で決め手になった)。

## FM(Foundation Models)が全滅したら

screenLooksLike は FM 失敗時に nil を返して**素通りする**(呼び出し側が握りつぶす。
自己修復は 2026-09-15 に FM を呼ばなくなったため対象外 → MN-22)。
occlusion-guard は **OCR の読み(読めなければインク量)だけで判定する**(`OCROnlyVisibility`)——
空白・全面の覆い・別の文字は赤にできるが、**OCR が判定できない形(読めない × インクが多い = 図形・
WebView・一部だけ残った文字)は素通り**で、`ocrTextVisibilityCheck` が off なら読みが無いので全部素通り。
実測(OCR が判定不能にした見えない標本 72 件は FM なら全部赤)は OG-5.19。
run 終了時の「FM 呼び出しが全て失敗しました」警告と結果 JSON の `fm` フィールド、それに
ステップ単位の `notes: ["visibility-guard-skipped"]`(occlusion-guard だけ)が手がかり。

- **切り分けの起点は `fleetest doctor`**。availability は「端末が対応しているか」しか見ておらず、
  資産側の理由で全滅していても `available` を返すので、**実呼び出し(checkLive)の結果で判断する**
- **FM 依存の変更は「FM を呼ぶシナリオ」で検証する**。まず前提として、テキストの可視性検証
  (occlusion-guard)は**実行プロファイル既定 ON**(切るなら `fmTextVisibilityCheck` と `ocrTextVisibilityCheck` を両方 `false`)だが、
  `OcclusionSuspicion` が疑いを立てたときだけ発火するので、シナリオを選ばないと `fm: null` で
  **空振りする**(実害: セレクタ画面・テキスト入力のシナリオで2回続けて空振りし、検証したつもりになった)。
  実測で FM 呼び出しが最も多いのは `ジェスチャが正しく検出されること`。
  確認は結果 JSON の `fm` フィールドで行う(警告が出ない = 成功、ではない。**呼ばれていない**かもしれない)
- **実行時の FM 経路は `FMHealth.record` を必ず呼ぶ**(occlusion / screenLooksLike。**自己修復は
  2026-09-15 に FM を呼ばなくなり、FM トリアージは同日撤去** → MN-22・MN-21)。記録は
  `fm` フィールドと `FMBreaker` の両方を養うので、欠けると①`fm` に出ず「呼ばれていない」と誤読され
  ②失敗がブレーカを進めず、死んだホストで時間を捨て続ける。実害(当時): **triage が記録を欠いていた**
  (2026-07-30 修正。`fm.calls` に一切現れず、動作確認はレポートの「トリアージ」節でしか取れなかった)。
  監査は `FMAccountingAuditTests`(**関数単位**。ファイル単位だと同一ファイルの複数機能に
  一致して欠落を見逃す。判定前にコメントを落とすのも必須 —
  記録の必要性を説明したコメント自身に一致して一度素通りした)。
  作成時の経路(FMDoctor / TestbaseDrafter)は run の実績ではないので免除リスト

### Vision(画像特徴量)まで死ぬことがある —— 画像に依存する E2E は判定に使えない(2026-09-19)

同じ機械状態(ANE の破綻)で、FM だけでなく Vision の `GenerateImageFeaturePrintRequest` も死ぬ。経過は2相:
①**異なる画像に同一の特徴量が返る縮退**(全候補が距離 0.000。Vision の失敗としては記録されない)→
②要求が 30 秒後に `Building espresso plan [espresso error: -1]` で落ちる(ホストの単体テストも同じ)。
①は `FindImage.isDegenerate`(白紙との距離 0)が失敗にする。①ほど極端でない異常(普段 0.002 前後で見つかる見本が
0.33〜0.43 で「見つからない」になった。2026-09-19 負荷テスト)は `FindImage.isConsistent`(同じ見本を取り直して
控えと一致するか。健全なら 4 機 1,200 回とも距離 0)が失敗にする。**この間、findImage / imageIs / checkIsON の
分類器の E2E(各 SUT の 08・20・21)は赤でも緑でも判定に使えない**。切り分けは
`swift test --filter FindImageTests`(ホストで特徴量を実際に作る。0.5 秒で終わるはずが 30 秒かかって落ちる)。
**見本の採取(`fleetest vision capture`)とブリッジの鮮度の確認は Vision を使わないので、この間も進められる**。
復旧は再起動(ブートごとの当たり外れ)。経緯は MN-37。

### FM が全滅している間の E2E は「弱い緑」(2026-08-03)

FM(オンデバイスモデル)が死んでいると、**occlusion-guard(`exist` の既定 `requireVisible`)・
`screenLooksLike` が実質無効のまま緑になる**(失敗は飲み込まれて pass 扱い。自己修復は FM を
呼ばないため対象外)。
run のログに `Every FM call failed` が出ていたら、その run は**誤った緑(覆われているのに exist が
通る)を検出できていない**と読むこと。`fleetest doctor` の「On-device model」で確認できる。

根本原因は Apple 側(`modelmanagerd` が安全性モデルを ANE にロードできない。FB 報告済み)で、
availability は available と嘘をつく。**`SystemLanguageModel(guardrails:
.permissiveContentTransformations)` で回避できないことは 2026-08-03 に確定**した
(全滅中のプローブが `tvp` = permissive も同じエラーで落ちる)。
監視は `Scripts/fm-flap-monitor.swift`(再開手順はスクリプト冒頭)。

### FM 経路の検証は `Scripts/fm-verify.sh`(2026-07-30。2026-09-15 に screenLooksLike/occlusion のみへ縮小)

上記の空振り要因(既定 OFF・失敗しないと呼ばれない・既定スイートに無い)を
まとめて潰す。**FM 専用シナリオを一時的に有効化 → FM 全 ON の `ios-fm` プロファイルで実行 →
結果 JSON の `fm.byKind` に必要な種類が出たかを判定**する(1コマンド)。

```
Scripts/fm-verify.sh                    # 既定 TestProjects/E2E-CMP・プロファイル ios-fm
```

**既定では回さない**。見ているソース(`negative-controls.json` の `watches."fm-verify"`)が前回 ✅ から変わったら
`e2e.sh` の終わりで推奨する。回すのはユーザーの指示があるとき(§陽性対照スイート)。

- FM 専用シナリオは `TestProjects/E2E-CMP/scenarios/_disabled/` に置く(`92_screenLooksLike` =
  screenLooksLike)。**既定スイートに入れない**: 生きた FM の判定は非決定的でフレーク源になり、
  かつ FM が死んでいる間は skip されるので緑のまま気付けない。**自己修復(FM 版)の witness
  だった `90_自己修復` と、FM トリアージの陽性対照だった `93_存在しない要素` は
  2026-09-15 に両機能ごと撤去した**(→ MN-22・MN-21)
- スクリプトは `trap` で必ず `_disabled/` へ戻し、退避した指紋の控え(`locator-fingerprints.json`)
  も復元する(出したままだと既定スイートを汚す)
- **`screenLooksLike` の欠落は失敗扱い。`occlusion` は疑いが立った時だけ発火する**ので
  警告に留める(呼ばれないことと FM の死を区別できない)。`fm.byKind` に必要な種類はこの2つだけ
- 実測(2026-07-30・再起動直後。当時は heal/triage も計測していたが両方撤去済み):
  occlusion 13 / screenLooksLike 2 呼び出し・失敗 0。
  **occlusion は `ジェスチャが正しく検出されること` が大半**(docs の「最も呼ばれる」の裏取り)
- **occlusion の「FM に訊いて反転する」経路は、自前 SUT では踏めない**(2026-09-03 に実機で確認)。
  試した2形はどちらも **FM を1回も呼ばずに緑**になった(結果 JSON の `fm` が null):
  ① `E2EAppIOS` の別ウィンドウ全画面モーダル配下の背面要素 —— 覆いは
  `Color.black.opacity(0.55)` の**減光**で、規則どおり「判読できる減光は visible=true」。
  しかも減光越しに文字が見えるので Tier-1 のインク量も高く、**FM の手前で素通り**する。
  カードが不透明に覆っているのはラベルを持たない `#sw_auto_dialog` だけで、足切りに掛かる /
  ② タブバーに潜る `#btn_under_footer` —— 帯にはタブのラベル(インク)があり、
  iOS の木は z を持たないので幾何の疑いも立たない。
  **要るのは「テキストを、文字の無い不透明な面で覆う」画面**で、2026-09-03 に
  `E2EAppIOS` の覆い画面へ足した(`#btn_toggle_paint` / `#txt_paint_target`)。
  **対象がテキストであることも必須** —— `OcclusionEligibility` はテキスト型だけを FM に回すので、
  Button 版では guard が 6ms で素通りし FM 呼び出しは 0 だった(これも実測)。
  陽性対照は `TestProjects/E2E-iOS/scenarios/_disabled/96_遮蔽の反転.swift`
  (`fmTextVisibilityCheck: true` のプロファイルで回す。**S0010 は落ちるのが正常**)。
  実測では失敗文言に reason と crop が付き、`fm.byKind.occlusion.calls` が**2**(等倍の転写 +
  2 倍の読み直し)になることまで確認した。**FM 段の形を触るときは、この対照とコーパスの両方で照合すること**
  (OG-5.18)
- **occlusion-guard は長期間 死んだままでも E2E は緑になる**。実績値では
  6066 呼び出し中 5673 失敗(**93.5%**)で、成功を含む run は 582 中 58 だけだった。
  つまり**「緑」は基本的にツリー一致の緑**で、可視性検証を含むとは限らない
- **エラーは入れ子。最上位だけ見ても何も分からない**。`LanguageModelError(-1)` は常に
  「The operation couldn't be completed.」で、真因は `NSMultipleUnderlyingErrors` の奥にある。
  `FMHealth.describe` が `←` 区切りで畳んで出すので、そちらを読む
- **2026-07-27 に観測した全滅の連鎖**(M2 Ultra / macOS 27 beta):

  ```
  FoundationModels.LanguageModelError(-1)
   ← com.apple.SensitiveContentAnalysisML(15)          sanitizeText 失敗
   ← CombinedTextSanitizerBackend.BackendError(1)
   ← ModelManagerServices.ModelManagerError(1001)      安全ガードレールのモデルがロードできない
  ```

  落ちているのは**本体の LLM ではなく安全ガードレール**(`com.apple.fm.language.instruct_300m.safety`)。
  ガードレールは**テキストのみの呼び出しでも必ず通る**ので、これが死ぬと画像添付の有無に関係なく
  **FM 機能が全滅**する。アセット記述子はディスク上に存在しており、欠落ではなくロード失敗
- **飽和(スループット不足)とは別物**。飽和なら成功が混じるが、この事象は**失敗率 100%** になる。
  結果 JSON の `fm.failures / fm.calls` で必ず区別すること
- **並列 run 中に発生しやすい**。modelmanagerd が `unloadIfNeededToMakeRoom` で
  安全モデルを積み降ろしし続けた直後に落ちた(実測: 14 ワーカーが一斉に occlusion-guard を叩いた
  E2E の途中で成功→全滅に転じ、以後プロセスを変えても回復しない)。ホスト RAM の枯渇ではない
  (192GB 中 57GB 空き)。**FM はホスト全体で共有される資源で許可枠に制限される**
  (PT-3.5)ので、枠を超えて並列に投げてもスループットは伸びず、
  この積み降ろしだけが増える
- **回復手段は現時点で「マシン再起動」しか確認できていない**(再起動直後は成功する。
  ただし数分〜十数分の並列実行で再発する)。`GenerativeExperiencesSafetyInferenceProvider` は
  root 権限のため一般ユーザーでは kill できない。ログでの確認:

  ```
  /usr/bin/log show --last 15m --style compact \
    --predicate 'eventMessage CONTAINS[c] "End sanitizeText"'
  ```

  (`log` は shell 関数に食われることがあるので**絶対パスで叩く**。自分の述語文字列が
  `log` プロセス自身のログに出て**偽の成功行**に見えるので、プロセス名まで確認すること)

### 自己修復(指紋照合)の検証は `Scripts/heal-verify.sh`(2026-09-15)

指紋照合は**失敗経路でしか動かない**ので、緑の run では1度も実行されない = フル E2E を何度回しても
守られない。そこで witness(`TestProjects/E2E-CMP/scenarios/_disabled/94_指紋照合.swift`)と
前提を切り替える補助(`95_指紋照合の前提切替.swift`)を一時的に有効化し、**同じデバイス**で順に回して判定する
(1コマンド。既定は `ios-heal` プロファイルの先頭のデバイス):

```
Scripts/heal-verify.sh                  # 既定 TestProjects/E2E-CMP・プロファイル ios-heal
Scripts/heal-verify.sh --profile android-heal
```

| 段 | 期待 |
|---|---|
| schema=v1 → 94 | 緑・修復なし(プライマリで解決して**指紋を採る**) |
| schema=v2 → 94 を2周 | 2周とも緑・`heal-fingerprint-match`・修正提案 `#btn_heal_v1` → `#btn_heal_v2`・FM 0 回 |
| `--set heal=false` → 94 | 赤(`cannot resolve the locator: id=btn_heal_v1`)・指紋を使わない |
| schema=v1 へ戻す | 緑(途中で落ちても trap で戻す) |

- **2周目が要る**: 1周だけだと「指紋で直った行の鍵が、その run の終わりに刈られて3周目に赤へ戻る」
  不具合(2026-09-15 に直した。`LocatorFingerprintCache` の失効)を踏まない
- **全段を `--device` で1台に固定**する(schema はデバイスごとのアプリデータ・指紋はホスト側のファイル)
- 指紋の控え(`<project>/.fleetest/locator-fingerprints.json`)は退避して空から回し、最後に戻す
- run の特定は実行前後の `results/runs/` の差で行う。`fm-verify.sh` と**同時に回さない**
  (どちらも `_disabled/` のシナリオを出し入れする)
- 自己修復(`StepExecutor` の解決分岐・`LocatorFingerprint`・`LocatorFingerprintCache`・`heal` の配線)を
  触ったら回すことを**推奨する**(`e2e.sh` の終わりに出る。回すのはユーザーの指示があるとき = §陽性対照スイート)。実測(2026-09-15): iPhone 17 Pro Simulator で約 70 秒(シナリオのビルド込み)・Pixel 9 Emulator(`--profile android-heal`)で約 40 秒。どちらも全段が期待どおり

## デバイス供給の競合(モニターと run が同じデバイスを取り合う)

拡張のモニターは watchdog で `api start-device` を投げる。run と同じデバイス群を使うので競合し得る。
**マシン再起動直後**(全デバイスが落ち、拡張も run も同時に供給を始める)が最も踏みやすい。

- **XCUITest ランナーは 1 デバイス 1 本が OS 制約**。2 本目は永久に announce せず、
  そのデバイスのシナリオが全滅する
- 供給側の防御は2段:
  1. `BridgeProvisioner.planBridge` が **announce 前のランナーも見て `.adopt`(起動せず待つ)**
     に落とす(検出は `BridgeLauncher.portsByUDID` = プロセス引数の `-destination id=<UDID>` 照合。
     `scanRunningBridges` は /status 応答済みしか映らないのでこれだけでは足りない)。
     引き取ったランナーが応答しなければ止めて同じポートで立て直す(親を失ったゾンビ対策。
     **起動予算を超えて生きているランナーは待たずに起動し直す** —— 上の §「起動中のブリッジを待つ」)
  2. run は**供給フェーズ(install・凍結triage)の間も run-lease を保つ**(`SupplyLeaseHolder`)。
     `RunOrchestrator` の lease はシナリオ実行中しか書かれないため、その手前に watchdog の
     `api start-device` が割り込む穴が空いていた。**orchestrator が書き始めたキーは手放す**
     (`handOff`。手放さないと担当を終えたデバイスの lease を run の最後まで書き戻す)
- それでも手で確実に避けたいときは `fleetest.autoRepairBridge` を false にするか、
  E2E 前にモニターパネルを閉じる
- **`.adopt` は健全な環境では通らない**(announce 前のランナーが残っていないと発火しない)ので、
  E2E が緑でも「退行が無い」以上のことは言えない。実際の発火は再起動・拡張再起動を跨いだときに
  自然と起きる。**通らない経路を「E2E 緑」で検証済みと書かないこと**
- **Android エミュレータは run が自動起動しない**(iOS シミュレータは供給が起こす)。
  再起動後は `fleetest devices up --project <名> --profile <名>` を先に回す

## iOS が `never joined the run` / 「the in-app bridge did not respond in time」で供給に失敗したら

(iOS が**1台も**合流しなかった run は、残りを配らずに「no iOS device joined the run」で止まる = run.json の `abortReason`。
原因の切り分けはこの節と同じ)

**まず残骸の in-app ブリッジを疑う**(受け手報告 2026-08-22・こちらでも 2026-08-23 に再現)。
全シミュレータはホストの loopback を共有するのでブリッジのポートは**デバイスを跨いで一意**だが、
in-app ブリッジは注入先アプリが**前面のときしか /status に答えない**。別のデバイス・別のクローン・
中断された前の run のアプリが背面でポートを掴んだままだと、`scanRunningBridges` に映らず
採番では空きに見え、新しい注入が bind できずに「did not respond in time: The network
connection was lost」で落ちる(そのデバイスは never joined = 準備できていないデバイスを緑にしない正しい挙動)。

2026-08-23 からツールが自分で扱う(`BridgeProvisioner.executeBridge`):
- **これから使うポートを LISTEN している実体を記録の有無に関わらず `PortHolder` で確かめ**、
  シミュレータ内アプリ/残骸ランナー/iproxy なら止めてから注入する
  (ログ `🔧 … stopped a leftover bridge holding port N (pid M: …)`)
- 止められない無関係プロセスなら **in-app は撃たずに落とす**(`port N is in use by another
  process (pid M: …)`)。xcuitest は従来どおり bindFailed の検知に任せる
- 再利用できない旧ブリッジの停止手段は `StaleBridgeStop.decide`(記録無し → PortHolder。
  以前は `.pid` 経路へ流して「no .fleetest/bridge.pid」で止めそこねていた)
- 注入後に ready にならなかったときは**占有者を名指し**して落とす(`PortHolder.describe`)。
  起動したアプリは terminate し記録も消す
- `.inapp` の記録は **ready を待つ前に書く**(待っている間に run が中断されても記録が残る)

それでも手で見るなら `lsof -nP -iTCP:<port> -sTCP:LISTEN` で占有 pid を出し、シミュレータ内
アプリなら `xcrun simctl terminate <udid> <bundleID>`(`pkill -f <アプリ名>` でも止まるが、
同名アプリの現役ブリッジを巻き添えにする)。**`port` はデバイス指定のキーではない**
(`runs/*.json` の devices に書いても "unknown key" で無視される。採番は自動)。

## macOS / Xcode ベータの整合

- macOS ベータを更新したら Xcode も同じベータへ揃えてフルリビルド。FoundationModels の ABI 不整合で
  全バイナリが dyld クラッシュする(swift build は SDKROOT/--sdk を無視するため Xcode 側を揃えるしかない)
- Xcode(beta)単体の更新でも同様: iOS ランタイム導入(`xcodebuild -downloadPlatform iOS`)+
  ランナー再ビルドで整合させる。不整合はアプリが数操作で「Application is not running」クラッシュする
  (`fleetest doctor` がツールチェーン指紋の不一致を警告。2026-07-21 実害)。**判定に成果物の
  `Info.plist` を使わない** —— `XCTRunner.app` は SDK のテンプレートのコピーで、`DTXcodeBuild` は
  テンプレート自身の値のまま残る(Xcode 27 beta 6 は `27A252` で、`xcodebuild -version` の
  `27A5252f` と体系が違う = ビルドし直しても永久に警告し続ける。2026-08-25 に踏んだ)。
  正は `BridgeLauncher.staleRunnerToolchain` = 再ビルドの砦と同じ指紋

## テストが接続拒否(「ドライバへの接続が拒否されました」)で全滅したら

まず**プロファイル経路で走ったか**を確かめる。実行プロファイル未指定だと `--platform/--port` の
直接ポート接続に落ち、**ブリッジが自動供給されない**ため、事前に `bridge up` していなければ
全シナリオが即失敗する(拡張は 2026-07-26 から未指定で実行を止めるが、CLI では今も起こる)。

- **run.json の `machine` がホスト名なら非プロファイル経路**(プロファイル経由ならマシン
  プロファイル名が入る)。`scutil --get ComputerName` と比べれば一目で分かる
- **全シナリオが数十 ms・run 全体が数秒**なら供給が一度も走っていない(供給は数十秒かかる)
- 生きているブリッジは `curl -s 127.0.0.1:<port>/status` で確認する。`.fleetest/bridge-<port>.log`
  や `bridge-<port>.inapp` は**残骸が残る**ので、ファイルの存在は稼働の証拠にならない。
  `/status` の `sessionBundleID` で「どのアプリのブリッジか」まで見ること(別 SUT のブリッジが
  生きていても対象アプリには使えない)

## ワーカーが「ブリッジ接続不能のため離脱しました」で落ちたら

**まず XCUITest ランナーのクラッシュを疑う**(2026-07-28 に真因確定・修正済み)。
`~/Library/Logs/DiagnosticReports/FleetestRunnerUITests-Runner-*.ips` が積まれていれば確定。
スタックが `Issue.record` → `Event.post` → `SwiftTestingInteropRecordHandler` の**再帰**で
数千段になっていれば、XCUI の操作失敗を起点にしたツールチェーン不具合(../design/bridge.md「XCUITest ランナーは「操作の失敗」でプロセスごと落ちる」)。

- **ホスト側の症状は2種**。`The request timed out` / `The network connection was lost`
  (ランナー死=処理中の HTTP が返らない)と、**離脱せずに「12 回スクロールしても見つかりません」**
  (別アプリを掴んで無言で空振り)。後者は失敗レポートの要素一覧が**対象アプリの画面のまま**なので
  「スワイプが効いていないだけ」に見える
- ランナー側の決め手は `.fleetest/bridge-<xcuiPort>.log` の
  `Failed to application <bundleID> is not running`。**その bundleID が対象アプリと違えば**
  セッションの取り違え(使い回した XCUITest ブリッジが前のプロジェクトのアプリを指したまま)
- **再現条件は「複数 SUT を連続で回す」**。`Scripts/e2e.sh --ios --ios-inapp --cmp` のように
  SUT を1つに絞ると出ない(プロジェクトを跨いだセッション残留が起きないため)。
  切り分けは必ずフル構成で、**A/B は変更を `git stash` して同じ条件で並べる**
  (実測: ベースライン フル×2 = 各1件離脱、修正後 フル×2 = 0件)

## iOS の Compose・Flutter が「文字が描かれていない」「screen rendering check」で全滅したら

Simulator のアプリのプロセスの描画が崩れている(アプリの領域が一色・形は描けて文字だけ無い。木は正常)。**一度崩れると
アプリを起動し直すまで戻らず、Mac の状態が悪いと E2E でも崩れ続ける**。崩れるのは自前描画(Compose・Flutter)だけで、
SwiftUI・RN は描ける(docs/design/dsl-execution.md「描画崩壊の検査」・MN-90)。

- **E2E の規模では崩れない**: 再起動の後のフル E2E・E2E-CMP の iOS 1プロファイル(58 本)は崩壊 0(2026-10-19)
- **負荷テストの規模で崩れ始める**: Simulator 10・Emulator 8・実機・ファズ・配信を同時に掛けると、再起動の後でも約 8 分で再発した
- **負荷テストの後に回帰の E2E を回すなら、先に Mac を再起動する**(崩れた状態のまま回すと赤の大半が環境になる)。
  ツールは崩れた画面を可視性検証と描画崩壊の判定で赤にするので、崩れたまま緑で終わることはない
- 見分け方: 失敗の写真で文字が1つも無い・アプリの領域が一色で、同じ時間帯に SwiftUI・RN の SUT は緑

## テストが「Application is not running」で全滅したら

ランナーや自分の変更を疑う前に **SUT のバックエンド死活を確認**する
(sut-ec-mobile は localhost:8090 の dev サーバ。停止中はアプリが非同期例外でクラッシュする)。
apps プロファイルの healthCheckURL が実行開始時に警告を出す。

バックエンド停止の症状は 2 種が混在する(実測 2026-07-27): SUT の SIGABRT クラッシュ
(未処理コルーチン例外。`~/Library/Logs/DiagnosticReports/` に .ips が積まれる)と、
エラー画面のまま要素が解決できない大量失敗。**決め手は失敗レポートの「失敗時点の要素一覧」**
(エラー画面 `#view_error`「読み込みに失敗しました」が写っていればバックエンド起因で確定)。
.ips が積まれていてもツールや OS beta を疑う前に `/health` を確認する。

## FM 呼び出しの許可枠(FMCallSlots)

FM は**ホスト全体で共有される資源**。2026-07-22 時点の実測ではスループットは並列度によらず
約1回/秒に見えたが、これは**枠1本(直列化)の上限**であって FM 自体の天井ではなかった
(2026-09-01 の反証は `Sources/FTCore/FMCallSlots.swift` 冒頭が正 —— `fleetest doctor --fm-load` で
門を通さず直接叩くと、並列度5で 7.81 回/秒(text)まで伸びる)。並列ワーカーから無制限に同時に
投げるとやはり modelmanagerd のモデル積み降ろし(`unloadIfNeededToMakeRoom`)が増えるので、
呼び出し側で**枠(既定1・`FT_FM_CONCURRENCY` で上書き)を作る**(`FMCallSlots`。
~/Library/Caches/fleetest/fm.lock.<0..<枠数> への flock)。

- **リポジトリ単位ではなくホスト単位**。別リポジトリの fleetest とも枠を共有する
- **全ての FM 呼び出しがこのロックを通る**のが不変条件(occlusion / screenLooksLike /
  TestbaseDrafter。自己修復は 2026-09-15 に FM を呼ばなくなり対象外)。
  新しい FM 呼び出しを足すときは必ず通すこと。画像を伴う 2 つ(occlusion / screenLooksLike)は FM の常駐プロセスへ頼む側で通す
  (実呼び出しは常駐プロセスが撃つ。MN-81)。
  監査は `FMAccountingAuditTests`(セッションを作る関数と常駐プロセスへ頼む関数の両方)と
  `FMServeTests.testOnlyTheFMProcessAndAuthoringToolsCreateSessions`(セッションを作ってよいファイルの集合)
- **取れなければ FM をスキップする**(既定 20 秒)。全ワーカーが並ぶと最後尾の待ちが積み上がり
  シナリオの壁時計タイムアウトを超えうるため、この安全弁は外せない。スキップは**失敗とは別に
  数える**(`FMHealth.recordSkip`。失敗率の分母を汚さない)
- **FM に狙って負荷をかけたいだけなら `fleetest doctor --fm-load`**(既定
  `--fm-load-seconds 30 --fm-load-concurrency 5`。**この口だけは FMCallAdmission/FMCallSlots を通さない**
  ので実行中の run と容量を奪い合う点に注意)。経路は2つ: 既定はテキスト経路、
  `--fm-load-vision` は画像入力経路(occlusion-guard 相当)。**自己修復は 2026-09-15 に FM を
  呼ばなくなったため、テキスト経路の実行時利用者はもう無い**(シナリオ下書き・命名コマンドは
  実行時ではない)。**text と vision は独立に死ぬ**ので両方確かめたいときは両方回す。記録は
  `FMHealth.record(kind: "loadtest")` を通るので監視の FM 行にも出る。E2E ではほぼ FM が焚けない
  ため、flake 調査や負荷試験で意図的に FM を鳴らしたいときはこれを使う
  (詳細と実測は PT-3.5)
- **A/B 計測の殺しスイッチ**: `FT_FM_CALL_SLOTS=0` で無効化(acquire が常に true = 素通り)
- **occlusion の FM 段は転写だけ**(2026-09-15。期待文字列を FM に渡さず `TranscriptMatch` が照合する)。
  2 段化の殺しスイッチ `FT_FM_OCCLUSION_TWO_STAGE` は撤去した。方式と実測は
  OG-5.18

  ```bash
  FT_FM_CALL_SLOTS=0 Scripts/e2e.sh   # 呼び出しの枠なし
  Scripts/e2e.sh                      # 直列化あり(既定)
  ```

- **A/B は1回の再起動では取れない**。片方の実行で FM を殺すと、もう片方が死んだ状態から
  始まってしまう(FM は一度落ちるとプロセスを変えても回復しない)。**アーム毎に再起動する**こと

### 検証結果(2026-07-27): **直列化では FM の全滅を防げない**

導入の動機だった「積み降ろしの連発 → 全滅」という因果は**反証された**。積み降ろしは全滅の
随伴現象であって原因ではない。アーム毎に再起動して全 SUT の E2E を回した実測:

| プロファイル(実行順) | 直列化 ON | 直列化 OFF |
|---|---|---|
| 1本目 | 21 calls / 0 失敗 | 21 calls / 0 失敗 |
| 2本目 | 9 calls / **9 失敗** | 21 calls / **21 失敗** |
| 3本目以降 | 全て 0% | 全て 0% |

**ロックは正しく効いていた**(空振りではない)ことを次で確認済み:
FM 呼び出しの時間的な重なりがゼロ(別プロセスが 1.5〜3 秒間隔で順番待ち)/
p50 レイテンシ 2416ms → 1675ms(−31%)/ ロック待ちによる skip は 0 件。

**崩壊のトリガーは時間でも並列度でもない**。再起動から E2E 開始まで 43 分あって FM は生きており
(時間ではない)、直列化で並列度を 1 に落としても崩壊した(並列度でもない)。両アームとも
**累積 20〜30 回の呼び出しで尽きる**ように見えるが、2 標本からの推測で確証はない。

直列化は**この目的では効果が無かった**が、実測で害が無く p50 が下がるため残している。
全滅そのものへの対策は**サーキットブレーカ**(下記)側で行う。

## サーキットブレーカ(FMBreaker)

FM は死んだら**再起動まで回復しない**ので、死んだ後も呼び続けるのは純粋な浪費
(実測: 全滅した 1554 シナリオで合計 31 分を捨てていた)。**連続 3 回失敗したら以後は呼ばない**。

- **入場は FMCallAdmission に一本化**している。`FMCallAdmission.enter()` が ①ブレーカ ②許可枠のロック(FMCallSlots)
  を順に見る。
  **新しい FM 呼び出しを足すときは必ずここを通す**(監査: `grep -c "FMCallAdmission.enter" Sources/FTFoundationModels/*.swift`
  と、頼む側の関数(`FMServeWire.Request(kind: .transcribe` / `.screen`)・テキストの呼び出し(`TestbaseDrafter`)の数を突き合わせる。FMDoctor は可用性判定、FMServeServer は頼まれた実呼び出しなので対象外)
- **ホスト単位**(~/Library/Caches/fleetest/fm-breaker.state の mtime)。全滅はホスト全体の事象で
  ワーカーはプロセスが別なので、プロセス内カウンタだけだと 14 ワーカー分を無駄打ちする
- **成功したら即座に復帰**する。10 分(cooldown)経過後は 1 回試させる(half-open)ので、
  FM が復活したことを検知できる
- ブレーカ由来のスキップは**失敗と別に数える**(失敗率の分母を汚さない)。実行後の警告に
  「N 件はスキップしました」として出る
- `FT_FM_BREAKER=0` で無効化(切り分け用)

**実測(2026-07-27・FM 全滅状態)**: 同一シナリオの FM 呼び出しが **11 回 → 3 回**へ。
浪費が 6.0 秒(3 回)で止まり、残り 8 回はスキップされた。
