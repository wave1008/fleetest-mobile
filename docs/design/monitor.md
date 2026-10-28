# 設計: デバイスモニター

| 種別 | 範囲 | 読む場面 | 扱わないこと |
|---|---|---|---|
| 正典 | 画面配信・ブリッジ死の検知と自己修復・ゲスト OS の健全性・3ペイン・run ボード(DS-12・18) | モニターの配信・回復・表示を変える前 | 拡張のビルドと i18n(→ .claude/rules/vscode-i18n.md) |

VSCode 拡張のデバイスモニターの設計。

## 目次

- DS-12 デバイスモニターの画面配信と自己修復
- DS-12.1 画面配信は3段フォールバック
- DS-12.2 ブリッジ死の検知と自己修復
- DS-12.3 実測(M1 Max、詳細は PT-4.1)
- DS-12.4 ゲスト OS 健全性の検知と自己修復
- DS-12.4.1 デバイスのストレージ計測(ダッシュボード「デバイスの健全性」)
- DS-12.4.2 iOS Simulator の PosterBoard スナップショットキャッシュの掃除(起動前)
- DS-12.4.3 iOS Simulator の統合ログ(Special)の整理(起動前)
- DS-12.4.4 iOS Simulator のニュースのウィジェットのタイムライン項目の掃除(起動前)
- DS-12.5 タイルペインの auto-fit と「非表示中は実測しない」規律
- DS-12.6 「デバイスモニター」タブの3ペイン(ラインビュー / グリッドビュー / 実行ログビュー)
- DS-18 デバイスモニターの run ボード(フリート横断の実行状況)
- DS-18.1 供給源は台帳(`FTCore.RunProgressLedger`)
- DS-18.2 監視への相乗り(`monitorRuns`)
- DS-18.3 時刻は秒に直して運ぶ
- DS-18.4 残り見積もり(新しい定数を1つも置かない)
- DS-18.5 UI(ツールバー直下に常設。ユーザー決定 2026-09-20)
- DS-18.6 実装の段
- DS-18.7 やらないと決めたもの
- DS-18.8 タコメーター(アクション/秒。ユーザー決定 2026-10-28)

## DS-12 デバイスモニターの画面配信と自己修復

### DS-12.1 画面配信は3段フォールバック

**H.264+WebCodecs(既定)→ MJPEG ストリーミング → スクリーンショットポーリング**の順に落ちる。

- **H.264 経路**: helper(`fleetest-simstream`=IOSurface→VTCompressionSession HWエンコード /
  `fleetest-androidstream`=screenrecord の H.264 をトランスコード無しでパススルー)が
  10バイトヘッダの v2 レコードを stdout へ → 拡張が Uint8Array のまま webview へ転送 →
  `VideoDecoder`(HWデコード)→ canvas。デコードは全チャンク(P フレーム連鎖のため)、
  canvas 描画のみ約 15fps に間引く。ワイヤ形式・ping の契約は
  `Sources/fleetest-simstream/main.m`・`fleetest-androidstream/main.m`・
  `vscode-fleetest/src/deviceStream.ts` の3ファイル同期(詳細はそのコメント)
- **フォールバック**: webview の `codecError`(WebCodecs 非対応/デコード失敗)でデバイス単位に
  MJPEG へ自動復帰(設定 `fleetest.streamCodec` で恒久切替も可)。ストリーミング自体の連続失敗は
  従来どおりポーリングへ(`onFailure`)。フォールバック状態はパネル単位のメモリ(開き直しでリセット)
- **monitor のスクショポーリング抑制**: タイルがストリーミング表示中のデバイスは、拡張が
  `suppressFrames`(stdin 制御)で monitor 側の生成ごと止める(受信後の間引きは競合吸収の
  安全弁として残置)。契約は `Sources/fleetest/ApiMonitorCommand.swift` 冒頭
- **壊れたレコードを webview へ流さない**: 長さ前置きのバイナリ列は helper が書き込み途中で死ぬと
  境界がズレ、以降**自力復帰せず**ゴミの寸法+非 JPEG を吐き続ける。v1 パーサは寸法・長さの足切りと
  JPEG SOI 照合で desync を検出し、未知 KIND と同じく helper を kill して張り直す
  (`deviceStream.ts` の `handleProtocolDesync`)。タイル側もヘッダ由来の寸法を信用せず
  **デコードできた画像の実寸だけ**でアスペクト比を決める(壊れたフレーム1枚でタイル幅が
  異常に広がったまま戻らないため)
- **実寸は `VideoFrame.close()` の前に控える**: close 後の VideoFrame は `displayWidth/Height` が
  0 を返す(WebCodecs 仕様の detach)ので、後で読むとアスペクト比が既定値(0.4615)のままになる。
  寸法が変わるたび `onDimensions` で枠へ反映する(初回だけだと解像度変更で古い比率が残る)
- **screenrecord のレターボックス補正(Android)**: screenrecord は**エンコーダ上限を超える画面を
  縮めた動画へレターボックス投影する**(黒帯が映像に焼き込まれるため、タイルは帯ごと表示する。
  実害: 1280x2856 の Pixel 10 Pro で左右に黒帯。1080x2424 では起きない)。`fleetest-androidstream` は
  起動時に 1 秒の `screenrecord --verbose` プローブ(出力先 `/dev/null`)で
  `Content area is <w>x<h> at offset x=<x> y=<y>` を読み、offset が 0 でないときだけ実内容の領域を
  `--size` に渡す。**プローブが返す領域はエンコーダが受け付けたサイズ以下**なので `--size` 明示で
  configure が落ちない(自前でサイズを推定すると拒否され得る。しかも `--size` 指定時の
  screenrecord は 1280x720 への自動フォールバックをせず即エラー終了する)。費用は約 1.2 秒/helper 起動

### DS-12.2 ブリッジ死の検知と自己修復

XCUITest ランナーは HTTP サーバだけ死んで xcodebuild 親が残ることがある。

- **watchdog**(`vscode-fleetest/src/monitorBridgeWatchdog.ts`): 一度 connected になったデバイスが
  booted(実体は起動中・ブリッジ無応答)へ降格して連続5観測(約10秒)続いたら `api start-device` を
  自動投入。実行レーン稼働中は保留・クールダウン3分・2回失敗で諦めて表示(`fleetest.autoRepairBridge`
  既定 ON)。タイルに出すのは諦めた後(failed)だけで、文言は実機「デバイス未接続」/仮想機
  「接続できません」(内部語ではなくユーザーの取れる行動が分かる語にする。fleetest 出力への
  誘導はホバーのツールチップへ退避。`deviceTiles.js` の `bridgeWatchLabel`)。
  **他の機械(リモート)のデバイスも見る**: 修復は lifecycle ジョブが machine を運び、
  `remote exec <machine> -- api start-device … --device-machine local` で向こうへ回す。記録の鍵は
  `device.id`(machine 込みで一意。name で持つと、向こうの connected が手元のハングを隠し、向こうの
  booted が手元の健全なデバイスを再起動する)。webview へ出す `bridgeWatch` にも machine を載せる(省略 = 手元)。
- **ブリッジ診断ログ(xcresult)の起動し直し**(`vscode-fleetest/src/monitorBridgeLogRotation.ts`・
  `Sources/fleetest/BridgeLogRotationSampler.swift`・判定は `FTCore.BridgeLogRotation`): 生きたランナーの束は
  guarded で消せない(docs/results-json.md §保持容量)ので、**束が大きいブリッジを起動し直して孤児にし、
  既存の掃除に消させる**。原因は XCTest がランナー経由のスクショ1回ごとに約 5KB の内部ログを書くこと
  (`getting screen bounds` ×6 ほか。xctestrun の `OS_ACTIVITY_DT_MODE` を外しても `-XCTEmitOSLogs NO` でも
  減らないと実測で確認)で、実機の画面を配信し続けると 1 台 1 日約 2.6GB。
  - 観測: `api monitor` が **10 分おきに裏で**束を測り(周期は控えを読むだけ)、判定を
    `RetentionSweeper.clean` の notice と同じ条件(`RetentionSweep.plan` の `overCapAfterGuards`)で行い、
    guarded で最大の束のデバイスを `monitorBridgeLogRotation` 行で出す(変わったときだけ・候補無しは
    `"candidate":null`)。**この機械のデバイスだけ**(`RemoteMonitorFanout` は中継しない)。
    **`sweepAfterRun` が false なら候補を出さない**(利用者の止めるスイッチを共有する)。
    控えを返すたびに束の実在を確かめる(起動し直し後に古いポートを別のデバイスが使っても、そのデバイスを指さない)
  - 撃つ: 拡張が lifecycle ジョブ `restartBridge` → `api restart-bridge --name` を積む。run 実行中・
    待ち行列 busy・同じデバイスに 20 分以内に撃った(計測 2 周期ぶん)ときは撃たない。`machine` 付きは無視
  - `api restart-bridge`: run・MCP・ライブ操作の印があれば断る(`DeviceBooter.deviceInUseRefusal`)→
    **XCUITest ランナーだけ**を止める(`BridgeLauncher.stopRunnersMatching`。in-app ブリッジと注入した
    アプリは起こし直さない)→ 供給し直す。デバイス本体は触らない。古い束は同じポートなら起動時の掃除、
    別ポートなら `sweepOrphanResultBundles` が消す
  - 陽性対照(2026-09-27): 上限を最小(1GB)にし、生きた束へ 1.1GB の実データを足す → モニターが候補を出す →
    `api restart-bridge` が 16.6 秒で起動し直し、1.1GB の束が消え、in-app ブリッジは起動し直されなかった
  **実機は見ない**(供給に数分かかり枠を専有する)。健全性の watchdog(`monitorHealthWatchdog`)は
  まだ手元だけ(Wi-Fi 修復に相当する `api` の口が無く、手元の adb を直接叩くため)
- **残骸掃除**: `BridgeLauncher.startDetached` は起動前に同一ポートの xctestrun
  (`FleetestRunner-<port>.xctestrun`)を掴む旧 xcodebuild を kill する(他ポートはパス不一致で不干渉)

### DS-12.3 実測(M1 Max、詳細は PT-4.1)

- Android エミュレータは headless(-no-window)だと hw.gpu.mode=auto が SwiftShader(CPU描画)へ
  落ちるため **DeviceBooter は `-gpu host` で起動**(モーション時 qemu 約3コア→約1/3)。
  gfxstream+host Vulkan(MoltenVK)は `-gpu host` の時点で既定有効で、HWUI の Vulkan 化は
  効果なし(DS-6 不採用表)
- **ただし `-gpu host` が画面凍結(白フレーム固着)の根本原因**(headless + macOS 27 / emulator
  36.5.10。切り分け実測 2026-07-17。PT-7 参照)。swiftshader_indirect は免疫だが
  CPU 約3倍。そこで **基本 host・凍結が軽量修復で治らない個体だけ per-device で swiftshader_indirect
  再起動**にフォールバックする(DS-12.4 の watchdog ラダー)。`bootOne(gpuMode:)`→`startEmulator`、
  CLI は `fleetest api start-device --gpu swiftshader_indirect`。swangle_indirect は screencap 0B で不採用
- H.264 化で webview Renderer 30-65%(瞬時)→ 8.4%(65秒平均)、helper モーション時
  Android 5.2%→1.0%。monitor は suppressFrames で常時 11%→約2%

### DS-12.4 ゲスト OS 健全性の検知と自己修復

adb 接続は生きているがゲスト側が不健全(Wi-Fi 無効・ゲスト時計の凍結)なまま同じシナリオが
落ち続けた実害(フリート起動直後から2時間)への対策。ブリッジ死(12.2)とは検知面が別:
デバイスは connected のままなので、ゲスト OS を直接プローブする。

- **プローブ**(`Sources/FTAndroid/AndroidHealthProbe.swift`): monitor が connected な Android
  エミュレータ(`emulator-*` のみ。実機は Wi-Fi オフが意図的でありうるため対象外)へ 30 秒間隔で
  `cmd wifi status` / `date +%s` / `screencap -p`(PNG サイズで一様フレーム=描画ウェッジを検出。
  a11y は生きたまま画面だけ死ぬ症状で、guest 再起動でのみ回復)を実行。2回連続観測で確定・
  正常1回で即クリア(AndroidHealthDebounce)。確定異常は monitorDevices の
  `health: ["wifi-disabled"|"clock-skew"|"blank-screen"|"metal-errors"]` で拡張へ伝搬
  (契約は `vscode-fleetest/src/monitorDeviceModel.ts` 冒頭。拡張は未知の種別も再起動修復に倒す)。
  **`metal-errors` だけは拡張側で落とす**(表示も修復もしない。`monitorHealthWatchdog` の
  actionable フィルタ。ホスト GPU ドライバ由来で全機に同時に出る背景現象で個体の異常を表さない=
  タイルに出すのが不適切。フリート全数検証の実データは PT-7。
  Swift 側は記録・分析のため載せ続ける契約のまま)
- **watchdog**(`vscode-fleetest/src/monitorHealthWatchdog.ts`): 異常種別ごとに修復ラダーが分かれる。
  ライフサイクルキュー busy 中は保留(起動/停止処理との競合回避)。テスト実行中は保留しない
  (ユーザー決定 2026-07-17: 凍結は実行完了を待たず即修復。実行中の該当デバイスは再起動で落ちるが
  凍結済みで証跡が撮れないため許容)。設定 `fleetest.autoRepairDeviceHealth` は
  **既定 OFF**(autoRepairBridge と異なり、Wi-Fi をわざと切ったテスト環境を勝手に上書きしないため)。
  検出通知(タイルの警告バッジ)は設定 OFF でも出す。
  - **wifi-disabled 単独**: まず `adb shell cmd wifi set-wifi-enabled enabled`(軽量修復、クールダウン 120s)。
  - **blank-screen(画面凍結)**: **画面リセット(`runDisplayRepair`=sleep/wake keyevent ~4s。
    固着した合成バッファの無効化→再合成で直す最軽量修復。readback が効かない個体にも効く。
    クールダウン 60s)**→ ストリームヘルパー再起動(`restartStream`。読み出し再開で一時回復。
    クールダウン 120s)→ 効かなければ **CPU 描画へフォールバック**(`forceCpuRender`→`MonitorDeviceOps`
    が個別の `start-device` に `--gpu swiftshader_indirect` を付与。セッション中維持。bulk `start-all-devices` も
    `--cpu-render` で維持)→ それでも駄目なら failed。
    **host 再起動は挟まない**(実測で host 再起動は治らず再凍結=無駄。DS-12.3・PT-7)。
    run 経路(CLI/api run)は watchdog と独立に、実行前トリアージ「blank 検出→sleep/wake 修復→
    不発なら guest reboot を同期発行しブート完了待ち→再判定して**本 run で使う**(まだ blank の
    個体だけ除外)」と実行中修復を持つ(`ProfileWorkerFactory.excludeOrRepairBlankScreenWorkers` /
    `AndroidHealthProbe.observeBlankAndRepair`。修復/除外は run.json の
    blankRepairs/blankExclusions に記録される。guest reboot は emulator プロセスを再起動しないので
    serial は変わらず、ワーカーの再構築は不要)。
    **同じ点検の続きで、ホストへの経路の無い Emulator を停止と起動で戻す**(2026-10-19。
    `ProfileWorkerFactory.restartEmulatorsWithoutNetwork`・判定は `AndroidHealthProbe.hostRoute` = `ip route get 10.0.2.2` の
    終了コード 0/2。それ以外は判定しない)。負荷の高い時間帯に起動した Emulator は擬似モデムに繋がれず(`RADIO_NOT_AVAILABLE`)、
    モバイル回線も Wi-Fi も上がらないまま起動を終える = アプリはサーバーへ1件も届かずログイン等で赤になる。機内モード・Wi-Fi の
    切り替え・ゲストの再起動では戻らず、停止と起動で戻る(実測 2 台)。撃つ前に持ち主を確かめ(`deviceInUseRefusal`)、
    戻らなかった・serial が変わった・他のセッションが使っている台は除外し、理由を `workerAnomalies` の `reason` に書く。実機は見ない。
  - **clock-skew 等その他**: down→up の host 再起動(`enqueueRestart`。クールダウン 5分・2回失敗で諦め)。
  - **無限ループ対策**: 「異常なし1回」ではエピソード(試行回数の記憶)を破棄せず、健全が 10 分持続して
    初めて破棄する(ブート直後の一時健全で restartAttempts が毎回リセットされ MAX 到達しなかった実害対策)。
- **証跡の白フレーム無効化**(`BlankFrameDetector`=FTCore、PNG デコードして一様性で判定。サイズ判定と違い
  縮小スクショでも誤検知しない): テスト実行の失敗時証跡スクショ(`FTRuntime.handleFailure`、Android のみ)が
  白フレームなら最大3回撮り直し、それでも白ければ `evidenceBlank` を立ててレポートに警告表示。実行前は
  恒常白のデバイスをワーカーからディスパッチ除外(`ProfileRunner`、短時間の連続 probe でフラップと区別)
- **ブロードキャスト実行**(`fleetest run --broadcast`): 選んだシナリオを実行プロファイルの
  **各デバイスで1回ずつ**回す(warmup 向け)。**差し替えるのは分配だけ** —— `ScenarioDispatch.broadcast` で `RunOrchestrator.run`
  が platform 別の共有キューの代わりに**レーン(デバイス論理名)別のキュー**を作り(`BroadcastPlan` =
  純粋関数。platform 未指定のシナリオは全レーンへ・明示は同 platform のレーンだけ)、ワーカーは
  `BroadcastPlan.laneKey(of:)`(= `logicalName`。復帰でポートが変わっても同じデバイスは同じキューに戻る)で
  自分のキューを取る。供給・インストール・フック(run で1回)・スタッガ・CPU 門・復帰・lease・録画・
  レポートは同じ経路。`ProfileRunner` は **`limitingDevices` を通さない**(各デバイスで回すのが目的)。
  `ScenarioRunItem` は `lane` を持ち **URL に `?lane=` を付けて (シナリオ × デバイス) を別キー**にする
  (表示バッファ・稼働集計・requeue 回数は URL で持つ。`lastPathComponent` は ID のまま)。
  結果はデバイスごとに `worker` で区別(同じ ID が `~N` 連番で並ぶ)。**`RunRecorder.discardLast` は worker を
  名指しする**(同じ ID を別のデバイスが同時に書いているので、「この ID の最新」では別のデバイスの記録を消す。
  欠番は詰めない)。参加しなかったデバイスのぶんは「device … never joined the run」、離脱して復帰できなかった
  デバイスのぶんは「… dropped out and could not be revived」で失敗として残す(準備できなかったデバイスが緑に紛れない)。
  ホスト混在プロファイルは `DeviceMachineRunner` が**分割せず全ホストへ全件**を渡し、`--runner` は
  `RemoteRunArgs.build` が中継する。`--fleet` とは併用不可(中継していないので黙って分配になる)。
  `api run`(拡張)には載せていない(Test Explorer は flowURL = シナリオ1項目の前提)
- **実行中の凍結による結果取り消し+別デバイス再実行**(`RunOrchestrator.runWorker`):
  シナリオが失敗した直後にそのワーカーの Android デバイスを `isDeviceFrozen`(注入プローブ=
  `AndroidHealthProbe.isPersistentlyBlank`。FTCore→FTAndroid は循環のため呼び出し側=fleetest ターゲットが注入。
  未注入時は常に false)で確認し、凍結していれば `RunRecorder.discardLast` で直前の記録を取り消し、
  `ScenarioQueue.requeue`(上限 `MAX_FREEZE_RETRIES`=1。item を末尾へ戻す)で別ワーカーへ振り直す。
  凍結ワーカーは `.workerFailed` を出してその実行から離脱する(残りの正常機で消化)。上限到達時は
  `recordSkipped`+`failed` として確定。再実行の通知は新イベントを足さず既存の `.step`(synthetic)で行う。
  monitor 側の自動 CPU フォールバック(DS-12.4)とは別プロセス・別機構(こちらは実行結果の振り直し)
  - **凍結の検知契機は2つ**: (1) **スクショ時の明示シグナル**(即時・確実)= サブプロセスが白フレームを
    確定した瞬間(`StepExecutor` の screenMatches 画面検証、および失敗時証跡の `evidenceBlank` 確定)に
    `FTDriveCore.markDeviceFrozen` が `scenarioAborted` を立ててシナリオを打ち切り、NDJSON イベント
    `deviceFrozen`(文字列 kind。`ScenarioHost.run`/`ScenarioRunnerMain`/`ApiRunCommand`/MCP は無改修で素通し)を
    emit。ホストの `ScenarioRunner.runOne` がこれを検知して戻り値 `ScenarioOutcome.frozen` を返し、事後
    プローブ無しで即振り直す。白フレームの screenMatches は `.skipped` にしない(検証されず継続すると結果汚染)。(2) **失敗後の事後プローブ**(上記の `isDeviceFrozen`)= タイムアウト/ハング等で
    `deviceFrozen` を出さずに死んだ凍結を拾う保険。runOne は `.passed`/`.failed`/`.frozen` を返し、
    runWorker は `.frozen` は即・`.failed` はプローブ確認で振り分ける。事後プローブは
    `AndroidHealthProbe.isBlankObserved`(窓内=既定 4×2s に一度でも blank で凍結扱い)を使う —
    `isPersistentlyBlank`(非 blank で即健全)だと約25秒周期のフラッピングの回復側を引いて見逃す
    (実測。isPersistentlyBlank は実行前の恒常白除外用)
  - **iOS はブリッジ接続不能も振り分け対象**: ブリッジのウェッジ(シナリオ途中から全ステップ
    「ドライバに接続できません」)は Android のプローブでは拾えず通常失敗になっていた(実測: 1ワーカーで
    2件連鎖)。`.failed` 時に `/status` を2回(2s 間隔)確認し、両方失敗なら「ブリッジ接続不能」として
    同じ discard+requeue+離脱へ。復帰(reviveWorker)は BridgeProvisioner.provision を通るため、
    ウェッジしたブリッジの再供給も試みられる
  - **Android は iOS ブリッジ供給の完了を待たず開始**(`RunOrchestrator.lateWorkers`):
    iOS ブリッジ供給(壊れたブリッジの置き換え=数十秒)を全ワーカーが待つと、開始→最初のシナリオが
    10s→81s に悪化する(実測)。そこで
    ProfileWorkerFactory を buildAndroidWorkers(数秒)/buildIOSWorkers(供給込み)に分割し、
    Android を初期ワーカーとして即時開始、iOS は lateWorkers(platforms 宣言+provider)として
    供給完了後に task group へ合流する(group スコープ内の await は既存子タスクを止めない)。
    workersReady はレーン構成の**全置換**(runLaneModel.applyWorkers)のため1回だけ・全ワーカー分を
    宣言する(iOS は供給前でも id="ios:論理名" が確定。detail「ブリッジ供給中...」のプレースホルダ)。
    label→id 変換は WorkerIDMap(NSLock)で iOS 合流時に merge。CLI(ProfileRunner)も同構成。
    **供給の手順(両レーンの中身)は `ProfileSupplyLanes` の1箇所**で、run・api run の並列経路・--debug の逐次経路が
    同じ関数を呼ぶ(2経路に別々に持つと片方だけ WebView の更新・実機の画面の観測・Android のホームが抜ける。
    `ProfileSupplyLanesWiringTests`)。**全滅は異常として run を止める**(ユーザー決定 2026-10-20): Android のレーンは
    実行前のチェックで全台が除外されたら投げる(run の開始前)/ iOS は**1台も合流しなかった時点で** RunOrchestrator が
    配布を止める —— 走っているシナリオは最後まで走らせ、残りは理由つきの未実行(`noWorker`)、run.json は `abortReason`
    (中断ではないので `interrupted` は立てない)。iOS のシナリオが待っていなければ止めない。一部の台だけが落ちたときは
    残りの台で続ける
  - **供給フェーズの進行は NDJSON の `log` にも流す**: 供給(デバイス起動・インストール・
    凍結 triage)の行を stderr だけに出すと、「デバイスモニター」タブが無音になる。
    **デバイスが起動していない状態からの run は供給が長い**(実測 2026-09-09: 手元 Android 8台で
    クリック→最初のシナリオまで 3分39秒。うち起動プロセスの投入だけで 1分41秒 ——
    `AndroidLaneRecovery` は凍結対策で**1台ずつ直列**に起こす)ので、タイルが1台ずつ点いていく様子が
    「テストが1本ずつ走っている」ように見える(**実行そのものは並列**。同 run の8レーンは13秒以内に
    出揃っている)。`ApiRunCommand.logSupply` が stderr と NDJSON の両方へ出し、`SupplyLogRelay` が
    **runStarted より前の行を貯めて runStarted の直後に流す**(拡張のレーン状態は NDJSON の runStarted で
    clear されるため。対向: vscode-fleetest/src/runLaneModel.ts)。デバイスごとの進行は `(i/N)` 付きで
    開始と結果の2行。worker を持たないので表示先は「全体」レーン(workersReady で置き換わる)。
    **複数機械の実行では中継側が機械名を埋める**(`ApiRunMachineFanout.machineStampedLog` が
    worker を持たない log の message へ `[<machine>] ` を付ける。手元の子も `[local]` と名乗る)——
    埋めないと3機ぶんの「Reviving 8 dead lane(s)」が混ざってどの機械のものか読めない。
    **全体レーン(`__overall__`)は workersReady で消さない**(レーン構成の全置換が worker を持たない
    受け皿ごと消すと、最初のワーカー合流で供給の進行がタブから丸ごと消える —— 複数マシンでは
    合流が機械ごとに来るので最後には何も残らない)。
    ホスト(`runLaneModel.applyWorkers`)と webview(`laneLog.configureLanes`)の**両方**に
    同じ除外がある(`syncLanesToDevices` の除外と対)。
    **実行ログに出すのは選択したデバイスだけ**(DS-12.6)なので、worker を持たない log は見出しの状況行
    (`#lanes-run-status`)にも出す(LaneAction の `status`)—— 18台選択のまま実行すると、
    レーン欄には拡大表示だけが並び進行がどこにも出ないため。
    **全体レーンは選択に関わらず実行ログビューに残す**(DS-12.6)ので、供給の進行はこの行と
    実行ログビューの両方で読める
  - **「テストを実行」ボタンは先に「デバイスを全て起動」と同じ処理を通す**(ユーザー決定 2026-09-09。
    `monitorPanel.startTestRunAfterDevicesUp`): タイルの「起動待機」バッジは拡張の
    ライフサイクルキュー(`opBusy` / `bulkOpActive`)からしか出ないので、run 内の供給
    (`AndroidLaneRecovery`)に任せるとボタンから起動したときだけ無表示になる。
    一括起動の完了は `MonitorDeviceOps.whenLifecycleQueueIdle` で待ってから run を投げる。
    **run 内の供給は消さない**(Test Explorer 直・CLI・リモート機にはモニターが居ない。
    冪等なので起動済みなら素通りする)。**この待ちの間の「テストを中断」は run ではなく
    一括起動を止める**(まだ run が無い)。一括起動が一部失敗しても run へは進む
    (残りは run 内の供給と部分失敗の許容が面倒を見る)。**この段では「デバイスの起動を中断」を
    出さない**(ユーザー指示 2026-09-09)—— 実行中はツールバーを畳むので押せず、押せない
    文言だけが出るため。中断の口は「テストを中断」1つ(`refreshBulkButtons` の `upCancelMode` は
    `testRunActive` の間 false)
  - **run 開始時の home は in-app ブリッジを持つデバイスには撃たない**(実測 2026-09-09。
    `ProfileWorkerFactory.homeOnStartPlan`): home は黒画面の予防措置。in-app ブリッジ宛には `/home` のルートが無い。
    XCUITest ブリッジ側へ回して撃つと**退行する** —— home はアプリを背面へ送り、in-app ブリッジは
    **そのアプリの中に居る**ので無応答になり、供給が壊れたブリッジと見て停止・張り直しに入って
    **3機で13台がワーカーから脱落**する(結果は緑のままだが手元の run が 50s → 136s)。
    よって inapp-boost モードは対象外にし、撃てるデバイス(xcuitest モード・Android)だけ `systemUIClient` 経由で XCUITest ブリッジへ回す。
    **判定はモードで行う**(inapp-boost モードは xcuiPort も持つので、xcuiPort の有無で決めると同じ穴に落ちる)。
    宛先の決定自体は `systemUIClient` の1箇所で、残存アラートの警告(`warnOnResidualSystemAlerts`)と共有。
    **inapp-boost モードで黒画面の予防を復活させるなら「home → アプリを再前面化」が要る**(未検証。
    既定の inapp-boost モードでは予防が効かないが、その実害の報告は無い)
  - **一括起動/停止の最中はブリッジ無応答を数えない**(`monitorBridgeWatchdog`): 供給中のデバイス
    (10 秒後に ready)へ「booted が5回連続したためブリッジ無応答とみなします」を出さない。
    **検知は誤検知0が条件**なので `inRun` と同じく streak ごと 0 に戻す
  - **MCP・ライブ操作の使用中もブリッジ無応答を数えない**(`inSession` = モニターが `MCPDeviceLease.holderPID` を読んで
    デバイスイベントに載せる): XCUITest のランナーは操作の処理中に /status へ答えないので booted に見える。使用中の端末は
    start-device の引き取り(`.adopt`)が止めずに断るので、数えると誤警告と失敗する修復だけが出る(MN-84.8)
  - **ブリッジの定着待ちはデバイスごとに並列**(実測 2026-09-10。`awaitDurableAndroidBridges`):
    **直列にする理由は起こす側にしかない** —— `AndroidLaneRecovery.bootMissingDevices` が1台ずつ
    なのは「複数台の同時ブート描画が画面凍結の契機」だから。定着待ちは `/status` を叩くだけで
    描画を伴わないのに直列で、1台あたり最低 8 秒の dwell を台数ぶん積んでいた
    (実測 2026-09-09: 手元 Android 8台で run 開始→最初のシナリオが 3分41秒。起動の投入 105 秒を
    除いた 116 秒がこの待ち + install/triage)。並列化後の実測(同じ8台・冷起動)は
    **起動 134 秒 → ワーカー確定 179 秒 = 待ちは 45 秒**(8台とも同じ秒に待ち始めている)。
    **和ではなく最大**になるのが並列化の形。テストは待ちの差し込み口で重なりを見る
    (`DurableBridgeWaitConcurrencyTests`。直列に戻すと落ちる)
  - **配信 helper は「アタッチ中」も生存を知らせる**(`fleetest-simstream`):
    消費側(`vscode-fleetest/src/deviceStream.ts`)は 15 秒 1 バイトも来なければ helper が固まったと
    見て kill→再起動する。静止画面は 3 秒ごとの keepalive ping で埋めてあったが、**CoreSimulator への
    アタッチ**(SimServiceContext / ioPorts / setPowerState)は `dispatch_main` より前の同期処理で、
    その窓には ping が1本も無かった —— 起動ストームの最中に健全な helper が繰り返し殺されていた
    (M1Ultra の6台で観測)。アタッチ前から 3 秒ごとに ping を流し、完了したら止める(以後は既存の
    keepalive)。**ping は「生きている」だけ**でフレームの証拠にはしない(消費側が区別する)。
    stdout はレコード単位でロックする(ping と gQueue のフレームが交錯するとパースが壊れる)。
    **アタッチが 5 秒を超えたときだけ実測を stderr に残す**(次に遅かったときの根拠を作る)。
    v1(mjpeg)には ping レコードが無いので h264 のときだけ。検証は `SimStreamAttachPingTests`
    (実在しない UDID を渡す = デバイス不要で「アタッチ前に ping が出る」を固定)。
    **リモートのデバイスには手前にもう1段ある**(実測 2026-09-09): 拡張は
    `remote exec <host> -- api device-stream` を起こし、そのコマンドが向こうで宛先を解決してから
    ヘルパーへ exec する。解決(`DeviceRosterLoad` + `ApiMonitorCommand.determineStates`)は
    起動ストームの最中に十数秒かかり、**ヘルパーが起きる前に 15 秒の期限が切れていた**
    (ヘルパー側の ping では届かない —— 実測: wedge の 19 秒後にヘルパーが
    「attaching took 15.3s」を出した)。同じ ping を解決の間も流す(`StreamResolvePing`)
  - **録画の client を SIGINT 以外で殺さない**(実測 2026-09-09。`IOSSimulatorVideoRecorder`):
    `simctl io <udid> recordVideo` を SIGKILL/SIGTERM で殺すと**端末側の録画セッションが握られたまま
    残り**、そのデバイスは**再起動するまで**録画できない(以後 "Host recording …" / "A recording is already in progress" で
    全部落ちる)。ツールは猶予切れで SIGKILL しており、**自分で作ったセッションを自分で
    「残っている」と警告する自作自演**になっていた(実験: 該当デバイスは数分後も busy、
    `api stop-device` で解け、再起動後は 120KB の録画が撮れた)。停止は SIGINT のみ・止まらない
    個体は放置(`RecordingKillDisciplineTests` がソース走査で固定)。**stale の掃除も `pkill -INT`**。
    失敗の理由は simctl の stderr から採り、busy / 空 / 止まらない / 起こせない を撃ち分ける
    (`SmokeFailure`。全部を「セッションが残っている」と断定しない)。
    **空振りは一過性なので再試行する**(実測 2026-09-10: M1Ultra の6台が run 開始直後に同時に
    空になったが、数分後には同じデバイスで 1 秒 66KB が撮れ、並列6本でも空いていれば全部成功した)——
    予算は `spawnNextPart` と同じ(`startAttempts` / `startRetryBackoffSeconds` を共有。同じ
    一過性を2つの数字で持たない)。**busy は再試行しない**(端末側のセッションはシャットダウン
    以外では解けない)。仕分けは `isTransient` の1箇所で、テストが直接叩く
  - **recordVideo は "Recording started" より前の SIGINT を無視する**(実測 2026-10-18: 起動から 0.05・0.2 秒の SIGINT では
    止まらず、0.5 秒以降は止まった)。止める経路はすべて `IOSSimulatorVideoRecorder.interruptRecorder` を通し、撮り始めるまで
    `interruptRepeatSeconds`(0.2 秒)ごとに送り直し、撮り始めたら1回だけ送る(撮り始めた後の client は SIGINT から数 ms で終わる)。
    通すのは試し撮り・本番の開始が確かめられなかったとき・`HostRecordingProbe` の3つ。試し撮りは撮り始めを待ってから 1 秒撮る
    (上限は本番と同じ `startConfirmSeconds` 10 秒)。**止まらなかった試し撮り(`didNotStop`)は再試行しない** —— 残った録画が
    セッションを握るので撮り直しは必ず "A recording is already in progress" で断られる。開始前の掃除(`killStaleRecording`)は
    残りの録画が止まるまで送り直して待つ(上限 15 秒)。止める期限を過ぎてもまだ動いている client は見張り(`handOff` →
    `fleetest api recorder-watch` = `FTCore.RecorderWatch`)へ渡す。見張りは **fleetest より長生きする別プロセス**(プロセスの中のタスクだと、
    fleetest が先に終わった後で撮り始めた client を誰も止めない)で、`FT_PARENT_PID` を渡さず `InterruptRelay` にも載せない。
    **身元は spawn の直後にだけ採る**(pid + 起動時刻 µs = `RecorderWatch.Target.of`。handOff で採り直すと、終わって回収された pid が別の
    プロセスに使い回された形を追う)。見張りの観測は 3 値(`ProcessLiveness.observe`: 居ない / 生きている + 起動時刻 / 読めない)で、
    生きていて起動時刻が一致する間だけ SIGINT を送り直し、読めない間は送らず・消さず・待ち、居なくなったら最終名と `.sb-*`(simctl の一時
    ファイル)を消して終わる。client の stderr のパイプは見張りが読み継ぐ(元の読み手が消えると、遅れて撮り始めた client が stderr へ書いた
    瞬間に SIGPIPE で死に、SIGINT 以外の終わり方になる。読み捨ては行に分けない = 改行の無い出力を保持しない)。**ファイルの所有**: 見張りへ
    渡したら呼び手は消さない(先に消しても simctl は一時ファイルから最終名へ rename するので後から現れる)。見張りを起こせなかったときは
    呼び手が今あるぶんを消し、「止める者がいない・ファイルは残りうる」と事実だけを言う(`handOffNotice`)。**出力名は run の中で一意**
    (`outputURL`: `<stem>~smoke.mov` / `<stem>.mov` / `<stem>~part<N>.mov`。`~` は `sanitizedFileName` が出さない。coordinator の重複判定の鍵は
    `RecordingIndexIO.collisionKey` = 大小文字・正規化を無視)。期限は壁時計でなく単調時計(`clock`)で測る。経緯は MN-87
  - **モニターの撮影失敗は事実だけ言う**: `simctl io screenshot` の期限切れに
    「a test run is probably driving it」と断定しない(run の2分前の一括起動中にも起きる)。原因は候補として並べる(run / 一括起動 / 刺さった simctl)
  - **ワーカーの表示名は machine 込み**(`vscode-fleetest/src/runLaneModel.ts` の
    `workerDisplayLabel`): worker 名だけでは、同名のデバイスが別の機械にも居る実行
    (例: performance-android は M1Max と M1Ultra の両方に "Pixel 10…-01"〜"-04")で**どちらの機械の行か判別できない**。レーン見出しの hover と
    同じ規則(`machine/name`)を1箇所に置いて両方から呼ぶ
  - **iOS ブリッジの実行前プレフライトは不採用**(ユーザー決定 2026-07-18): ウェッジ機で
    `scenarioTimeout`(当時の既定 90s)を失うのを実行前の status 確認で回避する試み。①「item を取ってから
    5s×2 判定→振り直し+離脱」は 10台同時の AX スパイク(一過性の遅さ)で9台一斉離脱・freeze-retry
    上限到達の失敗まで発生、②「取る前に 2s 即断・無応答中は取らずに回復待ち(60s)」も負荷時の
    誤判定で品質が安定せず撤去。**ウェッジの検知は失敗後の事後チェック(bridgeUnreachable/
    deviceUnreachable/deviceFrozen → 振り直し)のみで行う**(ウェッジ機の1件は 90s を失うが確実)。
    再提案しないこと
  - **withDeadline は「先着で確定・遅い方を待たない」レースにする**: `withTaskGroup`+`cancelAll` にしてはならない。
    構造化並行はスコープ終端で全子タスクの完了を待つため、op(ウェッジ機への `status`=URLSession)が
    キャンセルに即応しないと期限側が勝っても遅い方を待ち続け、**run 全体が5分以上アイドル固着する**
    (全スレッドパーク・子プロセスもソケットも無いデッドロック)。
    `withCheckedContinuation`+`DeadlineGuard`(継続を一度だけ resume)で、先に終わった方で即確定し op が
    ハングしても放置(URLSession の timeout で自然消滅)する。これで死活確認・プレフライト・warmup が
    確実に期限内で返る
  - **死活確認系の await は必ず短期限**(`RunOrchestrator.withDeadline`): ウェッジしたブリッジは
    **接続を受けたまま応答しない**ため、BridgeClient の既定 120s/リクエストに任せると status 確認・ウォームアップ・
    復帰 provision が 120s×N 直列に積み重なり、全シナリオ記録済みなのに run が数分〜十数分終わらない
    (実測: 8141/8142 への ESTABLISHED 固着で Test Explorer が 69/75 のまま停止)。対策: 死活確認は
    withDeadline(タスクレース+cancelAll。URLSession await はキャンセルで解ける)で bridgeUnreachable=5s、
    warmup status=10s・snapshot=15s、復帰 provision(ProfileWorkerFactory.buildWorker)=60s に制限
  - **振り直しの監査記録(freezeRetries)**: 成功した振り直しはシナリオ記録に痕跡を残さない
    (discard 後に別ワーカーの pass で上書き)ため、`RunSummary.freezeRetries` に「シナリオ: 理由
    (元ワーカー、試行 n/1 or 上限到達)」を集約し、run.json の `freezeRetries` に永続化+CLI 末尾に表示
  - **ワーカー・サーキットブレーカ**: 凍結/消失の個別プローブに当てはまらない不良(ブリッジの
    ウェッジ・ANR 連発等)で死んだワーカーへシナリオを投げ続ける事故を防ぐ一般化。同一ワーカーで通常失敗が
    `WORKER_FAILURE_CIRCUIT_THRESHOLD`(=3)連続したら原因不明でも離脱+現シナリオ振り直し(`.passed` で
    カウンタリセット)。凍結/消失判定はこのブレーカの前段(既知の即離脱)、ブレーカは後段の保険。
    **離脱には証拠が要る**(2026-08-24。`FTCore.WorkerCircuitBreaker`): 離脱するのは**この streak の間に
    別のレーンが1本でも通ったとき**だけ。誰も通っていない = 全レーンが同時に落ちている = デバイスではなく run の
    問題なので、レーンを残して走り続ける(`workerAnomalies` に `circuitHeld` を streak ごとに1件・
    ログに1行)。**連続失敗は run をまたいで引き継ぐ**(2026-10-01。`FTCore.LaneFailureStreakStore` =
    `.fleetest/lane-streak-<platform:論理名>.json`。1台が run あたり閾値未満しか受け取らず毎 run 赤を出し続けた実測)。
    引き継いだ streak の開始通過数はこの run の開始(0)とみなす。通ったら消す(離脱では消さない = 1 run に数件しか受け取らない不調機を次の run の最初の失敗で外す)・中断の失敗は書かない。
    受け手報告(2026-08-23): 外部サイト停止の時間帯に condition の not-found で全レーンが
    連続失敗 → 全部離脱 → 再投入 → revive 上限 → 39 本中 34 本失敗・多数が `no usable workers` で未実行。
    **condition 段階の失敗を数えない案は却下**(不良なデバイスは launch / 最初のステップ = condition で落ちる
    ので、守るべき形を見なくなる)。**閾値のプロファイル化だけも却下**(障害の時間帯は予測できないので
    常時高く = 保護を捨てる)。単レーンの run は連続失敗だけでは離脱しなくなる(プローブは別に効く)。
    陽性対照: 全部落ちる6本を2レーンで回し、両レーンとも held・離脱なし・6本すべて実行を確認(2026-08-24)
  - **凍結だけでなく「実行中のデバイス消失」も振り分け対象**: watchdog の実行中再起動や
    エミュレータのクラッシュで adb からデバイスが消える(`device offline`→`not found`)と、runner の
    固定ワーカーは以降のシナリオを全部即失敗させる(実測: 1台消失で11件連鎖失敗)。これを拾うため
    `.failed` 時に `isDeviceUnreachable`(注入=`AndroidDeviceCatalog.connectedSerials` に serial が居ないか。
    取得失敗時は誤振り分け回避で false)を **凍結プローブより先に**確認し、消失していれば同じ
    discard+requeue+離脱へ流す(理由表示「デバイス消失(offline/未検出)」)。`isDeviceFrozen`/`isDeviceUnreachable`
    の注入は `ProfileRunner`・`ApiRunCommand` の両並列経路で行う
- **劣化ワーカーの可視化**(`RunSummary.degradedWorkers`): 連鎖失敗を結果 JSON を掘らずに見えるようにする。RunOrchestrator が離脱(凍結/消失/連続失敗/接続不能)を `NoteCollector`(`degraded`)で集約し
  `RunSummary.degradedWorkers`(「label: 理由」)に載せる。`RunRecorder.finish` 経由で run.json の `degradedWorkers`
  に永続化(空は nil 省略)し、CLI(ProfileRunner の print / ApiRunCommand の logStderr)にも末尾サマリを出す
- **動的ワーカープール(復帰デバイスの再参加)**(`RunOrchestrator.superviseWorker`): 離脱したデバイスが
  監視側の再起動後に同一実行へ戻れるようにする。`runWorker` の戻り値を
  `WorkerExit{completed/retired}` にし、離脱時は `superviseWorker` が同じタスクスロット内で `reviveWorker`(注入クロージャ=
  fleetest 側が `ProfileWorkerFactory.buildWorker(forLogicalName:)` を `REVIVE_TIMEOUT`=90s・5s 間隔でポーリング+アプリ再導入)を
  呼び、復帰できたら新ワーカーでキュー消化を再開。`MAX_WORKER_REVIVES`=2・`ScenarioQueue.hasItems()` ガードで暴走と
  無駄な再供給を防ぐ。動的タスク追加はせず withTaskGroup 構造は不変(=安全)。FTCore→FTAndroid 循環回避のため
  再供給は注入(既存 isDeviceFrozen 等と同じ)。**注**: 実行開始時の接続失敗も retired 扱いのため、開始時から不在の
  デバイスは最大 MAX_WORKER_REVIVES×REVIVE_TIMEOUT 分ポーリングする(他ワーカーと並行なので run はブロックしない)
- **個別デバイス操作の2台並行**(`monitorDeviceLifecycle.ts` のスケジューラ): 右クリック起動/停止の
  ライフサイクルキューは「running(実行中)+jobs(FIFO 待機列)」のスケジューラ。
  device ジョブは `DEVICE_LIFECYCLE_MAX_CONCURRENT`(=2)まで同時実行、bulk/restartBatch は単独占有
  (内部で2台並行するため重ねると全体上限2を超える)。追い越しはしない(先頭が開始できない間は後続も
  待つ=投入順保証)。同一デバイス名のジョブは同時に実行しない(enqueueRestart の down→up ペアの逐次性)。
  並行 provision の失敗(waitUntilReady・ゾンビブリッジ)は ProvisionLock が供給を直列化して防ぐ。down 系の monitor pause は参照カウント化
  (`MonitorDeviceOps.monitorPauseDepth`。0→1 で pause、1→0 で resume)
- **デバイス再起動命令のロバスト化**(`MonitorDeviceOps.runDeviceOpAttempt`): 再起動(`enqueueRestart`
  の down→up)の **up が失敗するとデバイスが下がったまま放置**され、watchdog も offline を blank-screen として
  拾えず復旧しない。そこで up 失敗時は `deviceUpMaxRetries`(=2、`deviceUpRetryDelayMs`=3s 間隔)
  まで再試行してからキューを進める(down は再試行しない)。試行の終端は `settle(failed)` に集約し、
  ジョブ単位の `finishOnce` で `finishLifecycleQueueHead` を1回だけ呼ぶ
- **GPU 再起動と一括起動の単一キュー統合(`start-all-devices --restart`)**: 本質要件は
  「操作種別を問わず**同時2台まで**」(2台同時でホスト CPU がほぼ飽和するため)。ジョブを分けると
  ジョブ境界がバリアになり並行枠が遊ぶ(例: CPU 機3台の再起動の端数1台の間、未起動機が待つ)。
  そこで「全て起動」は `devicesUp{restartNames}` 1メッセージ→ bulk up 1ジョブ→
  `fleetest api start-all-devices --restart A --restart B` とし、**DeviceBooter.bootAll の単一キュー**に
  再起動アイテム(先頭。起動済みでもスキップせず shutdownOne→bootOne[host GPU])と通常ブート
  アイテム(restart 対象は除外=同一機の二重処理防止)を混載、既存の2ワーカーが消化する。
  NDJSON に `deviceStopping`(--restart 機の down 開始)を出す(検証: monitorModel.ts
  `isDevicesUpEvent`。受信時にそのデバイスだけ stopDeviceStreams)。cpuRenderNames の解除は
  `MonitorDeviceOps.bulkUpWithRestarts`。右クリック単発「GPUで再起動」は従来どおり
  `restartBatch` ジョブ(`fleetest api restart-devices`、`isDevicesRestartEvent`)を使う
- **一括 down の per-device 反映(`api stop-all-devices`)**: monitor は down 中 pause で
  状態スキャンごと止まる(→タイルが全台落ちてからまとめて「未起動」化する)。そこで **profile 指定の
  bulk down は NDJSON**(`deviceStopping`/`deviceFinished`。停止ロジックは `shutdownProfile` と同一)で出し、
  拡張は `deviceFinished` ごとにそのタイルだけ offline を先行反映(`deviceDownFinished` → resume 後に本物の
  state で上書き)。profile 無しの down は従来の全掃討 `devices down` のまま。詳細は PT-3.4
- **右クリックの既定メニュー(Cut/Copy/Paste)は拡張の全画面で出さない**(モニターの `main.js` が
  この規則を持つ。文字を打つ入力欄だけ残す)
- **「プロセス」タブ(常駐プロセス一覧・停止)**: **起動時は出さない** —— 設定タブ「ツール」の
  「プロセス」で設定タブの右に現れ、タブの × で隠す(`tabs.js` の `HIDDEN_AT_STARTUP`。復元もしない)。
  `ps` の fleetest 関連常駐を分類表示
  (`residentProcesses.ts`)。Android ブリッジは**エミュレータ内 `am instrument`= ホスト `ps` に出ない**ため
  `adb forward --list` から情報行を合成(ホスト PID 無し→PID 列は `(遅延起動)`/デバイス内 PID `(12345)`)。
  停止ボタンは「プロセスを終了してタブを閉じる」の1つ。掃討スコープは**ユーザー決定**で: ① iOS ブリッジ/ランナー・in-app・モニター/
  host-metrics/stream を停止し **iOS シミュレータと Android エミュ本体(qemu)は残す**(「デバイスモニター」タブの領域。
  `bridge down --all`=sim を残す/`bridge down --platform android`=qemu を残す/残余 SIGKILL は
  **この workspace 由来のみ**=workspaceRoot/binaryDir を含むコマンド。machine-wide 巻き込み回避)、
  ② **MCP サーバ(mcp)は表示・掃討とも対象外**(セッション保護)、③ 掃討後は**再起動せず
  モニターパネルを閉じる**(モニターを止めたままタブを開いておくと「デバイスモニター」タブが状態更新を失い
  凍結するため、「止める=閉じる」を1操作にする。再開はパネルを開き直すだけ)

- **監視と実行の協調(run-lease)**: monitor(watchdog)と run は別プロセスで無協調のため、
  watchdog が実行中デバイスに破壊的再起動をかけて run のワーカーを壊しうる。そこで run→monitor 方向の
  lease を置く(`Sources/FTBridgeClient/RunLease.swift`。`run-<key>.lease`)。`fleetest api run`
  (RunOrchestrator)がワーカー担当デバイス(serial/udid)へ 5s ハートビートで write、完了時と
  **離脱して復帰を諦めたとき**に remove(復帰の最中は保つ)。FTCore→FTBridgeClient は循環のため
  `writeRunLease`/`removeRunLease` クロージャ注入。記帳は `RunLeaseLedger` actor で、**打ち直しと削除を
  actor の中で直列化**する(外でキー一覧を取ってから書くと、消した直後に書き戻す)。供給フェーズの lease
  (`SupplyLeaseHolder`)は orchestrator が書き始めたキーを `handOff` で手放す —— 手放さないと、担当を
  終えたデバイスの lease を供給側のハートビートが run の最後まで書き戻し、モニターの配信が張られては畳まれる。`fleetest api monitor` が `RunLease.isFresh` を読んでデバイスイベントに `inRun` を載せ、拡張の
  `monitorHealthWatchdog` が **clock-skew 等の host 再起動分岐のみ inRun 中は保留**(restartAttempts/cooldown を
  動かさず見送る)。**blank-screen(CPU フォールバック再起動)と wifi 修復は inRun でも実行**(凍結はデータ汚染で
  即対応が要件、wifi は非破壊)。凍結で run のワーカーが壊れる分は DS-12.4 の requeue が回復する
- **MCP と run の協調(mcp-lease)**(2026-09-11・ユーザー決定「避けて、足りなければ警告して使う」):
  fleetest-mcp はデバイスを指すツールのたびに `.fleetest/mcp-<key>.lease`(`MCPDeviceLease`・鍵は run-lease と同じ)へ
  `<pid> <開始時刻>` を書く。**生死は pid + 開始時刻**(時間の閾値を置かない —— run は印を避けるだけで断らないので、
  使い終わった後も MCP が生きている間は残る印の損は「そのデバイスを避ける」に収まる。開始時刻まで見るのは pid の再利用で
  印を生き返らせないため)。MCP は stdin EOF で自分の印を消し、死んだ印は `sweepStaleLeases` が掃除する。
  run(`run` / `api run` の両方)は、ほかのデバイスで本数ぶん足りるなら印のあるデバイスを**外す**
  (`ResolvedProfile.limitingDevices(avoiding:)`)。
  本数が分からない(絞らない)ときも、ほかにデバイスがあれば外す。それでも使うデバイスは「MCP(pid N)が操作中。この run が奪う」と
  警告する(自分と親の pid の印は数えない・dry-run は見ない)。逆向きは MCP が run-lease のあるデバイスを触った応答
  (成功・失敗とも)の先頭で1行言う(断らない)。**差し替えドライバの MCP は印を置かない**。
  **ライブ操作(`api live serve`)も同じ印を書く**(中身は `<pid> <開始時刻> live <最後に操作した epoch ミリ秒。未操作は 0>`)。
  止める門・run の回避は見ているだけのライブ操作も「使用中」と数えるが、**対話セッション同士の警告は操作したときだけ** ——
  MCP はライブ操作が自分の前回の呼び出し以降に操作した回だけ「monitor's live control … operated this device」と言い、
  ライブ操作は自分が操作するコマンド(`refresh` / `frame` 以外)でだけ相手の MCP を言う。モニターでデバイスを選ぶだけで
  serve は印を書くので、区別しないと AIアシスタントの作業を見ているだけで「別の MCP セッションが駆動中」と警告する


### DS-12.4.1 デバイスのストレージ計測(ダッシュボード「デバイスの健全性」)

monitor が `monitorDevices[].storage`(`usedBytes` / `freeBytes` / `freeScope` / `measuredAt`)を配る。
契約は `Sources/fleetest/ApiMonitorEvents.swift` の `ApiMonitorDeviceInfo.storage`。

- **測る契機は利用者の「ストレージ使用を更新」ボタンだけ**(ユーザー決定): 拡張がモニターの stdin へ
  `{"cmd":"storageRefresh"}`(1回きりの指示)を送り、モニターはその周期に**動いている(connected / booted。
  ブリッジ未起動でも測れる)仮想デバイスを全台**積む。間隔・デバイスの起動し直し・モニターの起動では測らず、
  **run の有無でも止めない**(run で使っているデバイス・run が動いている Mac の iOS も測る)。実機は測らない(欄を省く)。
  **計測中のデバイスは積まない**(同じデバイスを二重に歩かない)。リモートの子へは fan-out が素通しする
  (1回きりの指示なので、張り直した子へは送り直さない)。測れなかった回は前回値を配り続ける(0 で埋めない)。
- **進捗**: 指示の id は拡張が押した時刻で振る。モニターはデバイスごとに `storageMeasuring` / `storageRefreshId`
  (最後に受け取った id)を返し、**1台終わるたびに `monitorStorage` を1行**出す(周期の一覧は 1 周 10 秒前後
  かかるので、待つと終わったデバイスがまとめて変わる)。fan-out は子の `monitorStorage` の id をマシン付きに直し、
  保持している子の一覧も同じ値へ書き換える。拡張は「自分の id 以上を受け取った かつ 測定中でない」デバイスを
  測り終えたと数え、**同じ id で一度測り終えたデバイスを、後から来た周期の一覧の「測定中」で巻き戻さない**
  (`keepFinishedStorage`。周期は状態を読んでから書き出すまでに約 2 秒かかり、その間に終わったデバイスを古いまま出す)。
- **Android**: `adb shell df /data`(`AndroidStorageProbe`)。`freeScope: "device"`。
- **iOS Simulator**: データディレクトリをプロセス内で**並列に歩いた割り当て済みの大きさ**(du -sk と同じ量。
  隠しファイル込み・リンクは辿らない)+ ホストのボリュームの空き(`SimulatorStorageProbe`。締切 300 秒)。
  `freeScope: "hostVolume"`(Simulator はホストのディスクを間借りしているので、空きはホスト側の値)。
  **並列度は CPU コア数の半分**(ユーザー決定)。律速はカーネルのメタデータ処理で、単一スレッドは API を変えても
  du と同じ(実測 12〜14 秒・`taskpolicy -b du` は 22〜28 秒)。4 スレッドで約 4 秒(データ 7.9GB / 16 万ファイル・
  load avg 11〜19)。各スレッドは I/O を throttle にし、background QoS にはしない(CPU も後回しになり所要が倍になる)。
- **配信の周期で計測を待たない**(`DeviceStorageSampler`): 周期は更新の要求があればデバイスを裏のキューへ積んで
  控えを読むだけ。計測は同期呼び出しなので Swift の協調スレッドにも載せない。iOS は 1 台ずつ
  (1 台の走査が既にコア数の半分のスレッドを使う)。
- **測れた値は `~/.fleetest/device-storage.json` に残し、monitor の起動時に読む**。メモリだけだと
  monitor が起動し直すたびに全台が空に戻り、更新ボタンを押すまで空のままになる。
  **読んだ値は更新ボタンで測り直すまで `carriedOver: true`** で配り、拡張の「デバイスの健全性」は灰色で出す
  (title に「前回値」)。

### DS-12.4.2 iOS Simulator の PosterBoard スナップショットキャッシュの掃除(起動前)

iOS 27 Simulator の PosterBoard(壁紙ギャラリー拡張)は、壁紙の版(`versions/<N>`)を作り直すたびに
`<data>/Library/Application Support/PRBPosterExtensionDataStore/…/versions/<N>/scratch/
SnapshotCache.cachedb`(壁紙プレビュー画像のキャッシュ。`Snapshot.pks/Resources/*.atx`)を作り、
**古い版の分を消さない**(Apple の公式な認知は確認できていない。実測 15 台で合計約 187GB・1台最大 30GB)。
束の `Info.plist` は作られた起動 ID(`BootSessionIdentifier`)を持つ(調べた1台で 67 起動ぶん・1起動あたり
約 140 束・平均 327MB)が、**起動のたびに増えるのではない** —— 消さずに再起動した回は束が増えず、版の数
(`SnapshotCache.cachedb` の個数)が 99 → 105 に増えた。ツールは起動を繰り返すので版が作り直される機会が多い。
**boot する直前に消す**ことで溜まる量を抑える。iOS 26 のデバイスは同じフォルダが約 100MB(起動回数が少ないデバイスなので、
iOS 26 で溜まらないとは言えない)・iOS 18 のデバイスにはこのキャッシュ自体が無い

- **起動の直前の入口は `FTBridgeClient.SimulatorBootCleanup.beforeBoot(udid:)`**(中身は
  `SimulatorPosterCache.purge` と DS-12.4.3 のログの整理と DS-12.4.4 のニュースのウィジェット)。simctl で boot / bootstatus -b
  (Shutdown なら boot する)を撃つ関数は、必ず同じ関数の中でこれを呼ぶ
  (`Tests/FTCoreTests/SimulatorPosterCachePurgeWiringTests.swift` が Sources 全体を走査して固定する。
  現在の呼び出し口は `SimulatorBoot.ensureBooted(udid:log:)` の1箇所で、供給・`DeviceBooter.bootOne`・凍結回復・
  表示凍結の回復・遅いランナーのデバイスごと再起動のどれもここを通る(`SimulatorBootSingleEntryTests`))
- **起動の同時数は機械全体で2台**(`SimulatorBootSlots`。`~/Library/Caches/fleetest/sim-boot.lock.<slot>` への flock・
  クローンもプロセスもまたぐ)。5台の一斉起動で空きメモリが尽きて FM が死んだため(MN-97)。
  枠が埋まっていても起動済み・起動中のデバイスは枠を待たずに `bootstatus -b` を撃つ
- **Booted のデバイスには撃たない** —— PosterBoard が動いている最中に消すと書き込み中のファイルを
  壊しうる。呼び出し側の保証をあてにせず、`purge` 自身が `SimulatorCatalog.shutdownObservation`
  で実状態を確かめる(一覧が読めない `.unreadable` も安全側で撃たない)
- **消すのは2種類だけ**: ①`SnapshotCache.cachedb` という名前のディレクトリ(見つけたら丸ごと・中には
  降りない) ②名前が `RuntimeSnapshot` で始まるファイル(ホーム画面の描画スナップショット
  `RuntimeSnapshot-<hash>-home.atx` と対のメタデータ plist)。②は今の壁紙の `configurations/<UUID>/versions/<N>/`
  の直下にハッシュ違いで作り足され古いものが消えない(1枚約 3MB・1台 81〜271 枚・最大約 860MB を実測)。
  停止中に全部消して起動すると今の分(1枚)だけ作り直され、ホーム画面・壁紙・シナリオ1本が正常だった
  (手で消した `-09` と、実経路で 109 ファイルを 0.7 秒で消した `-10`)。
  それ以外(configurations・descriptors の本体・壁紙の設定・データベース)には一切触れない。
  失敗(権限・途中で消えた等)は無視して先へ進む(起動を止めない)
- **検証**: 停止中の Simulator で `find <store> -type d -name SnapshotCache.cachedb
  -prune -exec rm -rf {} +` → 起動 → ホーム画面・壁紙・ウィジェット正常・シナリオ1本緑・
  キャッシュは現在の版だけ作り直された。所要は初回(22 起動ぶん・7.9GB・約 7 千束)48 秒、
  2回目以降 1.5 秒。実経路(run の供給で起動する直前)では 112 か所・6.6GB を 28.5 秒で消し、シナリオ緑
- **起動の直前は容量を数えない**(`measureBytes` は `fleetest clean` だけが true)—— 数えると全ファイルを
  もう一周なめるので、溜まったデバイスの初回は削除と同程度の時間が上乗せされ、供給が遅れる
- 消して確かめたのは 2 台(停止中に手で消した `-09` と、実経路の `-10`)。「15 台で約 187GB」は
  溜まり方を見た台数で、消して確かめた台数ではない
- **既に溜まった分**は `fleetest clean --simulator-poster-cache` が停止中の全 Simulator ぶんを
  消す(§保持容量とは別枠 —— `RetentionSweeper.Category` には入れず、このフラグを付けたときだけ動く。
  背景の自動掃除には含まれない)。Booted のデバイスは名前だけ出して飛ばす

### DS-12.4.3 iOS Simulator の統合ログ(Special)の整理(起動前)

`<data>/var/db/diagnostics/Special/*.tracev3` は logd が**容量でなくファイル数(1,000)でしか抑えない**
(`logdata.statistics.*.txt` の purge 記録で goal が無制限・kept 1000 files)。調べた `-01` では Special が 1.9GB、
統合ログ全体(diagnostics + uuidtext)で 3.7GB あった。Special の書き手は backboardd 47%(ほぼ全部が
`IOSurfaceQueryTransactionList got non-success return from kernel`)・runningboardd 13%・kbd 11%。
backboardd のこのエラーは、モニターが画面を配信しているデバイスで 192 件/5分、配信していないデバイスで 24 件/5分
(1組の比較。モニターを止めた対照はしていない)—— 画面の取り込みとツールの操作が主な源と読める。

- **起動の直前に新しい 100 ファイルだけ残して消す**(`SimulatorBootCleanup.specialLogFilesToKeep`。約 0.18GB)。
  ファイル名は固定幅の16進連番なので名前の昇順 = 古い順。`.tracev3` 以外には触れない
- 検証: 停止中の `-09`(647 ファイル・1.2GB)で古い 547 ファイルを消す(5 秒)→ 起動 → 新しいファイルが続けて
  書かれ・`log show` で読め・ホーム画面・シナリオ1本が正常。logd の `Failed to get persona` は削除前から出ている
  (手を入れていないデバイスにもある)
- Persist / HighVolume / Signpost は logd が容量でローテーションしているので触らない

### DS-12.4.4 iOS Simulator のニュースのウィジェットのタイムライン項目の掃除(起動前)

`<data>/Library/News/com.apple.news.public-com.apple.news.private-production/referralItems/com.apple.news.widget/`
には、今日の表示に置かれたニュースのウィジェット(systemSmall・systemExtraLargePortrait)がタイムラインを
更新するたびに `today--<大きさ>-<UUID>/`(記事の JSON `entry` と画像)を1つ足し、**古いものを消さない**。
`-01` の実測で 7/22 から 18,400 フォルダ・8.3 万ファイル・1.1GB、1日あたり約 1,200 ファイル・13MB で一定に増えていた
(1年で約 5GB。ファイル数が多いのでストレージ計測の走査も遅くする)。

- **起動の直前に `<data>/Library/News/*/referralItems` を丸ごと消す**
  (`SimulatorBootCleanup.purgeNewsWidgetReferrals`)。同じ階層のほかの物には触れない。ログに出す件数は
  `referralItems/<種類>/` 直下の項目数(2段の一覧だけ数え、中へは降りない)
- 検証(2026-09-27): 停止中の Simulator(3,486 フォルダ)を2つ複製し、片方だけ停止中に丸ごと消した(6 秒)→
  2台を同時に起動を2回。消した側は起動で 6 個だけ作り直され、2回目の起動では増えなかった(対照も 2 回目は増えない)。
  ホーム画面の撮影は2回とも対照と md5 が一致。ニュース関連のエラーは 164 件 / 対照 176 件で上位の種類は同じ。
  クラッシュレポートは両方に同じ種類(intelligencetasksd・AppIntentsLiveEntityService・PosterBoard 等)。
  消した側だけに出たのは1回目の起動中の2件(`com.apple.news.TodayFeedConfigDecoder` への XPC 接続失敗・
  CloudKit の My Articles 取得失敗。どちらも referralItems に触れない内容。1回ずつの比較なので揺れと切り分けていない)。
  実経路(停止した `-08` を `run --device` の供給が起動する直前)では 13,951 項目を **43.9 秒**で消し
  (溜まった台の初回だけ。2回目以降は数項目)、E2E-iOS の S0010 が緑、run の後に作り直されたのは 2 項目
  (systemSmall・systemExtraLargePortrait = 手を入れていない `-01` と同じ組み合わせ = ウィジェットの配置は残る)。
  今日の表示のニュースのウィジェットは枠が出て「No Stories」—— 消していない `-07` も同じ表示(Simulator では
  記事が取れない)
- 同じ棚卸しで見た残りは触らない: `private/var/MobileAsset`(Siri・言語などの資産 2.6〜2.8GB。消しても
  落とし直すだけ)/ `var/db/uuidtext`(ログの文字列表。古いランタイムの `dsc` が更新1回あたり約 90MB 残るが、
  使っていないものの判定が重く量も小さい)/ `Library/Caches`(寄せ集めで最大 163MB)

### DS-12.5 タイルペインの auto-fit と「非表示中は実測しない」規律

> **auto-fit は無い**(ユーザー決定 2026-09-17。ボタン・`tileFitModel.js`・`tileAutoFit` の保存を置かない)。
> セパレーターは手動だけで、保存値が無いときの初期位置は表示エリアの 20%(`splitter.js` の
> `DEFAULT_TILE_PANE_RATIO`。領域が測れた最初の描画で決める)。下の「非表示中は実測しない」規律は
> `relayoutTiles` と `splitAreaHidden` に残っている。

- **量の連鎖**: ペイン高さ → タイル高さ → `--tile-image-h`(= タイル実測高 − 固定 chrome 66px。
  `deviceTiles.js` の `relayoutTiles`)→ タイル幅(`--tile-image-h × --tile-aspect`)。
  padding/border/gap の定数は持たず全て実測する(style.css を変えたとき片方だけ古くなるのを防ぐ)
- **罠**: `devices` のポーリングは「デバイスモニター」タブが**非表示の間も届き続ける**
  (タブ非表示の間もフレーム配信は続く = 他タブから戻ったとき張り直しで映らない時間を作らない。ユーザー決定)。`applyDevices` は毎回
  `relayoutTiles` を呼ぶため、`display:none` 中は `clientHeight=0` → `--tile-image-h` が当時の下限 60px(現在は `MIN_TILE_IMAGE_HEIGHT` = 120)に
  潰れて書き込まれ、ペイン高さと `--tile-image-h` の対応が壊れていた。**タブへ戻ると実際の画像高さぶん過大**になりタイルが
  はみ出す(初回表示だけ正しく、他タブを経由すると必ず崩れる)。対策は
  **レイアウトが無いとき(`clientHeight===0`)は書かずに抜ける** — 非表示中は直前の正しい値が保たれる。
  同じ理由で `splitter.js` の高さ反映も `splitAreaHidden()` で抜け、タブ復帰時に
  `switchTab` → `reapplyPaneHeights` が測り直す(3ペインぶん。DS-12.6)
- **一般化**: **webview は非表示中もメッセージを受け続ける**。ハンドラからレイアウト実測値
  (`clientHeight`/`getBoundingClientRect`)を**書き込む**処理は、表示中でないことを確認してから行う
  (読むだけなら 0 が返って無害だが、書くと次に表示されたときまで嘘が残る)

### DS-12.6 「デバイスモニター」タブの3ペイン(ラインビュー / グリッドビュー / 実行ログビュー)

縦の並びは **ツールバー → run ボード(DS-18)→ `#devices-separator` → ラインビューの見出し →
`#tile-pane`(ラインビュー)→ `#splitter` → `#output-pane`(グリッドビュー。`flex:1 1 auto` で
残りを占める)→ `#splitter-log` → `#log-pane`(実行ログビュー。高さは `splitter.js` が inline で
入れる)**。3つとも常設で、**見出し行はどこを押しても開閉**(run ボードのヘッダと同じ規律。
三角は状態の表示で文字は常に ▶)。

- **テスト実行中のデバイスも操作を止めない**(ヒューマンインザループ。ユーザー決定 2026-10-25「常に介入可能・
  利用者の自己責任」)。トグルも確認も置かない(再提案しない)。人の操作の事実は CLI が
  結果 JSON の `humanOperations` に残し、ダッシュボードのシナリオ詳細と Markdown レポートに出す(DS-13.3 (0b))。
  止めるのは**整定のための自動の撮り直し**だけ(`gridLivePanel.js` の `scheduleOpSettleRefresh` /
  `refreshAfterPictureSettled`。判定は `laneLog.js` の `isDeviceRunning(id)` = `workerRunning` / hydrate の
  `runningWorkers`。id はタイルの `platform:name`)—— XCUITest ブリッジは1件ずつしか処理せず、シナリオの操作と口を取り合う。
  **画面サイズが無いときの最初の1回の撮影は実行中でも撃つ**(host の `handleGridAction` が座標の操作の前に撮る。無いと
  画面の操作が黙って無視される)。そのためグリッドの枠の整定は実行中は「次の snapshot」が来ず、`BOXES_SETTLE_CAP_MS` の
  打ち切りで手元の木で描く。
- **「実行中」と「デバイス」の間にもセパレーター**(`#devices-separator`。ユーザー決定 2026-09-22)。
  **見た目も挙動も `#splitter-log` と同じ**(`.splitter`)で、下げると run ボードが伸びる。
  見出し行どうしの区切りは地色だけで付ける(この仕切りが**唯一の例外**)。守る規律4つ:
  **①保存値が無い間は高さを書かない**(中身なりに伸び縮みする。既定比を作らない)/
  **②はみ出しは箱で止め、行は `#run-board-rows` が自前でスクロールする**(`min-height: 0` が無いと
  flex の既定で中身の高さまで伸びて `overflow` が効かない)/ **③畳んでいる間は出さない**
  (伸ばす中身が無い = 掴めない仕切りを見せない。CSS の `display: none` で `#splitter` /
  `#splitter-log` と同じ書き方。`offsetHeight` が 0 になるので高さの勘定からも自動で外れる)/
  **④畳みの反映は `runBoard.js` が
  `reapplyPaneHeights` を呼んで伝える** —— 高さを書いてあると箱の大きさが変わらず ResizeObserver が
  鳴かない(畳んだのに行の無い高い帯が残る)
- **どこまで引いても見出し行は消さない**(ユーザー決定 2026-09-21)。可動域の判定は純粋関数
  `webview/monitor/paneLayoutModel.js`(`runBoardLimits` / `tilePaneLimits` / `logPaneLimits`)に置き、
  見出し行とペインの padding は**実測して渡す**(定数を置かない = style.css を変えたとき片方だけ
  古くならない)
- **再クランプの入口は `reapplyPaneHeights` の1つ**(resize / run ボードの伸縮を見る ResizeObserver /
  run ボードの畳み / タブ復帰(`tabs.js`)/ 初期描画)。**run ボードを先に描く** —— 3ペインの
  取り分はボードの高さを引いた残りなので、順序を入れ替えると1周ぶん古い取り分でクランプする。**tile 側(`reapplyTilePaneHeight`)だけを呼ぶ経路を作らない**
  —— ラインビューを畳んでいる間 tile 側は `splitAreaHidden()` で素通りするので、実行ログビューだけが
  古い高さのまま取り残される(`webviewLogGridSplit.test.mjs` がソース走査で固定)
- **両ペインに出すのはラインビューで選択したデバイスだけ**(ユーザー決定 2026-09-21)。**全体レーン
  (`__overall__`)はデバイスではないので選択に関わらず実行ログビューに残す** —— 供給フェーズの進行
  (worker を持たないイベント)の受け皿で、消すと run の進みがどこにも出ない(DS-12.4 の `status` 行と対)
- **ちょうど1台選択のときだけ**、グリッドビューの中で拡大表示を `.lane-pair` が包み、操作カラム・操作パネルを
  その右隣に並べる(`laneLog.js` の `syncSinglePair`)。**実行ログの複製は置かない**(ログ本体は常に `#lanes-grid`
  側のレーン1つだけ = `appendLaneLine` の書き先も1箇所)。**実行ログビューは選択台数に関わらず利用者の設定
  (`logViewVisible`)と見出しクリックだけで開閉する**(1台選択でも自動では畳まない。複製が無いので畳むとログが
  どこにも見えなくなる)
- **1台表示のときだけ、デバイスのライブ操作**ができる(`gridLiveControls.js` = ツールバーと画面の操作、
  `gridLivePanel.js` = 操作パネル)。
  - **ツールバー**(拡大表示の右隣の縦のカラム。並びは「拡大表示 | 操作 | 操作パネル」): 戻る・ホーム・タスク切替・
    拡大・縮小・修飾キーの表示灯(ダブルタップ = Command・軌跡 = Option を押している間だけ点き、押し続けると `HELD_TIP_DELAY_MS`(0.8 秒)後に説明のツールチップも出す = `hoverTip.js` の `setHeldTip`。入力欄で押したとき・他のキーと一緒に押したとき(ショートカット)は出さない)を縦に積む。
    カラムは3段(上 = 戻る / 中 = ホーム〜表示灯を枠で
    囲んだデバイス操作のグループ / 下 = 失敗の文言)で、**上と下の段を同じ 1fr にしてグループを上下中央に置く**。DOM は `monitorHtml.ts` の `#grid-live-controls` を置き場から
    `.lane-pair` の中へ移し、操作パネルはその右隣へ置く(**ずれているときだけ動かす** —— devices の周期ごとに並べ直すと
    載せたボタンのツールチップが点滅する)。**「戻る」は1台表示を抜ける**(`deviceTiles.js` の
    `exitSingleSelection`): 「このデバイスのみ選択」の直後なら直前の選択へ戻し(絵の外側のダブルクリックと同じ戻し)、
    控えが無ければ選択を解除する。デバイスを触らないので busy でも押せる。
  - **画面の操作**(絵の上): クリック=タップ / Command+クリック=ダブルタップ /
    `LONG_PRESS_MS`(500ms、`liveConstants.js`)以上のホールド=長押し(`pressPoint`)/ 素のドラッグ=スワイプ
    (`dragPoints`。ドラッグ中は始点からの直線を描く)/ Option+ドラッグ=軌跡(`tracePoints`)。**軌跡の線は離した後も、
    デバイスがなぞり終えるまで残す**(デバイスは描いた時間ぶんかけて再生する)—— その操作の busy
    (observing なし)が立って解けたら消す。撃つ前に断られた(`gridActionError`・busy の外の `actionError`)・次のドラッグ・
    対象の変更でも消す。保険の上限は軌跡の長さ + 40 秒(host の待ち 20 秒 + serve の応答待ち 20 秒)。
    **離した後は、なぞった線を薄くし、再生が済んだ部分を太く重ねる**(`.playing` と `polyline.done`)。済んだ部分は**推定**で、
    経過時間をなぞった点の t に当てて伸ばす(`traceThinning.js` の `tracePrefix`。デバイスは指の位置を返さない)。
    **起点は見えている絵に合わせる**: その操作の busy の後に拡大表示の絵が初めて描き替わった時刻を「指が動き始めた点
    (`firstMoveT`)が映った時刻」とみなす(busy 起点だとブリッジの合成と配信の遅れの分だけ絵より先走った)。起点は busy の
    時刻より前へ戻さない。絵が変わらない操作では、再生が終わるまで太い線を出さない。
    **速さは実際の再生に合わせる**: iOS の XCTest の合成タッチはなぞった時間どおりに再生しない(MN-50.6 の実測)。host は
    軌跡の操作の応答(serve の actionResult = 再生の終わり)を受けた時点で `gestureActionDone` を送り、webview はそこで線を
    描き切って「起点から終わりまでの実際の時間 ÷ なぞった時間」をデバイスごとに覚え、次の軌跡の線の速さにする(直近の1回)。
    失敗の応答なら線を消し、比は覚えない。
    **押したまま動かさずに `LONG_PRESS_MS` を過ぎたら始点に「長押し」の印(`.long-press`)を出す**(デバイスは止まっていた
    時間ごと再生するので長押しになる = iOS のマップはピンを立ててパンしない。仕様は変えず、意図しない長押しに離す前に気付かせる)。
    軌跡・素のドラッグ・素の長押しのどれでも出し、**ダブルタップのモード(Command)では出さない**(押していた時間に関係なく
    ダブルタップを送る = 印と送るものが食い違う)。host は軌跡を送るたびに要約を出力パネルへ1行残す
    (`[live] trace:` = 点の数・時間・押してから動き出すまで・範囲・最大の跳び。`liveModel.ts` の `traceSummary`)。
    **座標がウィンドウの原点 (0,0) のポインターイベントは採らない**(`isOriginPointer`。なぞっている最中に1つだけ混ざり、
    採ると軌跡が絵の左上の角を経由してデバイスにもその形で送られる。離した位置が (0,0) なら最後に採った位置)。
    **絵の上のダブルクリックは2回のタップで、選択の切り替えにしない**(`laneLog.js` が
    `isGridLiveScreenTarget` と修飾キーで除く。切り替えは絵の外側のダブルクリック)。
  - **操作パネル**(`#grid-live-panel`): `.lane-pair` の中、操作カラムの右隣に置く(`syncSinglePair` が組を作り直すので
    `syncGridLivePanel` が毎回位置を確かめる)。1台表示は「拡大表示 | 操作 | 操作パネル」の3列(操作パネルが残りの幅を占める)。
    中身は要素一覧(見出し・「更新」。「バウンディングボックスを表示」はグリッドビューの見出し行の台数の右に置き、
    1台表示のときだけ出す・既定 OFF で ON/OFF は覚えない・クリックは見出しの開閉へ伝えない)・操作記録(列幅は `gridLiveOplogLabelWidth` に保存)。要素一覧は本文を切らずに横スクロールする。**入力するテキスト**(Enter 送信・IME 変換中と
    処理中は送らない)だけは拡大表示の絵のすぐ下(`.lane-preview-frame` の直後。`#grid-live-type-row`)に置き、中の
    ダブルクリック・右クリックは拡大表示(選択の切り替え・デバイスのメニュー)へ伝えない。当たり判定・行の描画・操作記録の描画は
    `liveListViews.js`。
  - **選択しただけでは serve へ接続しない(観測を自動で撃たない)** —— ブリッジの自動起動や実行中のテストへの
    相乗りを避けるため。接続は最初の操作・「更新」・枠トグル ON のときに起こる。**枠トグルが既に ON のまま
    1台表示を開いたときも1回取りに行く**(ON は利用者の明示の意思。撮らないと描く木が無く、ON なのに枠が出なかった)。一覧は host の `devices.selectedId`
    (host の serve が今つないでいるデバイス)が対象と一致するときの `snapshot`(screen と elements だけ。絵は
    モニター自身の配信)でだけ描き、`clearSnapshot` や別デバイスへのつなぎ替わりで捨てる。未取得の間は案内を出す。
  - **操作記録はデバイスごと**: host の `operationLog` が手動操作の行にだけ `deviceId`(操作を撃った時点の選択)を付け、
    パネルはデバイスごとに最大200行を控えて対象の行だけ出す。`deviceId` の無い行は出さない。「クリア」は対象のぶんだけ。
    右列は**同じ操作の Swift DSL の1行**(`tap("#login")` / `tap(x: 120, y: 340)  // coordinates — …`)で、クリックでコピーする。
    **拡張は変換せず、serve が `actionResult.dsl` で返した行をそのまま出す**(変換は `Sources/fleetest/LiveOperationDSL.swift` の1箇所 =
    MCP の下書きと同じ `FlowStep` → `ScenarioCodeGen`)。**拡張は画面の操作を座標で送る**ので、tap / 長押し / ダブルタップは
    撃つ前の直近の観測の木で、押した点にある操作可能な型のいちばん小さい要素へ写す(`FTCore.PointTarget`。MCP の下書きの座標タップと
    同じ判定)。操作可能な要素が無ければ、点を含むいちばん小さい要素(画面全体を覆う要素・スライダーは除く)へ、**中心を押しても
    その要素自身に当たり、安定したセレクタ(一意な #id・ラベル)が書けるときだけ**写し、行末に押した点を添える(セレクタの形は中心を押すため)。どれも書けなければ座標の行。
    行が対象に書いたセレクタは `actionResult.dslSelector` で返し、操作の列に `("…")` で添える(要素名(`{target}`)がそのセレクタと一致すれば添えない。末尾だけの一致では見ない =
    `liveModel.ts` の `withDslSelector`)。組めない操作は `dsl: null`(右列は空)。
    drag は押してからの静止が OS の長押し判定時間(iOS 0.5 秒・Android 0.4 秒)未満なら `swipePointToPoint`、以上なら `gesture { FTFinger… }`。
  - **枠の整定**: 画面を変える操作(「更新」以外)を送った時点で枠を消し(一覧は消さない)、**その操作の直接の結果の
    `snapshot` では描かず**、次の `snapshot` で描く。**この依存**: 直接の結果を受けたらグリッド自身が
    `SETTLE_REFRESH_MS`(700ms)後に「更新」(`refreshSnapshot`)を1回撃つ(`opSettleTimer`)ので、操作の結果の次には整定後の木が
    続く。その間に拡大表示の絵が描き替わったら予約を先送りする(絵が止まってから撮る)。処理中(busy)なら終わってから撃ち、
    実行中は撃たない。撮り直しの結果は非操作の `snapshot` として採って枠を描く。続かない場合のため、直接の結果から
    `BOXES_SETTLE_CAP_MS`(= 700ms×4)で手元の最新の木で描く。
    **「直接の結果」は host の合図 `gridActionStarted` の後に届いた最初の `snapshot` だけ**(`handleGridAction` が撃つ直前に
    送る。`runAction` は最初の await より前に busy を立てるので、合図と結果の間に別の観測は割り込まない)。host は撃つ前に
    デバイスの切り替え(開いたときの観測)や直前の処理の終わりを待つので、送った直後に届く `snapshot` は操作前の画面 ——
    取り違えると本物の結果を「整定後」と読み、遷移の途中の位置に枠を一度描く。操作の段(`opPhase`)は
    `clearSnapshot` で消さない(切り替えの途中で消すと同じ取り違えに戻る)。撃つ前に断られたら(`gridActionError`・
    busy を立てずに返る `actionError`)手元の木で描き直す。
    **枠はその木と同じ瞬間の絵の上に描く**: 木は host の観測(serve の `snapshot`)で届くが、拡大表示の絵はモニター自身の配信・ポーリングで
    別経路。ブリッジの無いシミュレータのポーリングは1サイクル1台の順繰りで台数ぶん遅く(実地: M1Max の iOS 6台で1台あたり
    約12秒に1枚。他の利用者が配信中 = `streamedByOther` だと配信も張れない)、絵の更新を待つ方式では上限が先に切れて古い絵の上に
    枠が出た。そこで**観測の一枚絵(snapshot の `image`)を拡大表示とタイルに出し**(`deviceTiles.js` の `showMirrorStill`。
    配信を描いている台は次のフレームが描けるまで一枚絵を前面に出す = `stillOverH264`。以後の配信・ポーリングのフレームが
    届けば入れ替わる)、**その絵の読み込みが終わるまで**(`onMirrorFrame` = 一枚絵の load / error。`gridLiveControls.js` が
    実行時に購読して `gridLivePanel.js` の `noteMirrorFrame` へ渡す)枠とホバー枠を描かない。既に同じ絵が出ていれば待たない。
    上限 `IMAGE_WAIT_CAP_MS`(1000ms = load / error が鳴らない異常の保険)。拡大表示の一枚絵は **src が変わったときだけ入れる**
    (同じ src を入れ直すと load が鳴る)。**一枚絵より前に撮られたポーリングの絵は捨てる**(撮るのに時間がかかるポーリングの絵が
    一枚絵の後に届くと古い絵に戻る): `monitorFrame` と snapshot の両方が `capturedAtMs`(撮り始めた時刻・epoch ms・必須。
    ProtocolVersion 56)を持ち、`deviceTiles.js` の `applyFrame` が配信由来でない絵のうち `capturedAtMs` が一枚絵より前のものを
    入れない。**比べるのはどちらもデバイスの居る機械で撮った時刻**(リモートでもモニターとライブ操作の serve はその機械で動く =
    機械間の時計のずれが入らない)。時刻は撮り始める前に採る(後に採ると古い絵が「後」に見える。`CaptureTimestampWiringTests`)。
    配信のフレームは時刻を持たない(届いた順 = 撮った順)。
    **操作と無関係に絵が変わったら、止まってから木を撮り直す**(操作の結果の整定の撮り直しと同じ考え方):
    OS のダイアログ(位置情報の許可等)・遅れて出る画面は操作の結果と撮り直しより後に出るので、撮り直さないと前の画面の木の枠が
    新しい絵の上に残った(実地: マップの位置情報の許可)。自分が出した一枚絵の読み込み以外で `onMirrorFrame` が鳴ったら、
    `SETTLE_REFRESH_MS` 新しいフレームが来なければ「更新」を撃ち、届いた木で描き直す。**鳴った時点では枠を消さない** —— 文字カーソルの点滅のように中身の変わらない描き替わりにも鳴り、消す → 撮り直して描く → 消す、で枠が点滅した(実地)。
    止まらない絵は `BOXES_SETTLE_CAP_MS` で打ち切って撃つが、**打ち切りで撮った木が前と同じなら以後の打ち切りをやめる**
    (`capBackoff`。点滅のたびに 2.8 秒ごとの撮り直しを続けない)。止まったときの撮り直し・木の変化・操作で戻す。操作の途中・
    host の serve が別のデバイスにつないでいる間は何もしない。**実行中は枠を消すが撮り直さない**。
    トグル ON で木が無い/古いときは「更新」を撃ち、届いた木で描く。ホバーは絵の上の点の
    最小の要素を一覧の行と枠で対に光らせる(一覧送りは枠 ON のときだけ)。
  - 送り先は `gridLiveAction` → `MonitorLiveController.handleGridAction` で、**serve は1本だけ**
    (対象のデバイスへ切り替えて使う。同じデバイスへ常駐を2本立てない)。選択中が別のデバイスなら `openDevice` で切り替えてから撃つ(処理中は
    切り替えずに `gridActionError` で断る)。座標の操作(tap/doubleTap/press/drag/
    trace)は切り替え直後の観測で `lastScreen` が揃うのを待つ。切り替えの中で観測が済んでいれば「更新」は二重に撃たない。
    失敗は**serve が今つないでいるデバイスが対象と一致するときだけ**グリッド側にも出す
- **折りたたみ機の開閉ボタン**(「折りたたむ」「開く」。グリッドビュー)は**モニターの `devices[].foldable` が
  true のデバイスだけ**に出す(`webview/monitor/foldButtons.js`。判定は `api monitor` の `DeviceFoldabilitySampler` が裏で1台1回 =
  iOS Simulator は devicectl の内蔵画面の枚数・Android Emulator は device_state の CLOSED。実機は測らず false・未確定は欄ごと省く)。
  押すと serve の `{"cmd":"fold","state":"fold"|"unfold"}`(`FoldControl.apply`。DSL の `fold()` / MCP の `ft_fold` と同じ判定)。
- **選択0台は両ペインに「デバイスを選択して下さい」**。実行ログビュー側は**全体レーンに行があるときは
  出さない**(供給の進行と重なる)。**出し入れはクラス(CSS)で行い inline の `display` を書かない**
  —— inline は畳みの規則に勝つので、畳んでも消えない形が静かにできる(例外は `waitingNote.js` が
  inline で出し入れする `#lanes-waiting` だけで、畳みの反映も同じ1箇所で解く)
- **永続化は `tilePaneHeight` と同じ契約**(webview → `setRunBoardHeight` / `setLogPaneHeight` /
  `setLogViewVisible` / `setGridViewVisible`、host → `runBoardHeight` / `logPaneHeight` /
  `logViewVisible` / `gridViewVisible`。既定はどちらも「表示」で、webview の `!== false` と host の
  既定 `true` を**片方だけ変えない**)。**`runBoardHeight` だけは既定値を作らない** ——
  届かなければ中身なりの高さ
- **タイルはどこを押しても選択トグル**(ユーザー決定 2026-09-21)。当たり矩形は**タイルそのもの**で、
  範囲選択(marquee)と同じものを使う(規則を2つ持たない)。解除はタイルの高さの外を押したときだけ
- 見出しの文言は **「デバイス一覧」/「選択したデバイス」/「実行ログ」**(ユーザー決定 2026-09-22)。
  「すべて選択」と「ライブ更新」は**どちらも同じトグル**(ユーザー決定 2026-09-22。
  `.header-toggle` のラベル + `.toggle-switch` のつまみ。ON は青い地)で、
  **ラインビューの見出し行にこの順で並べる** —— どちらもタイルの見え方を操るので隣り合わせる
  (「ライブ更新」が効く相手は全台 = タイルも拡大表示も)。台数(`.header-count`)から 10px
  離し(行の gap 6px に足して 16px。run ボードの「全て展開」と同じ)、**2つの間は行の gap だけ**。
  台数(`.header-count`)は**ラインビューが全台・グリッドビューが選択した台数**
  (ユーザー決定 2026-09-22。数える対象は違うが形は揃える)で、**0台でも出し、幅を固定**する
  (欄が消える / 桁が変わると右のトグルが動くため。等幅数字 + 言語ごとの `min-width`)。
  **全台のほうは選択の経路(`updateSelectionUi`)ではなく `applyDevices` で書く** ——
  デバイスが減っただけのときはあちらを通らない。守る規律3つ:
  **①実体は `input[type="checkbox"]` のまま**(キーボード操作と `change` をそのまま使う。
  `role="switch"`)/ **②見える文字は状態で入れ替えない** —— 次に何が起きるか(選択 / 解除)は
  ツールチップが出し、**`aria-label` は付けない**(見える文字が名前・ON/OFF は checked が伝える)/
  **③見出し行の開閉へ波及させない**(`streamToggle.js` / `deviceTiles.js` がラベルごと
  `stopPropagation` し、切り替えは `change` で受ける = label 経由の入力を二重に数えない)

## DS-18 デバイスモニターの run ボード(フリート横断の実行状況)

**動機**: モニターが run について持っている情報は2つだけ —— タイルの `inRun`(run-lease の鮮度)と、
**拡張が起こした run にしか届かない** `runEvent` のログ。「何本中何本終わったか」はどこにも無く、
CLI 実行・他人の run・ランナー機で直に打たれた run は `inRun: true` の1ビットに潰れる
(**FM のレートを run のイベントから供給しなかったのと同じ穴**)。

**見せるもの**: 走っている run を1行ずつ、進捗(done/total・失敗数)・経過・残り見積もり・
レーン(デバイス)の内訳。**主語は run であってデバイスではない** —— 台数が増えてもボードは伸びない。
対象は共有フリート全体(手元 + 全ランナー機・**自分の run も他人の run も**。ユーザー決定 2026-09-20)。

### DS-18.1 供給源は台帳(`FTCore.RunProgressLedger`)

```
~/.fleetest/runs/<pid>.json          ← 機械グローバル(FMUsageLedger の隣・同じ規律)
```

**機械グローバルに置くのが要点**。ランナー機では発行者ごとに work が分かれる
(`<base>/users/<issuer>/work/`。RR-18.6)ので、プロジェクトの `.fleetest/` に置くと
**他人の run が原理的に見えない**。共有アカウント前提(RR-15.3)なので `~` は全員で1つ。

```json
{ "pid": 41233, "runID": "…", "runGroup": "…", "issuer": "alice@air",
  "project": "ec-mobile", "profile": "ios-smoke",
  "phase": "running", "requeued": 1, "laneDropouts": 0,
  "startedAt": "2026-09-20T10:03:12Z", "total": 12, "done": 7, "failed": 2,
  "etaSeconds": 190,
  "supply": [ { "name": "iPhone 17-01", "platform": "ios", "step": "booting" } ],
  "lanes": [ { "key": "<udid|serial>", "name": "iPhone 17-01", "platform": "ios",
               "scenario": "05_検索", "scenarioStartedAt": "…" } ] }
```

- **記帳は `RunOrchestrator` の1箇所**。run-lease と同じ注入口(`writeRunLease` の隣)で、
  `runSequential` / `runParallel` の両方がここを通る = 記帳の実装を2つ持たない
- **ただし注入は2経路**(`ProfileRunner` と `ApiRunCommand`。`fleetest run` と `fleetest api run` は
  配線を別々に持つ2実装。共有はオプション宣言と検査の `RunCommonOptions` だけ)。**片方だけに足すとその経路では何も出ないまま緑で通る**ので、
  両経路の注入をソース走査テストで等号固定する
- **書くのは変化した瞬間だけ**(シナリオの開始・終了、レーンの増減)。秒ごとには書かない ——
  経過は読み手が計算する(18.3)
- **生存判定は pid だけ**(`ProcessLiveness.isAlive`。mtime を見ない = `FMUsageLedger` と同じ)。
  SIGKILL で残った控えは読み手が無視し、`RunCompletionSweep` と `remote clean` の保持ポリシーが掃く
  (`StreamLease` と同じ扱い)
- **run の段階を `phase` で持つ**(`"building"` → `"preparing"` → `"compiling"` → `"running"`。ユーザー指摘
  2026-09-20)—— 台帳を `RunOrchestrator` からしか書かないと、**ビルド・転送・デバイスの供給
  (実測で合計 20 秒。リモートはさらに長い)の間は run が1本も無い**ことになり、走っているのに
  ボードでは「空き」に見える。**書き始めは run の入口**(シナリオのビルドより前)で、
  ビルドが終わったら `"preparing"`、`RunOrchestrator` が走り出したら `"running"` へ上書きする
  (同じ pid = 同じファイル)。**`"building"` は実際に `ScenarioHost.build` を呼んでいる間だけ**
  (ユーザー決定 2026-09-22)—— 入口から立てると、`--skip-build`(**機械分担のローカル子は常にこれ**。
  親が1回ビルド済み)では**1バイトもビルドしないまま「ビルド中」**が出て、ビルドが終わってからも
  供給が始まるまで「ビルド中」のままだった。入口は `"preparing"` で書き(書かないとその間ボードから
  消える)、build を挟む間だけ `"building"` にして**直後に戻す**。**変更が無くてビルドを省くときも
  立てない**(`ScenarioHost.build` の `willBuild` = swift build を実際に呼ぶ直前にだけ呼ばれる)。
  省く判定(`BuildFingerprint`)は**パス依存の先(ツールのクローン)の Sources/ まで見る** ——
  外部パッケージ構成(受け手・ランナー機の WORK_DIR)は直下に Sources/ を持たず、見ないと
  判定不能 = 毎回 swift build になる(受け手構成の実測: 無変更の2回目が 0.11s)
  (`RunProgressLedgerWiringTests` が2経路とも走査で固定)。**書き手は段階ごとに場所が違う** —— `"building"` は
  `Fleetest.swift`(`fleetest run` はシナリオのビルドが `ProfileRunner` の外にある)と
  `ApiRunCommand`、`"preparing"` は `ProfileRunner` と `ApiRunCommand`、`"running"` は
  `RunOrchestrator` の1箇所。**どの段階も run / api run の両経路に置く**(片方だけだと
  その経路が無言になる)。**orchestrator へ渡る前に抜けたら消す**(defer。プロセスが
  すぐ死なない経路への保険)
- **`"compiling"` は `"preparing"` と `"running"` の間**(ユーザー決定 2026-10-06)。最初のシナリオの前に
  `compile-ocr` を待っている間だけ立てる(`RunProgressState.ocrCompileWaitBegan` / `Ended`。書き手は
  `RunOrchestrator`)。待ちは**シナリオの印より前**(`runWorker`)に置く —— `ScenarioHost.run` の中で待つと、
  何も動いていない間にレーンの経過と残りの秒読みが進んでいた(シナリオの所要の実績は待ちの後から
  計っているので、画面の数え方と食い違う)。全レーンが同じ1本を待つので run 全体の段階として持ち、
  待ちの間は進捗・残りを出さない(延長の秒数を見積もる定数を置かない)。待ち終えたらレーンの経過は
  0 から始まり、残りもその時点で計算し直される
- **全シナリオの後の動画の切り出しの間は `videoClips`(`{done, total}`)を載せる**(`FTCore.RunProgressVideoClips`。
  `VideoRecordingCoordinator.finish` の進みを `RunOrchestrator` が `RunProgressState.videoClipsProgress` へ中継する)。
  切り出すクリップがあるときだけ、開始時に `0/n`・1本終えるごとに1つ進む(失敗・断念も数える = `n` で必ず止まる)。
  **`phase` は `"running"` のまま**(本数と進捗バーは出し続ける)で、その間 `etaSeconds` は省く。
  拡張は残りの代わりに「動画を編集中 n/m」を出す(機械分担の run は全 run が切り出し中のときだけ合計。ProtocolVersion 55)
- **準備中の間は端末ごとの供給の段階を `supply` に載せる**(`FTCore.RunProgressSupply`:
  `name`(`devices[].name`。ランナーの build-for-testing は端末に属さないので空文字)・`platform`・
  `step` = `pending` / `runnerBuild` / `booting` / `bridge` / `configuring` / `installing` / `ready`)。iOS は計画の時点で予定の端末を全台 `pending` で
  立てる(同時に起動できる台数の枠を待つ端末に行が無いと、先に済んだ端末だけで「全台 ready」=「テストを開始しています」に見える)。**必須の欄**(古い形は読まない・
  段階の情報が無い run は空配列)。端末の行は `ready` になっても残す(読み手は全部 ready なら「テストを開始しています」)。
  **`configuring`** は iOS のブリッジがそろった後、シミュレータの設定(モーションを減らす・ソフトキーボード)を書き込む間
  (`ProfileWorkerFactory.buildIOSWorkers`。書き込む前に全台を立て、その台の書き込みが済んだら `ready`。
  無いとこの間も「テストを開始しています」が出る)。値を足すのは後方互換(読み手は未知の値を落とさず運び、
  古い拡張は「デバイスの準備を開始します」を出す)なのでプロトコルの版は据え置き。
  `runnerBuild` の行はビルドが終わったら消し、供給に失敗した端末の行も消す。
  **供給側(`BridgeProvisioner` / `ProfileWorkerFactory.installIfNeeded` / `AndroidLaneRecovery`)は
  `SupplyStageReporter` で `RunSupplyProgress`(run プロセス内の箱)へ知らせ、台帳の書き手3つ
  (入口の `writeProgress`・`ProfileRunOrchestrator.writePreparingProgress`=どちらも
  `PreparingProgressWriter`、`RunProgressState`)が書くときに必ず箱の snapshot(名前順)を載せる**。
  箱が変わったら直前の phase のまま書き直す(同じ内容なら通知しない)。`RunProgressState` は
  最初の書き込みの後に通知を引き継ぐ(それまでは準備中の書き手が続ける)。
  `ready` の置き場: iOS は `BridgeProvisioner.executeDevice` の終わり(ブリッジが ready)・
  `ProfileWorkerFactory.buildIOSWorkers` の設定の書き込みの後(その台の書き込みが済んだら)・
  `installIfNeeded` の終わり(戻るワーカー全部)、Android は `installIfNeeded` の終わり。
  Android のブリッジ待ちは `bootMissingDevices` が起こせた直後に `bridge` を立てる
  (定着待ち `awaitDurableAndroidBridges` の間)。
  **拡張**: 段階を**1つだけ**出す(台数は出さない = ユーザー決定)。選び方は `runBoardModel.currentSupplyStep` の1か所 ——
  ランナーのビルド(「ランナーをビルド中」)が最優先、端末は**いちばん進んでいる未完了の段階**(「デバイスを起動中」→
  「ブリッジを起動中」→「デバイスを設定しています」→「アプリをインストール中」の順で後ろのもの)。`preparing` ではそれを出し、端末の行が全部 `ready` なら
  「テストを開始しています」(実行が始まる直前)、段階の情報が無ければ「デバイスの準備を開始します」。
  `building`(「シナリオをビルド中」)・`compiling`(「Vision コンパイル中」)は供給の段階を添えない。`running`(混在 run で
  iOS の供給が続いている間)は進捗の横に同じ1語を添える。run / api run の2経路が箱を作って渡すことは
  `RunProgressLedgerWiringTests` が固定する
- **書くのはデバイスを実際に回しているプロセスだけ**。機械分担の run(親が手元・子が各機械)で
  親も書くと二重計上になる。束ねるのは読み手で、鍵は `runGroup`(単機 run は runID 自身)
- **レーンの `name` はモニターのタイルと同じ名前**(`RunWorker.logicalName` = 実行プロファイルの
  `devices[].name`)。`label` はポート込み(`…-01(ios:8130)`)なので、使うと同じデバイスがボードと
  タイルで別名に見える
- **詰まりの事実だけを載せる**(段6): run 単位の `requeued`(結果を捨てて振り直した回数)と
  `laneDropouts`(レーンが離脱した回数)、レーン単位の `expectedSeconds`(実行中シナリオの
  実績中央値。実績が無ければ省く)。**「遅い」「異常」とは書かない** —— それを分ける測定を
  していない(MN-29)。
  **`expectedSeconds` は記録用で画面には出さない**(ユーザー決定 2026-09-21)—— 経過の隣に
  並べると、超えた瞬間は同じ値が2つ並ぶだけ(`0:08(中央 0:08)`)で情報が無い。
  後から「いつもと比べてどうだったか」を分析するために**台帳と NDJSON には残す**
- **レーンごとの「残り本数」は持たない**。shared dispatch は同一 platform のレーンが1つのキューを
  共有するので、レーン別の残数は**同じ数字が並ぶだけ**(3レーンに「残 2」= 6本残っていると誤読される)。
  run の残りは `total - done` で足り、実行中の本数はレーンを見れば分かる
- **死んだ pid の控えは書き手が掃く**(`sweep`)。run の開始時に1回だけ走らせる(`StaleLedgerSweep` が
  provision の入口で台帳を掃除するのと同じ立場)。**読み手は消さない** —— `api monitor` は毎周期
  読むので、掃除を読み手に置くと監視が重くなるほど掃除も増える

### DS-18.2 監視への相乗り(`monitorRuns`)

`HostOccupancy` / `monitorLock` と**同じ経路**に乗せる。**ssh は1本も増えない**。

```
発行側                             ランナー機
 api monitor(親) ── ssh ──▶ api monitor --device-machine local(子)
     ▲ monitorRuns                     │ 毎周期 ~/.fleetest/runs/*.json を読む
     │ (親が machine を埋める)          │ (pid が生きているものだけ)
   拡張 ─┴─ run ボードを描く
```

```jsonc
{"kind":"monitorRuns","observed":true,"machine":"M1Max","runs":[
  {"pid":41233,"runGroup":"…","issuer":"alice@air","mine":false,
   "project":"ec-mobile","profile":"ios-smoke",
   "elapsedSeconds":261,"total":12,"done":7,"failed":2,"etaSeconds":190,
   "phase":"running","supply":[{"name":"iPhone 17-01","platform":"ios","step":"ready"}],
   "lanes":[{"key":"…","name":"iPhone 17-01","scenario":"05_検索",
             "scenarioElapsedSeconds":72}]}]}
```

- **machine は中継する親が埋める**(子は `--device-machine local` で自分を local と名乗るので、
  そのまま流すと手元の行に化ける。monitorDevices / monitorFrame / host-metrics に次ぐ4経路目)
- **「不明」と「無い」を混ぜない**: 子が落ちた・旧ランナーは `observed:false`。**控えも行も消さない**
  (消すと「実行中の run なし」と同じ形になる)
- **CLI と拡張は同じコミットで揃える前提**(版の照合は ProtocolVersion。後方互換の読み替えは置かない)
- **`monitorLock` と情報源が別**なので、ロックを取らない run(`--force-lock` で押し切った run)も
  ここには出る —— RR-18.7 末尾の「ロックに写らない run」がこの経路で見えるようになる。
  **`monitorLock` も手元を出すようになった**(2026-09-21)が、こちらは「本数と進捗」であちらは
  「占有」なので**別の軸のまま**(片方を他方から導かない)

### DS-18.3 時刻は秒に直して運ぶ

台帳は ISO8601 で持つが、**読むのは同じ機械の monitor** なので、経過は**読み手が自分の時計で計算して
秒で載せる**。手元は受信時刻から秒読みするだけ。`FMLiveness.checkedAt` / ロックの `acquiredAt` が
残している「向こうの時計とのずれ」を、この経路では最初から作らない。

### DS-18.4 残り見積もり(新しい定数を1つも置かない)

**見積もるのは run を走らせているプロセス自身**。他人の実績は手元に無いので、手元では原理的に計算できない。

- 材料は LPT がすでに使っているもの —— `RunResultsStore.scanRecords` → `LPTScheduler.durations`
  (`(scenarioID, platform)` ごとの中央値)。**2つ目の実装を作らない**。読むのは run 開始時に1回
- **値は makespan の下界**(新しい定数を置かない):

  ```
  残り = Σ(未着手の推定) + Σ(実行中レーンの max(0, 推定 − そのシナリオの経過))
  eta  = max( 残っている単一ジョブの最大, 残り ÷ 生きているレーン数 )
  ```

  並列スケジューリングの makespan は「最長ジョブ」と「総和 ÷ 台数」のどちらも下回れない ——
  **下界だから `~` 付きで出す**(実際はこれ以上かかる)。早い者勝ちのキューを LPT で再現したり、
  係数で水増ししたりしない(根拠のない数字を作らない)
- **実績が1件も無い run は `etaSeconds` を省く**(欄ごと省く = 表示は「—」)。推測値を出さない。
  **一部のシナリオにだけ実績が無いときは、実績のある中央値の中央値で埋める**(FleetRunner の
  `unknownDurationMs` と同じ考え方 = 既にある手口を流用し、新しい定数を持ち込まない)
- **分母(`total`)は run 開始時に確定した本数**で、再キューでも失敗でも動かさない
- **eta も記帳時点の値**(経過と同じ)。読み手は受信からの経過を差し引いて秒読みする
  (`liveRemaining`。0 を切ったら「残り ~0:00(+M:SS 超過)」)
- 表示は必ず `~` 付き。超過したら「残り ~0:00(+2:31 超過)」と**事実だけ**を並べ、
  遅れの帰属は書かない(MN-29)

### DS-18.5 UI(ツールバー直下に常設。ユーザー決定 2026-09-20)

```
┌ ▾ 実行中 2 ────────────────────────────────────────────────────────────┐
│ ▾ local   ec-mobile / ios-smoke     ███████░░░  7/12 ❌2   4:21 / 残 ~3:10 │
│     ▯ iPhone 17-01  ▶ 05_検索          1:12                              │
│     ▯ iPhone 17-02  ▶ 07_決済          0:48                              │
│     ▯ iPhone 17-03  ⏹ 待機              —                                │
│ ▸ M1Max   ec-mobile / android-regress ███░░░░░░  3/20     1:48 / 残 ~9:40 │
│ ▸ M1Ultra                                         空き                   │
│ ▸ M1mini                                          —                      │
└──────────────────────────────────────────────────────────────────────────┘
```

- **置き場所はツールバーの直下・ラインビューの上**(ユーザー決定)—— グリッド表示中も進捗が見える
  ことを優先する。下部ペインの第3モードにはしない
- **run 0 本でもヘッダ1行は残す**(ユーザー決定)—— 消すとレイアウトが飛び、「モニターが run を
  見ていない」のか「走っていない」のかも区別できない
- **ヘッダ行はどこを押しても開閉する**(ユーザー決定 2026-09-20)—— 三角だけを当たり判定にすると
  小さすぎて「開ける」と気づかれない。三角は状態の表示で、**文字は常に ▶・向きは CSS の回転**
  (字を差し替える形は細くて伝わらなかった)。個々の run の行の chevron も同じ規律
- **準備中の run は本数でなく「いま何をしているか」を1語で出し、進捗バーは隠す**(本数も割合もまだ意味を持たない。
  語は DS-18.1 の `supply` から = 「シナリオをビルド中」「ランナーをビルド中」「デバイスを起動中」「ブリッジを起動中」
  「デバイスを設定しています」「アプリをインストール中」「テストを開始しています」「Vision コンパイル中」、分からなければ「デバイスの準備を開始します」)。
  経過時間は出す —— どれくらい待っているかが分かる。**件数(「実行中 N」)には数える**
- **並びは常に機械の順**(local → 登録簿の順。ユーザー決定 2026-09-20)—— run が始まっても
  **その機械の位置は動かさない**(行の種類が「空き」から run に変わるだけ)。動くと目が追えない。**行の高さは固定する**
  (和文の「空き」と記号の「—」は既定の行高が違い、揃えないと上下に揺れる)
- **run の行に実行中のデバイス数「(N)」**(ユーザー決定 2026-10-28): run の範囲(プロジェクト / プロファイル)のすぐ右に
  左寄せで出す。数えるのはレーンのうち `scenario` を持つもの(待機中は含まない = 点灯マークと同じ基準)。走り出す前と空きの行には出さない
- **グリッドビューの点灯マーク**(ユーザー決定 2026-10-28): シナリオを実行中のデバイス(run のレーンのうち
  `scenario` を持つもの。待機中は含まない)だけ、拡大表示の左上(マシン名の段の左端)に点を出す(色は iOS がタコメーターの「低」の段と同じ青・Android は緑系。ユーザー決定)。ラインビューには出さない。
  点滅はさせない(操作の瞬間は約 2 秒周期の台帳からは取れない)。点灯・消灯は 0.8 秒のフェード(ユーザー決定)。レーン → デバイスは run ボードの行選択と同じ `deviceIdForLane`
- **詰まりは事実の並置だけ**(段6。ユーザー決定 2026-09-20): run 行に `⟳N`(再キュー)と
  `レーン離脱 N` を、**0 のときは出さない**。**語は中立に**(「遅い」「刺さっている」と書かない)
  —— ツールにはアプリが重いのか機械が混んでいるのか分けられない(失敗の記録に分類を置かないのと
  同じ理由)。**実績中央値は画面に出さない**(ユーザー決定 2026-09-21。記録には残す = DS-18.1)
- **デバイスの行にはデバイスのアイコンを名前の左に置く**(ユーザー決定 2026-09-22)。**色は
  プラットフォームのバッジと同じ値**(iOS / Android。`platform` が無いデバイスは色を付けない ——
  知らないものをどちらかに見せない)
- **レーンのデバイス名は省略しない** —— 末尾で見分けるので、途中で切ると同じ見た目が並ぶ
- **ツリーは2段・1行 = 1機械**(ユーザー決定 2026-09-30): **機械の行**(マシン名のバッジ。run があれば**同じ行に** `project / profile`・
  進捗・経過 / 残り)→ **デバイス**。run の無い機械の行はバッジと状態(空き / —)だけ。
  値は**その機械の run のもの** —— 機械分担の run は機械の数だけ行になり、それぞれが自分の進捗を出す
  (束ねた合計を使うのはヘッダの「実行中 N」の件数だけ)。同じ機械で run が複数走っていれば、
  その機械の行が run の数だけ続く。**どの行の種類でも同じ作り**(`.run-board-row`)にする ——
  作りを変えるとインデントと2カラムの境目が行ごとに割れる
- **機械の行の開閉の既定は、利用者が開かない限りどの行も閉じ**(run のある行も run の無い行も。下の「OFF の間」の規則が正。ユーザー決定 2026-09-30 → 10-01 で改訂)。
  押した結果を行の鍵ごとに覚える(寿命は webview の `getState` だけ。行の鍵は run が終われば
  二度と現れない)。閉じても行は残す —— その機械が居ることは消さない
- **階層はインデントで示す**(16px 刻み): ヘッダ 8px → 機械の行 24px(バッジ 48px)→ デバイス 48px
  (バッジと同じ位置)。**縦のガイド線**は機械の三角の中心(32px)に引く(ユーザー指摘 2026-09-20)
  —— インデントだけだと、デバイスがどの機械の子なのかが次の機械の行と見分けにくい
- **行は2カラム**(ユーザー決定 2026-09-22): 左 = ツリー(機械・デバイスの名前)、右 = ステータス
  (機械の「空き / —」・run の進捗と経過・デバイスの実行中シナリオ)。**右は左寄せ**。
  境目は**マウスで動かせる**。**既定はいちばん長いラベルがちょうど収まる幅 + 100px**(余白はユーザー決定 2026-09-30)
  (ユーザー決定 2026-09-22。比率ではない)—— 測る一瞬だけ左カラムを中身なりの幅にして
  全行の最大を採る(flex-basis が効いたままだと今の幅しか返らない)。**行を作り終えてから測る**
  (揃っていないと短い側に決まる)。守る規律4つ: **①幅は px で持つ**
  (比率だと丸めのたびに境目が滑る。既定は「まだ動かしていない」間だけ毎回引き直すので、
  デバイスが増えて名前が伸びれば追従する)/
  **②境目を全行で1本に見せる**ために、行の左右 padding を 8px に揃え・階層のインデントは
  左カラムの padding で表し・**レーンのガイド線は背景で引く**(border/margin は箱の幅を変えるので
  行ごとに境目がずれる)/ **③左右とも 80px は残す**(引き切って片方を潰さない。
  **保存する値もクランプ済み** —— 表示だけ直して控えに範囲外を残すと復元値が意味を持たない)/
  **④見出し行には掛けない**(掴む相手ではないうえ表示フィルタに重なる。top は測ったヘッダの高さ)。
  **寿命はこのパネルそのもの**(ユーザー決定 2026-09-22。`tilePaneHeight` とはここが違う)
  —— **タブを閉じたら解放し、開き直したら既定へ戻す**。隠す/再表示では保つ
  (`retainContextWhenHidden` で webview が生き続けるため)。そのため
  **webview のモジュール変数だけが持ち主**で、**host へ送らない・`getState` へ書かない**
  (どちらも閉じても残るのでリセットされなくなる)。ワイヤも持たない
- **デバイスのツリーは run の有無に関わらず出す**(ユーザー決定 2026-09-22)—— 認識したデバイスが1枚も
  見えないボードでは、フリートに何が居るのかがここから分からない。守る規律4つ:
  **①デバイスの一覧と並びはラインビュー(`monitorDevices`)から採る**(run のレーンからではない)。
  **ただし「起動中のデバイス」の表示フィルタは通さない**(ユーザー決定 2026-09-22)—— 通すと
  **ビルド中の run の下からデバイスが丸ごと消える**(供給前なのでどのデバイスもまだ起動していない)。
  停止中・観測できないデバイスもツリーには出す。そのため `monitorDevices` は**表示フィルタ前の全台**を
  webview へ送り(`devicesToWebviewMessage`)、落とすのは `deviceTiles.js` の入口でタイル側だけ/
  **②run の行にもその機械の全台を並べ、run が使っているデバイスにだけシナリオを添える** ——
  run に出ていないデバイスも見える / **③レーンの側にしか無いデバイスは落とさない**(消えたタイル・観測窓の
  外でも run の事実は残す。デバイスの一覧のあとに続ける)/ **④デバイスの一覧が変わったら描き直す**
  (`refreshRunBoardDevices`。run ボードは `monitorRuns` でしか描き直さないので、呼ばないと
  古いデバイスが残る)。**run の無い機械の行も run の行と同じ作り**(`.run-board-row`)で、
  行の高さ・インデント・展開の記録を共有する
- **run の無い機械の行**: **ヘッダに機械の要約は置かない** —— 同じ情報が2箇所に出るため。
  状態は**空き / 不明の2値**。空きは語、**不明は「—」**(ユーザー決定 2026-09-20。
  `remote status` の LOCK/FM 欄が判定不能に使うのと同じ記法)。**どちらもグレーで、警告色は
  使わない** —— 観測できていないのは異常ではない。ダッシュの意味は title で言う。
  **不明を空きに見せない**のがこの行の目的で、区別は語と「—」が担う
- **他人の run もプロジェクト名・プロファイル名・シナリオ名まで出す**(ユーザー決定 2026-09-20。
  同一信頼グループ前提)。自分の run では issuer を出さない
- 機械分担の run は `runGroup` で1本に束ねて数える(行は機械ごと = 上の「1行 = 1機械」)
- 機械の行のクリックでその機械のデバイスを**ラインビューで選択**(既存の `selectedDeviceIds`)。
  run の行はその run がその機械で使っているデバイスだけ。**デバイスの行は押しても何も起きない**(ユーザー決定 2026-09-22)——
  ここは実行状況を読む場所なので、cursor も hover の地色も付けない
- **ヘッダ右端の「全て展開を維持」はトグル(モード)**(ユーザー決定 2026-09-20)—— 一度きりの操作では
  なく、**ON の間はあとから始まった run も展開して出る**。**アイコンだけを置き、名前は tooltip と
  aria-label が持つ**(ユーザー決定 2026-09-21。ネイティブ `title` は使わず `setHoverTip`)。
  **文言は ON/OFF で入れ替えない** —— これは「いま開く」ではなく「開いた状態を保つ」モードのスイッチで、
  ON/OFF は押し込み(`.toggled`)で見せる。
  モードなので host の workspaceState に持つ(行ごとの展開は webview のみ、と対)。
  ON のまま1行を閉じたらモードを抜け、**他の行は開いたまま**(抜けた瞬間に全部畳まない)
- **OFF の間は、利用者が開かない限りどの行も開かない**(ユーザー決定 2026-10-01)—— run が始まっても
  既定は閉じ。**開閉の記録は機械ごと**(`machineExpansion`)で、同じ機械の run の行と空きの行が共有する。
  行の鍵(機械 + pid・run の有無)で引くと、次の run や 空き⇔実行中 の切り替わりで記録を失い、
  閉じた行が勝手に開く
- **プラットフォームの表示フィルタ**(ラインビュー見出しの「ライブ更新」の右。**iOS / Android の
  独立したトグル・既定は両方 ON**。値は `{ ios, android }`。**両方 OFF にはできない** —— 唯一 ON の側を押すと、もう片方と入れ替わる。ユーザー決定 2026-10-24): **見た目はバッジ**(ユーザー決定 2026-09-22)—— ON は**タイルのデバイス名ピルと
  同じ色**、**OFF は灰色**(aria-pressed が状態を持つ)。**ON はホバーで色を変えない**(素の
  `button:hover` が背景を塗り替えるので `--platform-badge-bg` で固定する)。OFF の側のデバイスを
  **4つのセクション(実行中・デバイス一覧・選択したデバイス・実行ログ)から同時に隠す**。
  **知らない形は両方 ON へ倒す**(webview も host も)—— デバイスが黙って消えるより出しすぎるほうが安全。
  守る規律3つ: **①落とすのは `applyDevices` の入口1箇所**(4つともこの一覧から作るので、
  ここで落とせば同時に消える。**次の監視サイクルで戻ってこない**のもこれが理由)/
  **②生の一覧を控えて切り替えたその場で描き直す**(次のサイクルを待たない)/
  **③run のレーンは別経路**なので、デバイスの一覧に無いレーン(消えたタイル)は `lane.platform` で
  別に落とす。永続化は `tilePaneHeight` と同じ契約(`setPlatformFilter` / `platformFilter`)
- 機械の色は `machineColors.js`、折りたたみ状態は `tilePaneHeight` と同じく設定へ保存

### DS-18.6 実装の段

| 段 | 内容 | 検証 |
|---|---|---|
| 1 | `FTCore.RunProgressLedger`(書き・読み・解釈は純粋関数)+ `RunOrchestrator` への注入 | 単体 + 変異。注入忘れはソース走査(`ParentDeathWatchWiringTests` と同型) |
| 2 | `api monitor` が手元の台帳を読み `monitorRuns` を出す | 仕分けは `ApiMonitorCommand.scope` と同じく pure に切り出す |
| 3 | 拡張: `runBoardModel.ts`(vscode 非依存)+ `webview/monitor/runBoard.js` | 往復テスト(型の効かない webview 境界)。i18n は両バンドル共有なので `lane.ts` 方式 |
| 4 | fan-out の中継(親が machine を埋める・`observed:false`) | 既存3経路と並べた等号テスト |
| 5 | 残り見積もり | LPT の部品を通すことをソース走査で固定 |
| 6 | 詰まりの注記(requeued / レーン離脱 / シナリオの経過と実績中央値の並置) | まず警告表示から |

段1〜3で「フリート全体の、誰の run でも、何本中何本」が出る。4 でリモートが乗り、5 で見積もり。

### DS-18.7 やらないと決めたもの

- **時間軸の帯(ガント)**: 「いつ何が動いていたか」は結果 DB(`api results`)とダッシュボードタブの
  担当で、モニターは「今」を出す口。両方に持つと同じ数字が2箇所で食い違う
- **空き機械の要約をヘッダに置くこと**: 要約と本体で同じ情報が2箇所に出て邪魔になる(ユーザー決定
  2026-09-20)。空き機械は本体に並べ、ヘッダには件数だけを置く(DS-18.5)
- **自分の run だけ `runEvent` から描く**: 供給源を台帳に一本化する。2通りの経路を持つと、
  同じ run が自分と他人で違う数字になる(runEvent はログレーン用に残す)
- **`results/<runID>/run.json` を実況の供給源にする**: `RunMetaRecord` は begin() の時点で pid ごと
  書かれており「実行中かクラッシュか」も読めるが、①**発行者ごとの work の下**にあるので他人の run が
  見えない ②毎周期 `scenarios/*.json` を数えるのは走査が重い ③**結果 JSON のスキーマの定義元は
  docs/results-json.md** で、実況のための欄を足すとそちらが汚れる。**記録(永続)と実況(揮発)を
  混ぜない** —— 突き合わせは台帳が持つ `runID` で足りる

### DS-18.8 タコメーター(アクション/秒。ユーザー決定 2026-10-28)

run ボードの見出しに、「実行中 N」・全て展開の右から順に推移・数値・40段の LED バーを置く(3案のうち横長のタコメーターを
採用し、並びはユーザーの見本に合わせた)。バーは幅固定で、見出しの幅に引き伸ばさない(ユーザー決定)。
**タコメーターは run が実行中(「実行中 N」の N ≥ 1。準備中も含む)のときだけ出す**(ユーザー決定)。隠している間も数え続ける。
**見出し行の LED バーの形のボタンで表示・非表示を切り替えられる**(既定 ON・ワークスペースごとに保存。ユーザー決定。設定タブには置かない)。
**出し入れはフェード(0.4 秒)**(run の開始・終了とボタン。ユーザー決定)。**run が終わっても 10 秒は出したまま**(ユーザー決定。その間に次の run が始まれば隠さない = 周の切れ目でちらつかない。ボタンの OFF は待たない)。消すときは透明になってから詰める。パネルを開いた直後の最初の判定(まだ run を受け取っていないので隠す)と動きを減らす設定では即座に切り替える。

- **アクション = デバイスへ実際に送った操作の回数**。1秒に1回タップするだけなら 1.0/秒。数えるのは子プロセスで
  `FTCore.ActionCountingDriver`(ドライバ群を同じ `ActionCounter` で包む)が**正常に返った**入力系の要件だけ。
  画面を読む・待つ・アプリの導入や向け直し(activate / attach)は数えない。**探すスクロールの1回ずつのスワイプも数える**
  (DSL の1行 ≠ 1アクション。ステップ単位の `Flow.isScreenMovingOperation` では数えられないので、ドライバで数える)。
  **ライブ操作は含めない**(別プロセスで台帳に載らない)
- **運ぶのは累計で、速さは拡張が出す**: 子 → 親は step / scenarioFinished の `actions`(前のイベントからの差分)、親は
  `RunProgressRecord.actions`(累計・必須)。台帳は変化したときだけ書かれるので、速さを台帳に置くと止まった run の
  値が古いまま残る。累計なら差分 0 が「止まっている」と読める。リモートは `monitorRuns` の中継にそのまま乗る(DS-18.2)。
  数えるのは run を実行している機械だけ(ディスパッチ元は台帳を書かない)なので二重計上は無い
- **推移のチャートは CPU・GPU のチャートと同じ作り**(ユーザー決定): host-metrics の tick(`onHostMetricsCommitted`)ごとに
  **その瞬間にカウンタが表示している値**を1点積み、直近 `HM_MAX_SAMPLES`(60)点を右詰めで並べる = 古い点は左へ流れて消える。
  ゲージが 0 ならチャートも 0。別の時計で描くと隣のチャートと動く瞬間がずれる。host-metrics が止まっている間は推移も止まる
- **数え方の基準**: モニターを開く前の分と、機械が観測できなかった間の増分は数えない(初見・再観測で基準を取り直す)。
  終わった run の寄与は窓を抜けるまで残す
- **LED バーは直近 3 秒の 1 秒あたり(ユーザー決定)**: 直近 3 秒に増えた数 ÷ 3。
  **数値(アクション/秒)はバーが表示している値そのもの・小数 1 桁**(ユーザー決定。別の窓で出すとバーが 0 でも数値が残って
  食い違う。単位は当初の「アクション/分」から秒へ変えた。説明と読み上げはバーの目標値)。元の更新はモニターの周期(約 2 秒・負荷で延びる)ごとなので、3 秒の窓には更新が1〜2回しか入らず段々に跳ねる。
  **表示は慣性で追いつかせる**(`easeToward`。時定数 1 秒 = 元の更新の周期の半分で、次の更新までに約 86% 追いつく)。
  途中の段は割合だけ薄く点けるので、車のタコメーターのように連続的に伸び縮みする(ユーザー決定)。動きを減らす設定では即座に写す
- **1目盛り = 1アクション/秒(ユーザー決定)**: 40段(40/秒)を超えたら同じ間隔の段を右へ足して延ばす(右端に張り付かせない。ユーザー決定)。
  足した段は高の色で、下がれば 40段に戻る。見出し行の右端を超える分は切る。1目盛り = 1アクション/分
  だと実際の負荷(手元 8 台で約 15/秒 = 900/分)に目盛りが足りない。見た最大値で上限を切り上げる案は、ひと目盛りの値が変わって
  読めないので採らなかった。推移の線の縦だけは表示中の最大に合わせる
- **色は VSCode のテーマに従う**(`body.vscode-dark` はネオンの発光、`vscode-light` は発光なしの計器調、ハイコントラストは
  テーマの色だけ)。発光は点いた段・数値・推移の線だけで、見出し行の地色と文字はテーマ色のまま。**数値の文字色はいちばん上に点いている段の色**(低・中・高。何も点いていなければ最下段の色。ユーザー決定)
