# 設計: レスポンス計測

| 種別 | 範囲 | 読む場面 | 扱わないこと |
|---|---|---|---|
| 正典 | 何を測るか(RM-1)・t1/t2 の測り方(RM-5)・プロファイルのキー/結果 JSON/比較/ブリッジ/段階ごとの確認(RM-8) | レスポンス計測の設計・結果の欄・ブリッジの観測口を変える前 | 試作の方法と実測(→ [../response-measurement.md](../response-measurement.md))・利用者向けの説明(→ [../user-docs/reference/running/response_measurement_ja.md](../user-docs/reference/running/response_measurement_ja.md)・[../user-docs/response/measuring_app_response_ja.md](../user-docs/response/measuring_app_response_ja.md))・結果 JSON のスキーマ(→ [../results-json.md](../results-json.md)) |

実機 1 台で、画面を動かす操作ごとに「最初の画面変化(t1)」と「次の操作ができるようになった時刻(t2)」を測る機能の設計。
試作の実測と、定数・方式の根拠になった数値は [../response-measurement.md](../response-measurement.md)(RM-2〜RM-4・RM-7)にある。

**用語**: 木 = アクセシビリティ(a11y)の要素ツリー(ブリッジの `/snapshot`)/ SF = SurfaceFlinger(Android の画面合成。アプリのフレームが
画面に出た時刻を持つ)/ SUT = fleetest 自身の E2E 用アプリ。

## RM-1 何を測るか

「レスポンス計測モード」で、並列なしで回す。**対象は実機(決定: ユーザー 2026-10-15)**。Simulator / Emulator は対象外。
1回の操作について、次の3つの時刻を取る。

```
操作の注入 ──▶ 最初の画面変化 ──▶ 操作可能になった時刻
   t0              t1(反応)            t2(操作可能)
```

- **t2 は次のステップで決める**: 次のステップの対象が木で解決でき、覆われておらず、枠が止まっていて、**かつアプリが応答する**。
  次のステップが無いとき(シナリオの最後)は画面の静止だけで決める
- 時刻は**デバイスの時計**で打つ(ホストで打つとブリッジとの往復が混ざる)
- 1回の値で語らない(N 回の中央値・p90)。比べるのは**同じデバイス・同じ機械での前回比だけ**。帰属(「アプリが遅い」)は書かない
  (失敗の記録と同じ規律)

## RM-5 t1・t2 の測り方

### アニメーションと t0

- **計測モードはアニメーションを必ず残す**: ブリッジは既定で Android のアニメーション倍率を 0 にし、iOS は Reduce Motion を入れる
  (`AnimationPolicy`)が、止めた状態の応答時間は利用者の体験を表さない(RM-7: 遷移が 3 → 8 フレームに伸びる)ので、計測モードは
  `enableAnimations` を強制する。`enableAnimations` と同じく **run の開始時に合わせるだけ**で、計測の run の終わりには Android 実機の倍率を
  **読めた元の値すべて**へ戻す(コールド起動のぶんも含めて書く)。iOS の実機はホストから Reduce Motion を変えられないので端末の設定のまま
- **t0 はブリッジが端末の時計で返す**: Android は ACTION_DOWN の `downTime`(`SystemClock.uptimeMillis`)、iOS はランナーが合成を撃つ直前の
  `mach_absolute_time`(xctrace の `mabs-epoch` と同じ時計)。外から読む方法は残らなかった(Android 13 の `dumpsys input` は eventTime を
  出さず、iOS は記録の開始時刻が秒単位で、アプリの run loop は XCTest の事前問い合わせで起き続けて受けた瞬間を区別できない)。
  「注入の直前」ではなく入力イベント自身の時刻にするのは、CMP のフリーズでは注入そのものが約 3 秒止まり、直前の時刻だと反応にフリーズの全体が入るため

### t1(反応)= 最初のフレーム

- **操作の直後に入る欄は `busyBeforeAction` / `quietWaitMs` / `firstFrameMs` / `firstFrameMissing` だけ**。`reactionMs`(t1 そのもの)は常に省略し、
  `firstFrameMs` を写さない: **最初のフレームは t1 ではない** —— 同じ中身のバッファの出し直しも1枚になり、iOS の画面に出たフレームは画面全体なので
  時計表示や通知の更新も拾う。t1 を名乗るには注入前の絵との差での確認が要るが、実装していない。`firstFrameMs` は「最初の注入から、最初に提示された
  フレームまでの遅れ」という別の量
- **操作の前に描画が止まっていることを確かめる**(`/responsePrepare`。アプリが `responseQuietMs` の間フレームを出さなくなるまで最長
  `RunTunables.responseQuietTimeoutMs` = 10 秒待つ)。実機では前の操作の描画(約 3 秒)が続いていることがあり、そのまま測ると 1〜2ms と出る(RM-7)。
  待っても止まらなければ `busyBeforeAction` を事実として残して `firstFrameMs` を出さない。10 秒の根拠: セレクタ画面へ遷移した直後の待ちが 5 回中 4 回で
  6562〜6613ms(観測した最長約 6.6 秒の約 1.5 倍)。描画が何なのか(見た目は変わらない)は未特定
- **Android**: `/responseCollect` が直近の注入の `downTime` と最初のフレームまでの遅れを返す(SF の履歴)。履歴が満杯で区間を確かめられないときは
  `noFrame` より先に `frameHistoryIncomplete`。**`noFrame` は観測を取りに来るまで暫定**: 次の計測ステップの prepare の静止待ちは
  `--latency-clear` を何度も撃つので、**消す各回の直前に**前の観測の最初のフレームを求め、見つかれば確定、確定の前に履歴の不足を見たら
  `frameHistoryIncomplete` で確定する(規則は `FirstFrameState.java` に集め、Android に依存しない形で `AndroidFirstFrameStateTests` が javac で動かして固定)
- **iOS**: 最初のフレームは**親プロセス**が run の間 Instruments(xctrace)で記録し、run の後に結果 JSON と md へ書き足す(`ResponseTracePatch`)。
  探す範囲は「最初の注入より後〜観測が締まった時刻(`observationEndMs`)以下」で、表の最後のフレームまでしか覆わない(範囲の外は空欄 = 誤った `noFrame` にしない)。
  **iOS の最初のフレームはアプリに限らない**: 表の行の大半はプロセスを持たない画面全体の表示更新なので、注入の後に最初に画面が更新された時刻になる
  (ステータスバー等が先なら、それを数える)
- 時刻だけで装飾(スクロールバーのフェード等)を切る方法は採らない(RM-4 の2・3)。**フレームが出ていることを応答の根拠にしない**
  (フリーズ中も RenderThread / render server が押下のアニメーションを描く = RM-7)

### t2(操作可能)= 木の履歴で判定する

- **注入の時点では次の対象は分からない**(`FTRuntime.perform` はステップを1つずつ同期で実行し、次に何をするかはシナリオの Swift のコードが決める)。
  次の操作ステップが始まってから判定する方式も採れない(その時点で過去の木・遮蔽は復元できない)。そこで
  **ブリッジが、計測するステップ j の最初の注入から次に計測するステップ i の最初の注入まで、木を読み続けて履歴(全読みの時刻と、変わった木)を持つ**
  (`ResponseObserver` / iOS は `ResponseMeasurement.swift`)。i が対象を解決し終えたら、ホストが j の履歴を
  **i が実際に解決して操作した要素**で判定する(`ResponseReadyJudge`。解決は StepExecutor と同じ `LocatorResolver`、遮蔽は操作の前と同じ
  `OcclusionGeometry`)。結果は j のレコードへ後から当てる(`responseReady` イベント → `ScenarioRecordBuilder` が `timeline[]` へ)。
  判定に使う対象は次のステップが解決した事実なので、**予測も学習の繰り返しも要らず、1回目から t2 が取れる**
- **条件**: ①解決できる・有効・覆われていない ②枠が次のステップの使った枠と等しい を満たす読みが、続く次の成功した読みでも保たれた最初の読みの終わりを t2 とする
  (`readyDecidedBy` = `tree`)。③(アプリが応答する)は読みが返ること以上の独立した材料を持たない。**④(画素の静止)は判定しない。
  要素の同一性は比べない**(`readyIdentity` = `locator`: 同じ位置に別の要素が来ても見分けない)
- **ホストからのポーリングでは測れない**: 実機では木の取得1回に数百 ms かかる(RM-7)。ブリッジの中で読むと素の取得は 4〜8ms(RM-7)。
  また木の観測を `/tap` が戻ってから始める形は a11y の静穏待ち(`QuietWaiter.QUIET_MS` = 200ms)の分だけ下限を作る(RM-4 の7)ので、観測は注入と同時に始める
- **判定しない場合**(t2 の欄は省略のまま): 次の計測ステップが無い(シナリオの最後)・失敗や中断で終わった・次のステップが対象に着くまでに自分で画面を動かした
  (スクロール探索・寄せ。使った枠が履歴の木の座標と別になる)。**シナリオの最後は画面の静止(③+④)で決める設計だが、静止の判定は未実装**(RM-6)
- **欠測の理由**(`readyMissing`。事実だけで、帰属しない): `notReadyBeforeNextAction`(条件が揃う前に次の操作が撃たれた)/
  `observationTimeout`(上限で締まり揃った回が無い)/ `observationTruncated`(記録の上限に達して途中からやめた)/ `observationLost`(ブリッジに観測が無い)/
  `noTarget`(次のステップに、セレクタで解決した要素が無い = 座標の操作等)/ `bridgeError`
- **論理ステップと注入を分ける**: 1つの操作ステップが複数回注入することがある(`scrollDown(repeat: 2)`・`type(replace: true)` 等)。観測は**論理ステップに1つ**。
  t0 と `firstFrameMs` は**ステップの最初の注入**から、t2 の条件は**最後の注入より後で**成り立ったものだけを数える。同じステップの2回目以降の DOWN では
  記録を捨ててその DOWN から記録し直し、上限の起点もそこへ移す(捨てないと、何度も送る操作は最後の注入の前に記録の上限を使い切った:
  32 ステップ中 3 ステップが `observationTruncated`。木の上限を 30 → 100 に上げても同じだった)。`readyMs` は最初の注入から測り、
  `readyAfterLastInjectionMs`(最後の注入から)・`injectionSpanMs`(最初から最後まで)・`injections`(回数)を並べる(最後の注入からの値だけだと、
  注入 0ms・2000ms で準備 2100ms の回と、注入 0ms・200ms で準備 300ms の回が同じ 100ms になり、操作全体の遅れが比較に出ない)
- **観測の上限(`RunTunables.responseObserveMs` = 10 秒)は判定を止めるだけで、観測を締めない**: 起点はそのステップの直近の注入。上限に達したら
  判定を止め、同じステップの次の注入が来たら起点を移して再開する(反復フリックの間隔が上限より長くてもステップの途中で終わり方が確定しない)。
  観測を締めるのは次の計測ステップの最初の注入・停止要求。締めた観測は直近 2 件を持つ(ホストが取りに来る前に次の締めで押し出されない)。
  読み回数 5000・変わった木 100 本が記録の上限で、尽きたら `truncated` で申告する(木が満杯のとき変わった木の読みは足さない = 古い木で「2回連続で保持」と誤らない)
- **iOS のランナー**はメインスレッドが空いた時しか木を読めず、ステップの合間の読みはほぼ 0 回だった。**ホストの `GET /snapshot` の木も観測の読みとして記録する**
  (検証と次のステップの解決のために必ず来る)。それでも 1 ステップあたり 2〜4 回で、t2 の分解能は数百 ms
- 解決・遮蔽は共有の判定(`LocatorResolver`・`OcclusionGeometry`・`TapTargetGeometry`)を使い、計測用に二重に持たない(MCP と DSL で判断が食い違わないため)
- 採らなかった方式: 繰り返しの1回目で次の対象を覚え、2回目以降に注入と同時にブリッジへ渡して判定する方式(呼び出しスタックを鍵に予測を引く)。
  予測の外れ・鍵の衝突・別スレッドで欠測が増える上、木を記録しておけば履歴を後から判定できるので不要になった。費用は観測中ずっと木を読む負荷と記録の転送量
  (木が変わった回だけを送り、上限を置く)

## RM-8 製品化の形

参考にした慣用: Android Macrobenchmark(回数を指定して中央値・最小・最大を出す)/ XCTest の `measure(metrics:)`(**基準値をデバイスごとに持ち**、前回との差で見る)。
Shirates にはこの機能が無いので踏襲元は無い。利用者向けの切り替えはプロファイルのキーで持ち、上書きは `--set` だけ(キーごとの専用フラグを足さない
= `.claude/rules/profile.md`)。既存の `--performance` は「レーンを厳格に扱う」意味なので流用しない。

### RM-8.1 有効化 = プロファイルのキー

- **`responseMeasurement: true`**(既定 false)。`--set responseMeasurement=true` で上書きできる(`run` / `api run` の両方。専用フラグは足さない
  = `RunCommandFlagParityTests` は変えずに済む)
- **`responseRepeat: N`**(1〜50 の整数・既定 `ResponseMeasurementPolicy.defaultRepeat` = 5・`responseMeasurement` 無しの指定はエラー・
  `RunMetaRecord.responseMeasurement.repeatCount` に記録)。各シナリオを続けて N 回回し、ステップごとに中央値・p90 を出す。繰り返しは標本を増やすためだけにある
  (t2 は1回目から出るので下限は 1)。作業の URL に `repeat=N` を足して区別し、結果ファイルは `<id>`・`<id>~2`…。上限 50 は 1 回の計測 run の所要を有限に収める
  (超える値は意図より打ち間違い)
- 実行時設定は `ScenarioExecutionSettings` に欄を足して運ぶ(`.claude/rules/executor.md`)。**専用フラグを足さないことでは `run` / `api run` の配線漏れは
  防げない**(`RunCommandFlagParityTests` が見るのはフラグの集合だけ)ので、両方の入口で有効化・拒否条件・結果の出力・モニターの停止を確かめるテストを置く
- 有効なときの強制と検査(**「指定したが黙って効かない」を作らない** = 名前の付いたエラー。`ResponseMeasurementPolicy`):
  - 設定の検査(`validateSettings`)は `ProfileResolver.resolve` の1箇所(`run` / `api run` 共有)。`enableAnimations: false`・`iosMode: inapp`・
    `fmTextVisibilityCheck` / `ocrTextVisibilityCheck` / `screenLooksLike` / `record` の true との併用はエラー
  - デバイスの検査(`validateDevices`)は `--device` / `--runner local` で絞った**後**の台数に当てる(run / api run の入口 = ロックの前・機械へ配る前。
    機械をまたいで数える。マシン別のサブ実行の中だけで数えると、手元とリモートに 1 台ずつ配られて並行に測ってしまう)。**有効なデバイスが1台**・
    `kind: physical`・Android か iOS・iOS は `mode: inapp` の明示を断る(解決が計測の run の既定を xcuitest に倒す)。実機が 2 台あるプロファイルでも 1 台に絞れば測れる
  - **並列なし**: レーンを 1 本にする。`--broadcast` / `--split` / `--fleet` との併用はエラー(`combinationRejection`)
  - アニメーション ON・FM/OCR/録画 OFF の強制値は `DeviceIndependentRunSettings.resolve` が持つ。ホスト負荷による減速も止める。
    モニターは run が pause して終わったら戻す(`e2e.sh --performance` と同じ持ち方。期限付きの `monitor pause` は run の間だけ期限なしに置き換えて終わりに戻す。
    停止の印 `.fleetest/monitor-hold.json` は**コマンドを撃ったディレクトリのクローン**に書かれ、拡張のモニターは本線のクローンを見るので、別の作業ツリーから
    起動した計測の run の停止はモニターに届かない)

### RM-8.2 測る範囲 = 全ての操作ステップ(自動)

- tap / type / swipe / scroll / launchApp 等、**画面を動かす操作の全ステップ**(`FlowStep.isScreenMovingOperation` = ホスト負荷の減速 `HostLoadPacing` と共有)で
  t1 の材料・t2 を取る。検証・待ち・`select`・`findImages`・`waitForSettle`・`performCustom` 経由(launch / back / home / wait 等)は測らない
- シナリオ側に専用の DSL は足さない(範囲は `--scenario` / `--folder` で絞る)。後から欲しくなったら `measure("名前") { }` のブロックで区間をまとめる形を検討する(XCTest の慣用)

### RM-8.3 結果 JSON

- `TimelineStepRecord` に省略可の `command`(コマンド名。description から切り出して埋めない)と `response`(`ResponseMeasurementRecord`)を持つ。
  `response` は計測モードの run の画面を動かす操作のステップだけ。欄の定義は [../results-json.md](../results-json.md) の TimelineStepRecord が唯一の定義元。
  - **操作の直後に入る**: `busyBeforeAction` / `quietWaitMs` / `firstFrameMs` / `firstFrameMissing`(`busyBeforeAction` / `noInjectedInput` / `noFrame` /
    `frameHistoryIncomplete` / `noSessionApp` / `bridgeError`)/ `downTimeMs`(最初の注入の端末時計の値。iOS の xctrace の突き合わせ用)
  - **次の計測ステップが対象を解決した時点で後から入る**: `readyMs` / `readyAfterLastInjectionMs` / `injectionSpanMs` / `injections` / `readyDecidedBy` /
    `readyIdentity` / `readyMissing` / `observedReads`(最後の注入より後に読めた木の回数 = t2 の分解能と判定の材料の量)/ `observationEndMs`。
    判定されなかったステップは t2 の欄が省略のまま
  - 使わない欄: `reactionMs`(常に省略)・`readyAfterObservationStartMs` / `observationStartMs`(観測は最初の注入から始まるので)
  - 帰属・分類の欄は置かない(失敗の記録と同じ規律)
- `RunMetaRecord.responseMeasurement`(`ResponseMeasurementRunInfo`)に、デバイスの識別(`deviceName`・`serial` / `udid`・`model`・`osVersion`)と `repeatCount` を書く。
  run.json の識別は配る前に書き、失敗の finish でも残す。前回比の「同じ端末」は `serial ?? udid ?? deviceName`
- **欄の扱い = 省略可・`ProtocolVersion` は上げない・保存記録は移行しない**(決定: ユーザー 2026-10-18。必須 + null・版 +1・保存記録の移行の案は採らない)。理由:
  - 結果のファイルは読めないと**黙って飛ばされる**(`RunResultsStore` の decodeFailure)。必須にすると、移行しそこねた保存記録が履歴からまるごと消える
    = 「沈黙する縮退」をこちらが作る
  - `response` が無いことは「計測モードの回ではない(= 測っていない)」という**正しい意味**を持ち、古い記録でも同じ意味になる。読むときに既定値で埋めて
    古い形を吸う読み替えには当たらない。`command` も無ければ「不明」のまま
  - 足した欄は後方互換(既存の読み手は無視する)なので、版を上げる条件(後方非互換)に当たらない。欄の意味を後方非互換に変えるときは、そのときに版を上げる

### RM-8.4 比較と報告

- **`fleetest results response [--project] [--since] [--json]`**(`FTCore.ResponseMeasurementQuery`)。`run.json` の `responseMeasurement` がある run だけを対象に、
  全文のシナリオ記録の `timeline[].response` を集計する(縮約版は `response` を持たない)。**ステップの鍵 = (scene, section, command, description, 出現順)**
  (出現順 = 同じ記録内で `response` を持つ同一4つ組の1始まりの通し番号。実行時の `index` は制御フローでずれるので使わない。表示は `s2 action tap Tap login #1`)。
  同じ run の繰り返しの記録(`<id>`, `<id>~2`…)は標本を合算する。
  列: scenario / step / device(serial があれば serial、無ければ deviceName)/ host / n(`firstFrameMs` のある標本数)/ median / p90(最近接順位法)/
  busy(`busyBeforeAction` の件数)/ prev median / delta(ms と %)/ ready n / ready median ms / ready p90 ms。JSON には `missingCounts`(`firstFrameMissing` の生の値ごとの件数)・
  `readyN` / `readyMedianMs` / `readyP90Ms` / `readyMissingCounts` も出る。各グループの最新の run の行で、前回 = **同じ (host, device) でそのグループを持つ直前の run**。
  デバイスか機械が違う run とは比べない
- 差は**警告として並べるだけ**(赤にしない。新しい検知は警告から。閾値で落とす機能は後で検討)
- シナリオの報告(`reports/scenario-*.md`)は計測モードのときだけ、計測ステップの行に ` · first frame 54 ms · ready 72 ms` を足す(`ScenarioReportWriter`。値が無いときは理由を並べる。事実だけ)

### RM-8.5 ブリッジの変更

- Android(`AndroidRunner`。`/responsePrepare` / `/responseCollect` / `/responseObservation` / `/responseObservationStop`)と iOS の XCUITest ランナー
  (`ResponseMeasurement.swift`)に、計測モードのときだけ通る同じ4つの口を持つ:
  ①注入の時刻(端末の時計)を返す ②計測ステップの最初の DOWN から木の履歴を観測する(裏で続け、**操作の応答は待たずに返す**)
  ③操作の前に描画が止まっているのを待つ(Android = SF のフレームが出ていない / iOS = スクリーンショットの比較。XCTest の操作後の待ち
  `QuiescenceWait` は材料にしない: tap では既定で待ちを飛ばし、残す操作でも上限 6 秒で打ち切って続行し、差し替え自体が効かない環境もある)
- 計測モードの経路は**リクエスト単位で適用して戻す**(例外のときも戻す)。計測の後の通常の操作へ待ち方が漏れない
- **計測は XCUITest ランナーにしか無い**(in-app ブリッジは 501)。計測の run は iOS を xcuitest モードで走らせる(`iosMode` の既定が xcuitest に変わり、`inapp` を明示すると断る)
- **iOS の最初のフレームは xctrace で取る**(`ResponseTracePolicy`・`ResponseTraceSession`・`ResponseTracePatch`): 計測モードの run の間だけ、iOS 実機 1 台のときに記録し、書き出すのは
  `displayed-surfaces-interval` / `potential-hangs` / `time-info` の3つの表だけ(全部書き出すと数分かかる)。注意:
  - `--all-processes` で録ると、記録中にアプリを1回起動しただけで保存に 72〜124 秒かかり、停止の上限で殺された。計測器を Display だけにして対象を名前で
    `backboardd` に絞ると 5〜7 秒(画面に出たフレームは端末全体の表なので、アプリのフレームも入る)。SpringBoard を pid で指定する形は、`devicectl` の一覧が
    起動し直した後の古い pid を返して失敗したので採らない
  - `--attach backboardd` の名前の照合はときどき失敗する(手で 3 回中 1 回)ので、その失敗のときだけ起こし直す(最大 3 回)
  - run の間は `InterruptRelay` が SIGINT を無視にしていて、`Process` で起こした子へ引き継がれるので `posix_spawn` で既定に戻して起こす
  - **保存される表は止めた時刻より数秒手前で終わる**(止める前に待つと表の末尾の「フレームの無い区間」が待った分だけ延びる = 表の終わりは止めた時刻に追従しない)。
    止める前に待って描画が残ったのは 0 秒 1/5・1 秒 0/3・2 秒 1/3・3 秒 5/5 なので、**run の後に 5 秒記録を続けてから止める**
    (`ResponseTracePolicy.stopLingerSeconds`)。足りなければ最後のステップが範囲の外になり、空欄に倒れる
  - 生の記録は大きい(9 秒の記録で約 97〜101MiB・約 3MB/秒)。止められずに残ったときの安全弁として `--time-limit 2h`。xctrace の見張りは spawn の直後から後始末の最後まで生かし、
    親の死では一時フォルダを引数に持つ子(書き出しを含む)を止めてから消す(見張りの sh は実際の /bin/sh でテストする = `ResponseTraceWatcherTests`)
- 版は、ブリッジの挙動を変えるたびに上げる(iOS `bridgeProtocolVersion` / Android `VERSION_CODE` = `.claude/rules/bridge-provision.md`)

### RM-8.6 段階ごとの確認

実装は4段で入った。各段の確認が、上の設計の定数と罠の根拠になっている。

1. **Android: 最初のフレームまで**(Android ブリッジ v103): Pixel 4a(Android 13)で E2E-Android の `起動と画面遷移が正しく行われること.S0010` を計測モードで 1 回。
   タップ 6 回のうち 5 回で `firstFrameMs` 49〜72ms(試作の 54〜77ms と同程度)。セレクタ画面の後の `#tab_controls` だけ描画停止の待ちが上限に達して `busyBeforeAction`
   (上限を 5 秒 → 10 秒に上げた根拠は RM-5)。罠: ブリッジのシェル実行口(`UiAutomation.executeShellCommand`)はシェルを通さないので、層の名前を引用符で包むと見つからない
   (全部 `noFrame` になった)。空白を含む層(入れ物・leash 等)は読まない
2. **繰り返しと比較**: `responseRepeat`・run.json の `responseMeasurement`・`fleetest results response`。Pixel 4a で同じシナリオを 3 回 → 2 回で流し、5 種のタップの中央値
   50〜70ms と前回比が並ぶことを確認(3 回の方はモニターを止めずに測った = 差には意味を読まない)
3. **Android: t2**(Android ブリッジ v106): `ResponseObserver`。Pixel 4a で確認(アニメーションあり・各 2 回): 画面遷移の後の t2 は 62〜79ms(試作のブリッジの中での観測 60〜74ms と同程度)、
   次の対象がタブバーのボタン(遷移の間も同じ位置に出続ける)のときは 5〜8ms = 最初の読みから操作可能(**ブリッジの読みはキャッシュを返しうるので、この短い値は③の証明としては弱い**)。
   `スクロールで折り返し下の要素に到達できること.S0010` は計測 32 ステップのうち t2 が出たのは 21、`noTarget` 2、残りはスクロールで探した回と最後のステップ。
   慣性のスクロールの後は約 1.0 秒、何度も送る操作(4〜5 回注入)は最初の注入から 4.8〜5.8 秒。打ち切りは 0
4. **iOS**(iOS ブリッジ 193 以降): iPhone SE3・iOS 26.6.2。`起動と画面遷移が正しく行われること.S0010` を計測モードで 2 回ずつ: 最初のフレームまでの中央値 143〜208ms
   (XCTest が入力を届けるまでを含む)、操作可能まで 682〜698ms(分解能は木の取得 1 回の所要 = 数百 ms)。Codex の実装レビュー 4 回の反映後(Android v109・iOS v194)は、
   Pixel 4a で `firstFrameMs` 49〜62ms・iPhone SE3 で 139〜237ms と、全ステップに `observationEndMs`。CMP・Flutter・RN × Pixel 4a・iPhone SE3 の同じシナリオ各 5 回で
   全組・全ステップに値が出て `busyBeforeAction` は 0(中央値は Android 70〜374ms・iOS 128〜260ms、p90 は中央値から概ね 10% 以内。t2 は遷移の後 Android 118〜427ms・iOS 652〜776ms)。
   Android で遅れて出るフレームの経路は、どのステップも collect の時点でフレームが出ていたので**デバイスでは通っていない**(単体テストだけ)
