# 性能: 設計原則・計測・調整ノブ・不採用の施策

| 種別 | 範囲 | 読む場面 | 扱わないこと |
|---|---|---|---|
| 手順 | 経緯と到達点・設計原則・計測基盤・チューニングノブ・不採用の施策と再検討の条件・既知の落とし穴・今後の改善候補(PT-1・2・4〜8) | 速さに手を入れる前(不採用の施策を先に読む) | 時間の内訳(→ [breakdown-1.md](breakdown-1.md))・検証の判定規律(→ [verification/](../verification/README.md)) |

高速化実装の設計判断・計測方法・調整ノブをまとめた恒久文書。
将来チューニングを行う際は、**まず本書の「設計原則」と「不採用の施策」を読んでから**着手すること。
過去に検討済みの案を再発明・再検討する無駄を避けるための文書でもある。

## PT-1 経緯と到達点

固定 sleep(シナリオ時間の約 67%)とシナリオ毎の再初期化が支配項だったため、
「待ちはプッシュ型(イベント駆動)、仕事は削減」の原則で置き換えた。実測(2026-07-12):

| 指標 | 改善前 | 改善後 |
|---|---|---|
| Android シナリオ所要(中央値、Android設定アプリ.S0010) | 4.89s | **2.18s(−55%)** |
| iOS シナリオ所要(中央値、3シナリオ×2シミュレータ) | 28.9s | 約21.0s(−27%) |
| ライブ操作のタップ往復(Android) | 0.8〜1.0s | 0.383s |
| snapshot(ブリッジ HTTP 素) | 8.7ms | 変わらず(元々速い) |
| 成功率・ホスト CPU | — | ベースライン同等(悪化なし) |

Android の 2.18s への内訳: 固定 sleep の静穏検知置換で 3.27s(−33%)、さらに
アニメーション自動無効化(PT-7。GUI E2E で発見したバグの修正の副産物)で 2.18s。
iOS の残り時間は XCUITest 経路のコストが支配する。**その内訳を「snapshot 約250ms」とした旧説は
2026-07-30 の外形計測で否定済み**(素の snapshot は 29〜118ms。実体は操作直後に掛けていた
固定 350ms の整定待ちで、PT-3.8 で収束判定へ置換した)。iOS の高速化の本線は in-app 常駐ブリッジで、
既に既定(inapp-boost モード)で動いている(PT-8 の 2〜4 は候補ではなく実装記録)。

## PT-2 設計原則(変更時も維持すること)

1. **並列実行時の負荷を上げない。** エミュレータの CPU=ホストの CPU なので、
   「デバイス側だから無料」は成立しない。待機は必ずプッシュ型(イベント駆動・
   ブロックしたスレッドが通知を待つ形)にする。**ポーリングを速くする方向の
   最適化は禁止**(単発は速くなっても並列 N 台で負荷が掛け算になる)。
2. **単一実装。** フォールバック経路・新旧タイミングの切替モード・プロトコル互換層は
   作らない(2026-07-11 ユーザー決定。adb 直叩きフォールバックと ADBKeyboard は削除済み)。
   バージョン整合はテスト実施者が担保する。
3. **採用ゲートは 3 指標同時。** 速度が上がっても、ホスト CPU か N 回連続成功率が
   悪化する変更は採用しない。固定 sleep は「遅いが負荷ゼロ・フレークを隠す」性質が
   あったので、置換系の変更は特に成功率を疑うこと。
4. **着手順は見積りでなく内訳で決める。** 2026-08-01 に「次は CoreSimulator 化(0.9s)」と
   決めていたが、内訳を採ったら**別コールの `simctl terminate` が 1.5s** で、しかも
   1行の修正だった。見積りで順序を決めていたら、大きい方を後回しにしたまま重い実装に
   着手していた。**内訳が採れない区間があるなら、まず採れるようにする**(PT-4)。
5. **削った先に何が残るかまで測る。** simctl を消したら律速が
   「プロセスごとの CoreSimulator 初期化 384ms」へ移った(PT-3.12)。移った先を測らないと、
   次の一手(暖機)の効果を過大評価する —— 実際 30〜60ms しか無く不採用にした。
6. **省く前に、その呼び出しが兼ねていた副作用を数える。** 高い呼び出しは往々にして
   「読む」以外の仕事もしている。interop WebView の委譲を外したとき、消えた
   `delegated.snapshot()` が **XCUITest の attach を兼ねていた**ことに気付かず、
   最初の座標タップが 200 を返しても効かない状態になった(PT-3.13)。
   **消す前に「この呼び出しを消したら、他に何が起きなくなるか」を1度書き出す**。
   副作用が要るなら、それだけを安く残す(今回は入場時1回の接続確認)。

## PT-4 計測基盤の使い方(チューニングの必須手順)

**変更前にベースライン、変更後に同条件で再計測、summary.md を比較する。**

**計測の前にモニターを止める** —— `fleetest monitor pause [--for <分>]`(解除は
`fleetest monitor resume`)。kill では止まらない(拡張が `api monitor` も配信ヘルパーも
数秒で再起動する)ので、無人計測はこのコマンドで条件を作る。効くのはこの機械の
monitor だけ。機構と旧手段(pkill 3連打)は docs/verification/operations.md「モニターと E2E」。

**計測手段は「使いたい条件」で一度検算してから信じる。** 2026-08-01 に launch の内訳を
出せるようにしたが、いざ 8 レーンで採ると `FT_EVENT_LOG_PATH` が並列書き込みで壊れ、
**launch 41 本中 3 本しか読めなかった**(1プロセス実行しか想定していなかった)。
知りたい条件がまさに読めない状態で、しかも**壊れた行は黙って捨てられる**ので
「n が少ない」以外に手がかりが出ない。手順は単純:

1. 採れた件数が**期待どおりか**を必ず確認する(シナリオ数と一致するか)
2. パースできなかった行数も数える(0 でないなら計測基盤を疑う)
3. 疑わしければ**単発(1レーン)と並列で同じものを採って比べる**

これを飛ばすと、少ない・偏ったサンプルで設計判断をすることになる。

**集計はシナリオ・step index 単位で突き合わせる**。コマンド名だけで中央値を取ると、
同名でも別シナリオ・別画面のステップが混ざって**実際より大きい差に見える**
(2026-08-03: `scrollToTop` を混ぜて `+1,007ms` と書いたが、揃えると最大でも `+1,100ms` の
1件で、他は `+130〜600ms` に散っていた)。**「1コマンドに集中」と読めたら集計方法を疑う**。

**スイート総計で小さい差を主張しない**。Android は同条件でも run 間で 363〜398s 振れるので、
n=3 では ±3s 程度は解像できない(Android はセッション内で性能が劣化するため)。
狙った経路のステップだけを取り出して突き合わせる方が S/N が高い
(実例: スイート総計は +3.2s で悪化に見えたが、scroll 系ステップだけ見ると −2.0s の改善だった)。

**A/B でバイナリを差し替えるなら `fleetest-scenarios-<project>` を差し替える(2026-08-03 に実害)。**
`StepExecutor`・ドライバ・セレクタ解決は **`fleetest` ではなくシナリオランナーのサブプロセス**で
動く(`RunOrchestrator.swift` 冒頭の契約)。`swift build --product fleetest` して
`.build/debug/fleetest` を入れ替え、`--skip-build` で回す —— という手順は
**両側とも同一のコードを実行する**ので、どんな変更も必ず「差なし」に見える。
実際にこれで、性能の A/B(誤って「+0.1% = 退行なし」と結論)と、Compose の探索不具合に当てた
修正案2件(いずれも誤って「no-op」と結論)を取り違えた。**症状は「きれいに差が出ない」**なので
気付きにくい。手順:

1. 差し替えるのは `.build/debug/fleetest-scenarios-<project>`(`swift build --product` も同名で)
2. **陽性対照を先に通す** —— マーカーを書くだけの版をビルドして差し替え、
   実行してマーカーが出ることを確認してから本番の A/B に入る
3. 二つのバイナリが `cmp` で別物であることも確認する(同名プロダクトの取り違え検出)

`nm` でシンボルを確認するときは、**動く側のバイナリ**を見ること
(「mtime でなく symbol で確かめる」の別形。
symbol を見ても対象を間違えれば同じ穴に落ちる)。

軽量な計測口が2つある(bench.swift を回すほどでもない切り分け用):

```bash
# ラン固定費の内訳(フェーズ毎の所要を stderr に出力)
FT_PHASE_LOG=1 fleetest run --profile <p> --scenario <s> --skip-build

# step 単位の NDJSON(durationMs/snapshotMs/actionMs/waitMs)をファイルへテー出力
FT_EVENT_LOG_PATH=/tmp/steps.ndjson fleetest run --profile <p> --scenario <s> --skip-build

# --scenario を付けなければプロファイル全体(=8レーン実負荷)の内訳が採れる。
# 並列でも行は混ざらない(EventLogAppender が直列化。2026-08-02 修正。それ以前は
# 複数ワーカーが同じハンドルへ書いて行が壊れ、41 本中 3 本しか読めなかった)
FT_EVENT_LOG_PATH=/tmp/steps.ndjson fleetest run --project <P> --profile <p>
```

- **`launch` も内訳を持つ**(2026-08-02 から): `actionMs`=プロセスを起動させる外部呼び出し、
  `waitMs`=操作可能になるまでの待ち。**`durationMs - actionMs - waitMs`(内訳外)を必ず見る** ——
  計測していない区間がここに出る(実際これで `simctl terminate` の 1.5s と
  未インストール検査の 0.7s が見つかった。PT-3 の表)
- 埋まらない経路は nil のまま(Android・`FT_NO_FAST_LAUNCH` 経路)。嘘の数字は出さない


```bash
# Android 単体(エミュレータ稼働中に)
swift Scripts/bench.swift --project SampleApp --profile android \
  --iterations 5 --scenario Android設定アプリ.S0010 --out bench-results/<名前>

# iOS(プラットフォーム専用シナリオは --scenario で絞る。PT-7 の落とし穴参照)
swift Scripts/bench.swift --project SampleApp --profile ios --iterations 3 \
  --scenario iOS設定のデバイス画面.S0010 --scenario ログインテスト.S0010 \
  --scenario ログイン画面.S0010 --out bench-results/<名前>
```

- `summary.md` に壁時計中央値/シナリオ毎所要/ステップ所要(durationMs と
  snapshot/action/wait の内訳)/成功率/heal 件数/ホスト CPU・GPU・MEM が出る
- CPU 計測は `fleetest api host-metrics`(デバイスモニターと同一計測系)を内部で流用
- **FM 介入は ANE 負荷ではなく呼び出し回数で見る**(PT-4.2)。ANE 負荷率は指標として使えないと
  実測で確定したため廃止した(PT-6)
- ステップ内訳は NDJSON イベント(`kind:"step"` の `durationMs/snapshotMs/actionMs/waitMs`)
  として流れるので、レポート/拡張からも参照できる
- `bench-results/` は .gitignore 済み。比較対象のベースラインは削除しないこと
- run ごとに `TestProjects/<project>/results/runs/<YYYY-MM>/<runID>/host-metrics.ndjson`(1Hz NDJSON)
  へホスト負荷を採取し、`fleetest api host-metrics-summary --project <p> --run latest`(既定 latest)
  で直近実行の avg/peak を JSON で読み戻せる(「あの実行は CPU 律速か」を実行後に確認できる)

### PT-4.1 ストリーミング vs ポーリングのキャプチャ負荷ベンチ

`Scripts/stream_vs_poll_bench.py`(依存: python3 + 起動中の sim/emu)。デバイス画面配信の2方式
(ストリーミング=`fleetest-simstream`/`fleetest-androidstream`、ポーリング=`fleetest api live serve` へ
`{"cmd":"frame"}` を fps 間隔で送る経路。`monitor.pollingMode` トグルの2方式に対応)のキャプチャ負荷を
静止/モーション × 隣接ベースラインで比較する。

```bash
# 起動中の sim/emu を自動検出、両OS・静止+モーション
python3 Scripts/stream_vs_poll_bench.py
# 片OS・静止のみ・計測窓を延ばして JSON 出力先指定
python3 Scripts/stream_vs_poll_bench.py --platform ios --conditions static --meas 20 --out /tmp/r.json
# 未起動なら start-device して計測(プロファイル名指定)
python3 Scripts/stream_vs_poll_bench.py --boot-ios-name シミュ1 --boot-android-name エミュ1 --project SampleApp
```

- **主指標=キャプチャプロセスの CPU(proc%/core、cputime デルタ/実時間、1コア=100%)**。ホスト差分
  (`host-metrics`、Mac 全体)は 10 コア分母で小信号が ambient 揺らぎ(±3pt)に埋もれるため補助。fps と
  stream_kbps も出す。出力は `bench-results/stream-vs-poll/`(.gitignore 済み)+ 表を stdout。
- 実測(M1 Max / iPhone17Pro sim / Pixel9 emu / fps12・max-width900):静止 proc → ストリーミング **0.2%** /
  ポーリング **~23-26%**、モーション proc → ストリーミング **~5%** / ポーリング **~24%**。fps → ストリーミング
  **~12**(滑らか) / ポーリング **5-8**(スクショ同期往復に律速)。静止でもポーリングは device 側込みで
  host **+14pt**(Android≈1.4コア)を消費。**→ ストリーミングはキャプチャがほぼ無料、特に静止画面
  (モニタの支配的状態)で圧倒的。**
- **H.264+WebCodecs 化後の実測(2026-07-14。上記は MJPEG 経路の値)**: helper モーション時
  Android **5.2%→1.0%**(パススルー化)・iOS **1.5%→0.9%**(VT HWエンコード)、4台デモ65秒平均で
  webview Renderer **8.4%**(MJPEG 時代は瞬時 30-65%)・拡張ホスト 1.4%。このスクリプトが測るのは
  **MJPEG 経路だけ**(コーデック切替のフラグは無い)。h264 側(helper と、復号を担う
  webview Renderer)は本番パネルでの cputime デルタでしか測れない
- **計測の罠(スクリプト冒頭 docstring に全掲)**:
  - `host-metrics`/`simstream`/`androidstream` は **stdin EOF で即終了**する常駐 CLI。Popen は
    `stdin=PIPE` を開いたまま保持必須(未保持=/dev/null 継承で即死→0 サンプル/0 フレーム。静止 0 と誤診しやすい)
  - ストリーミングは変化駆動で静止は≈0fps(仕様)。負荷はモーション条件でしか見えない
  - ストリーミング helper が 0 フレームでも「壊れた/表示合成が要る」と即断しないこと。simstream は
    **Simulator.app 無し・ヘッドレスでも動く**(実測: 静止≈0fps・モーション≈10fps)。0 フレームの第一容疑は
    上の stdin=PIPE 未保持による即死、次いで静止で変化が無いだけ(モーションを与えて切り分ける)
  - `serve`/`host-metrics` は **cwd=リポジトリルート**で起動(iOS ブリッジ自動起動の repo-root 検出のため)

### PT-4.2 FM 呼び出しの実測(回数・レイテンシ)

FM はホスト全体で共有される資源で許可枠に制限される(PT-3.5)ので、コストは**回数と時間**で測る。
`FMHealth`(Sources/FTCore/FMHealth.swift)が用途別(occlusion / screenLooksLike。自己修復は
2026-09-15 に FM を呼ばなくなったので対象外 → MN-22)に計上し、
シナリオ毎の結果 JSON の `fm` に載る。実行中は各シナリオ終了時に stderr へも1行出る。

```bash
# run 全体の FM コストを集計(壁時計と比べて律速かを判定する)
python3 -c "
import json,glob
fs=[json.load(open(f)).get('fm') for f in glob.glob('TestProjects/<project>/results/runs/*/<runID>/scenarios/*.json')]
fs=[f for f in fs if f]
print('呼び出し', sum(f['calls'] for f in fs), '合計秒', sum(f['totalMs'] for f in fs)/1000)
"
```

- **FM 合計時間 ÷ 壁時計**が判断軸。FM は許可枠(既定1・PT-3.5)で頭打ちになるので、合計時間が
  そのまま実行時間の下限に近づく。これが壁時計に近づくほど FM 律速で、**デバイスを増やしても
  縮まない**(枠はホスト単位のため)
- モニターパネルの **FM グラフ**(数値=累計回数、線=tick 毎の増分)でも実行中に見える
- FM が全滅すると occlusion-guard・screenLooksLike は**握りつぶされて素通り**する(テストは緑のまま
  機能だけ無効になる。自己修復は 2026-09-15 に FM を呼ばなくなったため対象外 → MN-22)。
  `FMHealth` が失敗を数えて実行後に警告するので、これを見逃さないこと

### PT-4.3 in-app dylib の内側を測る(整定ループ等)

in-app ブリッジはアプリのプロセス内にいるので、外形計測(アクション所要)では中身の内訳が見えない。
`fleetest` 側のログにも出てこない。使える手順は**一時計装 → ホスト側のファイルへ追記 → 撤去**:

- **書き出し先は `/private/tmp/<名前>.log` にしてホストから読む**。シミュレータのプロセスから
  ホストの絶対パスへ書ける(サンドボックス外だが simulator では通る)。`NSLog` は届くが
  unified log から拾い直す手間がかかる。複数シムが同時に追記するので1行1レコードにする
- **1 回ずつ時計で挟まない**。`DispatchTime.now()` 自体が数十 ns で、レイヤ判定のような
  1µs 未満の処理では測定対象と同程度になる。**同じ処理をまとめて N 回回して割る**
  (PT-3.10 は対象ツリー全レイヤ × 50 周で 1 レイヤあたりを出した)
- **計測前に `fleetest bridge down --all`**。稼働中の旧 dylib はそのまま再利用されるので、
  ビルドし直しただけでは計装版が載らない(版数を上げていないときは特に無言で旧版が走る)
- 撤去し忘れを防ぐため、計装は `// MARK: - 一時計測(TEMPORARY PROFILING — 計測後に削除する)`
  で囲んで1箇所に固める

### PT-4.4 整定の打ち切り率(赤になる前の先行指標。2026-08-07 追加)

収束判定がポーリング上限で打ち切られたステップは、**注記を付けて先へ進む**(止めない)。
これは通った run にだけ現れる情報なので、合否だけを見ていると**フレーク率が上がる直前まで気付けない**。
採用ゲート(PT-2 の 3 指標)の「成功率」を、赤が出るより前に判定するための指標がこれ。

```bash
fleetest results insights --project <name>     # 🟡 unsettledSteps の行を見る
```

- 判定は `results/runs/**/scenarios/*.json` の `timeline[].notes`。閾値は
  「3 run 以上 かつ 3割以上の run で発生」(`RunResultsQuery.unsettled*`)
- **数えるのはコード(`settle-capped`)だけで説明文は見ない**。文言一致で数えると、文言を
  書き換えた瞬間に集計が静かに 0 件になる(「問題が無い」と「測れていない」が区別できなくなる)。
  文言とコードは `Sources/FTCore/StepNote.swift` が1箇所から供給する
- **notes を持たない古い results は 0 件として数える** = 率が下がる側に倒れる(過小報告は安全)
- 同じ経路で `steps.viaHeldValue`(掴んだ値だけで通り往復 0 回だったステップ数)も記録している。
  これらは `durationMs=0` なので**所要の内訳の母数から抜ける** —— A/B で「速くなった」が出たとき、
  実装の効果か当たり率の変化かを切り分けるのに使う

## PT-5 チューニングノブ(値を変える場所)

| 定数 | 場所 | 現在値 | 意味・トレードオフ |
|---|---|---|---|
| `QUIET_MS` | AndroidRunner/…/QuietWaiter.java | 200ms | 静穏とみなす無イベント継続時間。下げると速いがアニメーション途中を「整定」と誤判定しやすい。**アクション所要の床** |
| `ACTION_CAP_MS` | 同上 | 2000ms | 静穏しないときの上限(スピナー等の常時アニメ画面で必ず抜けるための安全弁)。整定判定の失敗ではなく打ち切り |
| `LAUNCH_CAP_MS` | AndroidRunner/…/BridgeRouter.java | 10000ms | /session のウィンドウ出現+静穏の上限。超過は 500 エラー(黙って進まない) |
| `STABLE_PACKAGE_BUDGET_MS` | 同上 | 100ms | クロスパッケージ遷移(例: 設定→検索インテリジェンス)で遷移前パッケージを掴む誤整定の防止予算 |
| `RETARGET_EXCLUDED_PACKAGES` | AndroidRunner/…/QuietWaiter.java | {com.android.systemui} | クロスパッケージ遷移時、静穏対象パッケージの追従(TYPE_WINDOW_STATE_CHANGED 検知時に静穏対象を送信元パッケージへ切替)から除外するパッケージ。追従してしまうと遷移先アプリ本体ではなく付随ウィンドウの静穏を待つことになるため |
| `PollBackoff` | Sources/FTCore/PollBackoff.swift | 100→200→400→800→上限1000ms | exist/textIs/ロケータ解決リトライの共通バックオフ。5s timeout での snapshot 回数は旧5回→新8回(許容済み) |
| `defaultTimeout` | FTRuntime(runs プロファイルで上書き可) | 5s | 検証系の待ち上限。失敗するテストの所要を支配 |
| `waitSeconds:`(tap/type/select) | DSL 引数(FTDSL/Commands.swift・select は CommandsVerify.swift) | nil | アクションのロケータ解決待ち上限秒。nil=従来の3回リトライ(計700ms)、**0=リトライなし(出るか不定の要素を見るときの空振り ~750ms→数十msに短縮する opt-in ノブ)**。遅れて出る要素を拾えなくなるので `ifCanSelect` / `select` の空振り短縮以外では基本使わない |
| fallback 照会の間引き | StepExecutor+Assert.swift(executeAssert) | primary 2回目以降・偶数回ミスのみ | inapp-boost モードの SystemUIDriver 照会(springboard 再session+XCUITest snapshot=数百ms)の頻度。実在するシステムUI要素の検知遅れは最大バックオフ1段+1周期 |
| LPT 投入順 | `fleetest.lptScheduling` / `--no-lpt` | ON | 過去実績の長い順に投入する(PT-3.7)。OFF でシナリオ ID 順。レーン数とシナリオ長のばらつきが無いと効かない |
| LPT の実績の読む件数 | `fleetest.lptHistoryRuns` / `--lpt-history-runs` | 5 | **シナリオ1本あたり**読み込む実績の観測数(新しい方から。`RunResultsStore.scanRecords(maxObservationsPerScenario:)`。PT-3.7)。増やすと代表値は安定するが毎 run の読み込みファイルが増える。実測で 1 プロジェクト 3,500〜4,500 件の結果 JSON があるため全件走査はしない |
| 操作直後の整定(Android) | ブリッジ `/settle`(QuietWaiter) | QUIET_MS=200ms | ブリッジを経由しない経路(activate/home/appSwitcher/pressEnter フォールバック)の整定(PT-3.9)。旧実装は固定 800ms。ブリッジ不達時のみ 800ms へフォールバック |
| 操作直後の整定(iOS) | `BridgeRouter.captureSettled` の minSettle / budget | 0.12s / 0.35s | ツリーが連続2回一致するまで撮り直す(PT-3.8)。minSettle は早抜け防止の床、budget は収束しない画面の打ち切り。budget を上げるとスクロール慣性で待ち切ってしまい旧実装より遅くなる(0.8s で実測 0.72〜0.83s) |
| ビルドスキップ判定 | FTCore/BuildFingerprint.swift | mtime+size+toolchain | PT-3.2。強制再ビルドは `.fleetest/build-fingerprint-*.txt` を削除 |
| `fleetest.streamCodec` | VSCode 設定(package.json) | h264 | 画面配信コーデック。h264=HWエンコード/デコード(低負荷)、mjpeg=互換(WebCodecs 問題時の退避先。デバイス単位の自動フォールバックあり) |
| 描画間引き(66ms) | vscode-fleetest/src/webview/monitor/h264Decoder.js | 約15fps | h264 の canvas 描画間隔。デコード自体は全チャンク必須(P フレーム連鎖)なので下げても復号コストは減らない |
| `FT_WEBVIEW_DOM` | InAppBridge/Sources/InAppWebViewDOM.swift / Sources/FTAndroid/AndroidWebViewDOM.swift | 有効(`off` で無効) | **自作アプリの WebView の中身を DOM から読むか**(OS 共通の意味)。iOS in-app は off で WebView 画面ごと XCUITest へ委譲する従来動作(1手 4ms → 378ms)。Android は off で a11y のまま = **WebView の版で `#id` と `placeholder` が入れ替わる**状態に戻る(docs/design/webview.md「Android の自作アプリの WebView も DOM から読む」)。ブラウザ本体は別の口(`FT_BROWSER_DOM`)|
| watchdog しきい値 | vscode-fleetest/src/monitorBridgeWatchdog.ts | booted 連続5観測(約10秒)/クールダウン3分/2回で諦め | ブリッジ自動修復の感度。短くすると起動過渡を誤検知、長くすると復旧が遅い |
| ワーカー参加の間隔(`FT_WORKER_STAGGER_SEC`) | Sources/FTCore/RunOrchestrator.swift(`WorkerStagger.seconds`) | 1.5s(`0` で無効) | run 開始時にワーカーを1本ずつ参加させる間隔。**先頭2本は待たない**(`simultaneousHead`=2。BridgeProvisioner の「in-app の新規起動は同時2台」と同じ値)。各シナリオは `condition { launchApp() }` から始まるので、N 本同時に積むと**最初の launch が N 本同時**に走る。**定常のレーン数は変えない**ので伸びるのは立ち上がりだけ(10 台で約 12 秒)。1.5 の根拠は「シミュレータの launch がおおむね1〜3秒」という観測だけで、凍結率で較正した値ではない。なお 2026-07 の混在 5 デバイス実測(CPU 平均 50%・launch 衝突スパイクなし)ではスタガリングを一度見送っており、その後に採用した |
| ワーカー参加の CPU 上限(`FT_WORKER_START_CPU_MAX`) | Sources/FTCore/WorkerStartGate.swift(`WorkerStagger.cpuCeiling`) | 1.0 = 100%(`1` 以下は割合・超えたらパーセント) | **これ未満になるまで次のワーカーを起こさない**。間隔は時間の当て推量で、ホストが実際に空いたことを見ていない —— 供給が長引いた run では飽和したまま次を起こす。**先頭2本もこの門は通る**(間隔だけが先頭免除)。**30 秒(`cpuWaitCap`)空かなければ諦めて素通しし、以降その run では CPU を見ない**(飽和の理由がテストと無関係なとき立ち上がりが際限なく延びるため。諦めは1回だけ警告)。`CPUSampler` は連続呼び出しだと差分が取れず nil を返すので、**1窓(0.5s)以内の測定値は使い回す**(これが無いと先頭2本が測定窓のぶん離れ「間隔0」が崩れる)。コストは通常設定で最初の1窓=約 0.5 秒 |
| ステップの減速(マシン設定 `~/.config/fleetest/config.json` の `hostLoadPacing`) | Sources/FTCore/HostLoadPacing.swift(`defaultTiers`) | CPU % 以上 → 待ちミリ秒の段。既定 90%→200ms・95%→1000ms(この Mac・Android 6 台・配信ありで、CPU 97% 以上の時間が減速なしの 13.1% → 約 2%・所要 +11%。95% の段を 2000ms にしても 97% 以上は減らず、93% に下げても変わらなかった)。`disabled: true` で無効・`tiers: []` で待たない | **画面を変える操作の前に1回だけ**固定の待ちを入れ(検証・`select`・`findImages`・`waitForSettle`・`wait`・`doUntilTrue`・`procedure` と、`hold { }` の押している間と、画像で掴んだ要素の `tap()` と `settle: false` の操作は待たない。`settle: false` は利用者が速さ優先と明示した操作(消える表示を叩く・連打。Material の Snackbar の短い表示は 1.5 秒)。最後のものは見つけた枠の座標を叩くので、待つと座標が古くなる。セレクタの操作は待ったあとに木を取り直す)、CPU 100% 張り付きによる判定精度の低下を避ける(負荷が下がるまでは待たない)。CPU は**操作の直前にその瞬間の値を子が自分で測る**(`InstantHostCPU`。tick を 10ms 空けて2回読む = 操作ごとに約 10ms 遅れる。1回の読みは約 7µs)。測れなければ1回言って待たない。測る窓と待ちはステップの `durationMs` と FTSync の締切の外で、待ちは `DeadlineExclusion` で scenarioTimeout からも差し引く(負荷が高い間に長いシナリオが時間切れの赤にならない)。記録は `pacingMs`(docs/results-json.md)。不正な段は既定へ倒して親が1回警告 |
| `maxConcurrent`(bootAll 引数) | Sources/FTAndroid/DeviceBooter.swift | 2(固定。ユーザー決定 2026-07-16) | devices up の同時進行数(1台=ブート→iOS ブリッジ供給まで)。上限がブートストーム防止を兼ねる(旧 CPU 負荷ゲートは廃止済み。PT-3.3)。上げると速いがタイルの進行表示も増える |
| Simulator の同時起動の枠 | Sources/FTBridgeClient/SimulatorBootSlots.swift(`concurrency`) | 2(固定。ユーザー決定。設定の口なし) | 機械全体(プロセス・クローンをまたぐ flock)で Shutdown → Booted を同時2台まで。全経路が `SimulatorBoot.ensureBooted` を通る。起動済み・起動中は待たない。5台の一斉起動で空きメモリが尽きて FM が死んだ(MN-97) |
| GPU 描画モード / 凍結時 CPU フォールバック | DeviceBooter.startEmulator(gpuMode) / ApiStartDeviceCommand `--gpu` / ApiStartAllDevicesCommand `--cpu-render` / monitorHealthWatchdog | 既定 host / 凍結個体のみ swiftshader_indirect | `-gpu host` は速い(モーション時 約1コア/デバイス)が**画面凍結の主因**(PT-7)。swiftshader は免疫だが 約3コア/デバイス。全機 swiftshader ではなく、凍結が displayRepair/streamRepair で治らない個体だけ per-device で swiftshader 再起動(セッション中維持。bulk `start-all-devices` も `--cpu-render <論理名>` で維持される。host への意図的復帰は `restart-devices`) |
| 探索の打ち切り(`unmovedRoundsToStopSearch`) | Sources/FTCore/StepExecutor+ScrollFrame.swift | 2 周連続で木が不変なら打ち切り | 端に着いた後も上限まで振り続けるのをやめる。**見つからない探索が 7.40s → 2.05s**(実測 2026-08-06)。1 にすると遅れて描画される行を取りこぼす |
| 逆走査(`reverseSweepSpanRatio` / `MaxSwipes` / `DragSpeed`) | Sources/FTCore/StepExecutor+ScrollFrame.swift | 容器の 0.5 ぶん / 8 本 / 120px/s | 端に着いても見つからないときだけ、逆向きに細刻みで戻って拾い直す。**失敗が確定してからしか撃たない**ので通常経路のコストは 0。速度を上げるとフリングになって反対の端まで走る(実測: 189px 指定が約 700px 走った)。**MCP の ft_scroll_to の1回目だけは半開きシートの停滞で逆走査を撃たない**(`defersPartialSheetRecovery`。シートを展開して再試行する側の逆走査が救済を引き継ぐ。実測: 畳まれた経路カードで 7.8s の丸損 → 同一シナリオ 21s → 10.7s。2026-08-10) |
| `recordBitrateKbps` | 実行プロファイル(既定は `VideoRecordingConfig.defaultBitrateKbps`) | 1000kbps | 録画クリップの再エンコードの目標ビットレート(Android は screenrecord にも)。下げると iOS のクリップが小さくなるが、500 で誤読が増える(半分の解像度。PT-3.31)。Android は半分の解像度だと 1000 に届かないので効かない |
| `FT_CONTAINER_INFERENCE` | 環境変数(`ContainerGeometry.containerInferenceEnabled`) | 既定 on / `off` で無効 | **容器をツリーから推測して行う補正の殺しスイッチ**。見切れ判定・ghost の掴み直し・救済ドラッグ・座標補正(見えている部分を撃つ)・壊れた座標の候補除外が**まとめて止まり**、推測を持たなかった頃の挙動へ戻る。容器は「pre-order で直前の depth の小さい要素 + 同 depth の兄弟が2つ以上中に居る」という推測なので、**想定外のツリーでは外れ得る**(外れると別の場所を叩く・明後日へ送る・正当な要素が消える)。E2E の SUT は UI フレームワークごとに限られる(実アプリの木は代表できない)ので利用者の逃げ道として置く。**run 全体を殺す最上位のスイッチ**で、より細かい単位は実行プロファイルの `containerInference` と DSL の `tap(containerInference:)` / `withoutContainerInference { }`(docs/commands.md) |

window/transition/animator の `*_scale` はチューニングノブではなく、既定は 0 固定(実行プロファイルの `enableAnimations: true` で残せる。判定元は `Sources/FTCore/AnimationPolicy.swift`)で、
`Sources/FTAndroid/AndroidBridge.swift` の `startBridge()` 内(ブリッジのコールド起動時)と run 開始時に
自動設定される(PT-7 参照)。

**ブリッジ(APK)を変えたら `AndroidRunner/build.sh` の VERSION_CODE と
`Sources/FTAndroid/AndroidBridge.swift` の `expectedBridgeVersionCode` を必ず同時に上げる**
(ホストが不一致検出で自動再インストール)。検証時は旧ブリッジを
`am force-stop com.example.ftbridge` してから疎通させると確実。

## PT-6 不採用の施策と再検討条件(再発明防止)

| 施策 | 不採用理由 | 再検討条件 |
|---|---|---|
| ホスト ANE 負荷率の計測(IOReport `DIE_n_ANE0` の ACT/INACT residency) | 2026-07-22 実測で**電源状態の1ビットしか返さないと確定**し、指標ごと廃止(IOReport 私有API 依存 約200行も削除)。実推論レートを 8→175 回/秒(22倍)振っても全水準で正確に 1.00、アイドルのみ 0.00。**推論0件で失敗した実行でも 1.00 になる**(モデルをロードして電源が入っただけで立つ)。代替候補も全滅: PMP の `0%..100%` バケットは負荷時も常時オール0、DVFS residency(`ANEn-{SLOW,FAST}-*`)は SLOW/FAST クロックドメイン間を仕事が移動するため非単調、`ANEn RD+WR`(帯域)だけは単調だが GB/s であって利用率ではなく分母が定義できない。Energy Model グループは SIGSEGV、powermetrics は root 必須。**FM のコストは ANE ではなく呼び出し回数とレイテンシで測る**(PT-4.2) | Apple が ANE の利用率を公開 API で出したら、または powermetrics 相当を非 root で取れるようになったら |
| OCR の補助プロセスをマシンに 1 つ常駐させる(run ごと・MCP セッションごとに起動しない)(2026-10-08 検討) | 省けるのは準備の 0.32 秒(キャッシュ済みのモデルの読み込み)だけで、run の開始から最初のシナリオまで(下限で中央値 9.3 秒)に隠れる。常駐させると版の食い違い(`fleetest` を作り直したら入れ替える)・起動と停止の持ち主・孤児の掃除・複数の run と MCP の待ち行列の管理が増える。詳細は PT-3.33 | 補助の準備が最初のシナリオの開始を待たせていることが `FT_PHASE_LOG` のミリ秒の記録で確かめられたとき |
| SpringBoard のアラート・覆いの確認を、木を1回撮って探す形にする(2026-10-12 実装して撤回) | 劣化した機で 11.7s → 0.45s に縮むが、**画面に出ている位置情報の確認のダイアログを見逃した**(SpringBoard の木を丸ごと撮っても入っていない。拾えるのは `alerts` の問い合わせだけ)。見逃すとタップの前の門が開き、指がダイアログに当たって権限を黙って変える | 撮った木にシステムのアラートが載る経路が見つかったら。それまでは劣化の検知と起こし直し(PT-3.36)で対処する |
| 同じ Mac で iOS と Android の run を同時に回す(hybrid の1本・2026-10-27 検討) | CPU で頭打ち。この Mac(M2 Ultra・24 コア)のフル E2E で、iOS だけ(Simulator 7 台)で平均 63〜67%・Android だけ(Emulator 6 台)で平均 73〜77%(上位 10% は 89〜93%・90% 超が時間の 1〜2 割)。同時に回すと常に 95% を超え、ステップごとの減速(1000ms)が入る。台数を減らして同時に回しても総仕事量は同じ | マシンの CPU が増えて、片方の OS だけで平均 50% を大きく下回るとき |
| ランナー常駐化(stdin でシナリオ逐次投入) | 残存コスト ~0.2s/本(全体の1〜6%)に対し、プロトコル+クラッシュ隔離の複雑さが見合わない | ヒール多用ワークロード(FM 3B モデルのプロセス毎再ロードが効く)か、1 バッチ数十本規模 |
| シナリオ毎の CoreSimulator 初期化(約 360ms)の排除 = ホストへ委譲 or プロセス再利用(2026-08-02 調査) | 得られるのは壁時計 **1.8s/プロファイル(3.4%)**。代償はクラッシュ隔離・確実な kill・状態の初期化(DS-16.4 / ScenarioHost 冒頭)で、失敗モードが「遅い」から「デッドロック」「別シナリオの状態漏れ」へ変わる。**安い入口も無い**: `serviceContextForDeveloperDir:connectionType:` は type=0 が同等、type=1 は deviceSet が 6.4s、`standaloneConnectionWithError:` は context として使えない。`xcode-select` の 65ms だけは `DEVELOPER_DIR` 受け渡しで削除済み | 初期化が数倍に伸びるか、1プロセスあたりのシナリオ数を増やす別の動機(隔離を捨ててよい理由)が先に出たとき |
| エミュレータ黒画面対策としての Wipe Data / キャッシュ削除の自動化(2026-07-17 精査)→ **同日ユーザー決定で実行プロファイルのオプションとして実装済み** | 精査結論: Wipe Data が効くのは「ブート時黒画面」(Quickboot スナップショット破損・userdata 破損)。本フリートの症状は正常ブート後数分の表示パイプライン凍結で adb reboot で一旦回復する=userdata 破損型と不一致(guest cache.img は 66MB で削除効果なし)。コールドブート保証(`-no-snapshot`。ロード+セーブ無効)を DeviceBooter に実装。**別発見: フリート AVD の userdata-qemu.img.qcow2 が 6〜12GB に肥大**(qcow2 差分は縮まない)。この肥大解消のため、ユーザー決定で実行プロファイルに `wipeDataOnBloat`(既定 true)/`wipeDataThresholdGB`(既定 8。wipe 直後の再構築だけで 2〜4GB になるため 4GB 以下はスラッシング)を追加し、実行開始時に超過 AVD を Wipe Data する(AndroidDataWiper.swift)。**Wipe はゲストを初期化するが、アプリは appPath があれば強制再インストール、ロケールは実行プロファイル `locale`(既定 ja_JP)が再ブート後にブリッジ /locale で自動適用される**(DS-11.2) | **真因は切り分け済み(2026-07-17): `-gpu host`(DS-7)。Wipe は凍結には無効で確定** |
| エミュレータ凍結対策としての swangle_indirect(ANGLE/Metal)描画 | 2026-07-17 実測。headless で `screencap -p` が終始 0B(フレームバッファを読めない=証跡取得不能)。GPU アクセラを保ったまま凍結を避ける狙いだったが使い物にならない | emulator が headless での swangle スクショ取得に対応したら |
| iOS ブリッジの実行前プレフライト(シナリオごとの /status 疎通確認) | 2026-07-18 に2実装とも撤去(ユーザー決定)。①「item を取ってから 5s×2 判定→振り直し+離脱」は 10台同時の AX スパイク(一過性の遅さ)で9台一斉離脱・freeze-retry 上限到達の失敗まで発生。②「取る前に 2s 即断+60s 回復待ち」も負荷時の誤判定が残った。**一過性の遅さと本物のウェッジは短い期限では区別できない**。検知は失敗後の事後チェック(bridgeUnreachable 等→振り直し)のみとし、ウェッジ機上の1件が scenarioTimeout(当時 90s。今の既定は 600s)を失うのは許容コスト | XCUITest ランナーが main queue 非依存で /status を返せるようになったら、または iOS 並列度削減で AX スパイク自体が消えたら |
| Android ブリッジのスクリーンショットを可逆 WebP で符号化する(2026-09-19 試作・測定) | 所要の大半は端末上の符号化(撮影 13〜67ms・PNG 符号化 58〜272ms)だが、WebP にしても符号化はほぼ縮まない。8 回の中央値の全体: Pixel 3a 355 → 290〜299ms・Pixel 4a 226 → 218〜237ms・エミュレータ 79 → 73〜81ms。WebP は大きさが 2〜8 倍でホストの展開が +10ms 前後なので、差が出るのは遅い実機だけで約 50ms。ブリッジの版上げ・APK の作り直しに見合わない。**経路そのものは今のブリッジ `/screenshot`(PNG)が最速**(`screencap -p` 625/346/167ms・生の画素 10MB は USB 転送で 702/624/604ms) | 遅い実機が主力になり、スクリーンショットがステップの所要の大半を占める用途(画像探索の連打)が出たとき。そのときも先に符号化の速い形式(可逆のまま)を端末で測る |
| 操作後の整定を画像の静止判定にする(2026-10-10 実装・撤去) | 木の整定と比べて正しさの差が出ず、E2E の合計所要が +14〜36% 遅くなった。木の整定はタップ後に待たずに返り次の snapshot で済ませているのに対し、画像整定は操作ごとにアニメーションの終わり + 窓を払う。詳細と残す知見は PT-3.34 | 木の整定のまま「動いている画面」起因の赤が実 run で出たとき。全操作でなく絵が要る直前だけに絞る案から測る |
| iOS のスクロール探索で、送るたびに極小の横ドラッグ(空打ち)を撃って慣性を止める(2026-10-11 実装・撤去。対象は Compose Multiplatform / Flutter で送りが XCUITest の実ジェスチャのとき) | E2E-CMP / E2E-Flutter の `ios-xcuitest` の `05_スクロール`(スクロール探索 26〜31 か所)を OFF → ON で比べ、合否は両方全部緑・合計所要は CMP 333 → 365 秒(+9.5%・速くなったのは 10 本中 2 本)・Flutter 277 → 309 秒(+11.7%・9 本中 0 本)。理由の見立て(未検証): 慣性を止めると1回の送りで進む距離が減って送る回数が増える + 空打ち1回約 0.3 秒。UIKit 系は XCTest が慣性の終わりまで待つ(上限 6 秒)ので元から対象外 | 探索の送りごとに慣性の収まりを長く待っている実測が出たとき。そのときも送る回数(距離の減少)と合わせて測る |
| launchApp の同時起動の制限(CPU 90% 以上の瞬間に始める起動は機械全体で1本 = flock の共有/排他) | この Mac・Android・配信あり・ステップの減速あり(90%→200ms・95%→1000ms)で各 2 run: **8 台**では CPU 97% 以上の時間が約 9% → 4.2% に半減したが所要 +6%・中央値 87% → 80%。**6 台**では 1.75% → 1.5% とほぼ変わらず所要 +15%(130 → 151 秒)。根拠にした集計: 8 台で 97% 以上の瞬間は平均 2.8 レーンが起動の最中 = 6 台では重なりが少ない | 1 機械で Android 7 台以上を常用するとき(この Mac は最大 6 台と決めている) |
| iOS の終端ドウェル(`thenHoldForDuration`)でスクロールの慣性を消す | 2026-08-02 実測で**効かず不採用**。v1500 + hold 0 / 0.05 / 0.10 / 0.20 の移動量は 2.85 / 2.85 / 2.82 / 2.82 倍で慣性は残り、**所要だけ +200ms** 増える。XCUITest の hold は指を保持するだけでイベントを出さないため `UIPanGestureRecognizer` の速度計算が更新されない(Android の `VelocityTracker` は同一座標の MOVE 連打で速度が 0 になるので、**Android 側の話をそのまま iOS へ持ち込まないこと**)。検証のため一時的に `DragRequest.hold` を足した(版 37)が撤去済み(版 38)。**iOS で慣性を消す手段は速度を落とすことだけ**で、その閾値はフレームワーク依存(PT-3.18) | XCUITest が「保持中も move イベントを出す」API を提供したとき。**再提案の前に PT-3.18 (b) を読むこと** |
| snapshot 差分ポーリング/ポーリング間隔の一律短縮 | 負荷が並列 N 台で掛け算(原則違反) | なし(原則ごと見直す場合のみ) |
| ブリッジ /waitFor(セレクタ条件待ち) | セレクタ解決の Java 複製=二重仕様。整定後は初回ヒットが普通で価値が薄い | exist の初回ミス率が実測で高くなったら |
| HTTP keep-alive | 単一スレッドサーバ+複数クライアント(ライブ+モニター)で飢餓リスク。1接続 8.7ms 実測で効果は数 ms | サーバをマルチスレッド化する大改修をする場合のみ |
| adb forward ポートのファイルキャッシュ | MCP/serve/monitor が常駐でレジストリが効く。残るは稀な CLI 一発のみ | なし |
| 拡張既定バイナリの release 化 | 常駐化でプロセス起動が初回 1 回になり意味消失 | なし |
| capability 交渉・旧タイミング互換モード | バージョン整合は人間担保(ユーザー決定)・単一実装 | なし |
| iOS のシミュレータ私有 IF 直叩き(idb 方式: AXRuntime ツリー+IndigoHID 入力) | snapshot は速くなるが**整定のイベント源が無い**(Android の a11y リスナ相当が無い)ためポーリングに回帰=負荷原則違反。Xcode ベータ毎に壊れるリスクも高い | プッシュ型のアイドル信号を得られる経路が見つかったら |
| xcuitest の quiescence 待ちを swizzle でスキップ(当時の FastInput.swift。2026-07-21 PoC) | swizzle 導入・リクエスト毎の発火まで実測確認したうえで**効果 0〜2%**。静的アプリでは quiescence 待ちは元々ほぼゼロで、tap ≈360ms の実体は XCUITest のイベント合成往復(実測記録: poc/appium-driver-benchmark ブランチの docs/poc-appium-benchmark.md 追補3)。トグル(実行プロファイル `iosFastInput`)は撤去済みで、今の口はコマンドごとの `settle: false`(ブリッジへは `X-FT-Settle: 0`。ランナー側は `QuiescenceWait.swift`)だけ | アニメーション・常時通信の多いアプリで tap が実測で遅いと分かったら(そのアプリでのみ opt-in)。**2026-10-09 に常時動く地図(Apple マップ・MCP の ft_batch・Simulator・各2回)で測り直した**: タップの actionMs は 1,362〜1,576 → 412〜420ms に縮むが、**縮んだ分が次の手の snapshotMs へそのまま移り**(482〜557 → 1,320〜1,352ms。アプリはキーボードのアニメーション中)、4手の合計は 13.3〜13.9 → 12.8〜13.1s(約4%)。トグルは既定 off のまま置いていた |
| fast launch の attachOnly 化(simctl launch 後に activate() を呼ばずプロキシ接続のみ。2026-07-21) | launch 単発は 3.4→1.2s に見えるが、**activate() が担っていた初回整定が最初のステップのポーリング待ちへ移動して相殺**、シナリオ全体ではむしろ微悪化。simctl+activate を採用。ランナーの attachOnly 対応(LaunchRequest.attachOnly)は無害なので残置 | launch 直後に操作しない(整定を別途待つ)ワークロードが現れたら |
| ライブ操作の SCK(ScreenCaptureKit)フレーム配信(DeviceHub/Emulator ウィンドウをキャプチャ、実装後ユーザー判断で撤回) | 実装は完動した(較正=ブリッジ実スクショとのテンプレートマッチ、~30fps)がキャンセル。実装時の実測知見: ①多数フレームワークをリンクした大型 CLI(fleetest 本体)から SCK を呼ぶと macOS 27 beta で replayd 接続が再接続ストームになり await が無期限ブロック(Task.sleep も不発)→小型 @main 単体バイナリへの隔離が唯一の安定解 ②CLI からは NSApplication.shared(CGS 初期化)が先に必須 ③captureImage は要求キャンバスへスケールせず実効スケールで左上描画+透明パディング→倍率は不透明領域境界から検出する ④非表示ウィンドウへの captureImage はエラーでなくブロック=isOnScreen 必須 ⑤解像度は画面上のウィンドウサイズ依存(原寸スクショより低い) | 高fpsのライブ映像が再び必要になったら(実装の骨子はこの行と git 履歴のこのコミット前後を参照) |
| エミュレータの Vulkan 有効化(`-feature Vulkan`)と HWUI の skiavk 化(guest UI 描画を GLES→Vulkan へ) | 2026-07-14 A/B 済(emulator 36.6 / Pixel 9 A16 / -gpu host)。**`-gpu host` の時点で gfxstream+host Vulkan(MoltenVK)は既定で有効**(起動ログ `vulkan_mode_selected:host`)のため `-feature Vulkan` は実質無操作。残る HWUI skiavk 化(`setprop debug.hwui.renderer skiavk`、Pipeline=Skia (Vulkan) 確認済)も同一スワイプ10回の qemu CPU が 10.6s→11.1s と改善なし(むしろ微増) | emulator が Apple Silicon で HWUI Vulkan を既定化したら、または ANGLE 変換(GLES→Metal)がプロファイルで支配的と実測されたら |
| デバイス側動画ストリーミング(iOS=simctl recordVideo、Android=screenrecord/scrcpy + ffmpeg。2026-07-14 の当初 spike で不成立。ただし iOS はその後 fleetest-simstream で成立→理由欄の追記参照) | **追記(2026-07-14以降): iOS のヘッドレス映像ストリーミングは別方式で成立済み**(`fleetest-simstream`=CoreSimulator/SimulatorKit の private API `SimDisplayIOSurfaceRenderable` の IOSurface を `setPowerState:1` で起こし、フレーム単位に JPEG 化して長さ前置で stdout へ。simctl でも ffmpeg でもないため下記の不成立要因を構造的に回避。ヘッドレス=Simulator.app 非起動で mid-run・ネイティブ解像度・静止時ほぼ0fps を実測確認。ライブ操作タブ+デバイスモニタータブの両方で採用。実装: `Sources/fleetest-simstream/main.m` / `vscode-fleetest/src/deviceStream.ts` / `monitorDeviceStreamController.ts`。**「iOSストリーミングは不可能」と誤読しないこと**)。**以下の「不成立」は simctl recordVideo と ffmpeg パイプ方式に限った当初 spike の結果**。画像取得ポーリングの負荷対策として検討し、その2方式は両OSとも不成立だった。**iOS**: `simctl io recordVideo` は stdout(`-`)を「rendering to standard out is no longer supported」で拒否、ファイル/FIFO 出力も非フラグメント(moov を SIGINT 時に確定書き込み、`has_moof: False`)=録画停止まで1フレームも復号不可。**Android**: `adb exec-out screenrecord --output-format=h264 -` の生H.264を **ffmpeg にパイプ入力すると EOF まで出力をバッファしライブ逐次フレームが出ない**(実測: 同じH.264をファイル入力なら41フレーム復号できるがパイプ入力は mid-run 0。`-flush_packets1`/`-threads1`/`-use_wallclock_as_timestamps`/`-avioflags direct`/`-fflags nobuffer -flags low_delay`/fps有無/mpjpeg・image2pipe・image2個別ファイル の約16構成すべて mid-run 0。adb はパイプへ逐次配信済=adb 原因ではない。ffmpeg はライブ入力 lavfi なら逐次フラッシュするので raw-h264 パイプ demux の仕様的限界)。scrcpy 録画→FIFO(mkv)もクラスタバッファでライブ不可(frame=0)。**採用した代替=ライブの frameTick を旧 delayMs=0 ホットループから `fleetest.liveFps`(既定12)頭打ちに変更**(iOS/Android 共通・依存ゼロ・負荷源そのものを解消) | **iOS は fleetest-simstream で解決済み(理由欄の追記)。以下は Android 向け**: Android で真の映像ストリーミングが必要なら **GStreamer 未検証**(`fdsrc ! h264parse ! avdec_h264 ! jpegenc` はライブパイプ前提設計で ffmpeg のバッファ問題が無い可能性)。ただし heavy dep(`brew install gstreamer`)の再導入になる |

| metal-errors(emulator ログの Metal エラー計数)を凍結対策の判定材料に使う(タイル警告表示・自動回復のトリガ) | 2026-07-26 フリート8台の全数検証で**個体を分離できないと確定**。凍結した個体は累積(2486)でも増加速度(128/分)でも最上位ではなく、健全機の方が高い(2560 / 288 分)。ログのタイムスタンプ集計でもエラーは全機の同一時間帯(run 実行中)に一斉発生=ホスト GPU ドライバ由来の背景現象。閾値 100 は艦隊のほぼ全台で常時成立するため、表示は無意味なノイズ、再起動トリガにすると毎セッション全台再起動になる(しかも凍結を防げる根拠がない)。**タイル表示を撤去し、回復の検討対象から外した**(計測と `metal-history.ndjson` への記録は劣化分析用に継続) | 「高カウント機だけが凍結する」対応が実データで示されたとき(異常機と健全機を並べた比較が必須。1個体の数字では判断しない) |

| gRPC 生成コードの削減(`third_party/emulator-proto/emulator_controller.proto` を使用 RPC だけに絞って再生成する) | 2026-07-29 実測で**コストの所在が違うと確定**。`Sources/FTEmulatorGrpc/Generated/` は 13,519行(Sources 全 Swift の約40%)で 実使用は 46 RPC 中 5 つ(getScreenshot/sendKey/sendTouch/getStatus/setVmState)だが、M2 Ultra の実測は **クリーンビルド全体 99.3s に対しモジュール単体の再コンパイルは 8.9s(9%)**。gRPC スタックのみのクリーンビルド 73.7s から 生成コード分を引いた**約65秒は grpc-swift-2 / NIO / SwiftProtobuf の依存ビルドで、proto を削っても 1 秒も減らない**。さらに生成コードは変更されないため**増分ビルドでは再コンパイルされない**(日常コストはゼロ)。削減は楽観でも6〜7秒で、upstream proto の verbatim vendoring(差し替えるだけで追従できる)を失う対価に見合わない。**行数からビルドコストを推定したのが誤り**(比例しない) | 生成コードのコンパイルがクリーンビルドの支配項になったとき(必ず先に実測する。計測は `swift build --scratch-path <別ディレクトリ>` で実 .build を壊さずに行える) |
| 実行時の同時実行数の上限設定(実行プロファイルに per-platform の maxConcurrent を持たせる) | 2026-07-29 ユーザー決定で不採用。**同時実行数は実行プロファイルに載せるデバイス台数で手動管理する**。PT-8 の「iOS 並列度の上限」は 10台同時の AX スパイクが根拠だが、上限はレーンを減らす方向にしか効かず、PT-3.6 の「185秒→約121秒」は iOS のレーンを**増やす**ことで得られる数字なので別問題(こちらは配分=プロファイル記述の話)。代わりに実行後のレーン稼働表示だけ実装した(制御はしない。`LaneBalanceAdvice` / ProfileRunner の `📊 Lane utilisation`) | なし(手動管理の方針ごと見直す場合のみ) |
| `scrollToEdge` の署名に座標の量子化を入れる(端のバウンスで収束しない対策) | 2026-07-30 実測で**前提が再現せず不採用**。Android/WebView でスワイプ後に 8 回連続 snapshot しても y は完全に同一(整数値・ジッタなし)で、cap 打ち切りも起きなかった。実際の内訳は E2E-Flutter の `scrollToTop` 9,094ms に対し **actionMs 5,489ms(60%)/ snapshotMs 2,252ms / waitMs 1,333ms** で、**支配項は待ちでも収束失敗でもなくドラッグ操作そのもの**。しかもその所要は `hintDrag` の `min(max(|Δy|/2500, 0.3), 0.7)` = 意図したジェスチャ時間で、縮めるとフリングの物理(スクロール距離は速度依存)が変わる。量子化は「まだ動いているのに静止」と誤判定する実害リスクだけが残る。**追記(2026-07-31): 収束しない事例は実在したが原因は座標ではなくラベルだった** — SwiftUI List(E2E-iOS/ios-xcuitest)では静止画面でも画面外の再利用セル 2 件が取得のたびに別の行のラベルを名乗り A↔B で交互に振れ続ける(frame は 1pt も動かない)。**署名からラベルを外して解決済み**(`settledSignature`。cap 打ち切りが 2/3run → 0、`scrollToTop` の最悪 56s→17s)。当時 Android/WebView で再現しなかったのは**フレームワークが違ったから**で、量子化の不採用判断そのものは変わらない | 座標のジッタで収束しない事例が**実データで**観測されたとき(署名の連続比較をログに出して確認する。1 個体・1 回の観測では判断しない)。**ラベル由来の非収束は解決済みなので、それを根拠に量子化を再提案しない** |
| モニター常駐負荷の最適化(ポートスキャンの URLSession 32個/2秒・`canonicalAVDID` の毎サイクル再計算・emulator ログ読み) | 2026-07-30 実測で**最適化の余地なしと判明**。通常ビルドの monitor の CPU は 20 秒窓で **0.0%**(cputime 10ms 未満)。コード上は「32 ポートへ毎周期 `BridgeClient`(=`URLSession`)を作る」「`canonicalAVDID` が毎周期 `installedAVDs()` を呼ぶ」は事実だが、ローカルの閉じたポートへの接続は即 RST で安価。**当初 17.3% と観測したのは TSan 入りバイナリを掴んだ残存プロセス**で計測アーティファクトだった(PT-7)。なお「プロセスタブが**ガード無し**で 1 秒ポーリング」という指摘は誤りで、`processesTab.js` に表示中のみ回すガードがある | monitor の CPU が実測で有意になったとき(**必ず通常ビルドのプロセスで測る**) |
| プロファイル外デバイスの旧版ブリッジを provision が自動で掃除する | 2026-07-30 検討。`BridgeProvisioner` の stale 掃除は **`sameDevice` 条件**で「今まさに供給するデバイス」の分しか見ないため、プロファイル外に残った旧版ブリッジは誰も片付けない(実害: protocolVersion 4 のランナーがポートとシミュレータを 7 時間 22 分占有)。条件を外せば自動化できるが、**別ワークスペースが正当に使っているブリッジを殺す**危険がある(このリポジトリに「別クローンの資産を勝手に停止する」前例は無い)。代わりに **`fleetest doctor` が報告だけする**(停止しない)ようにした | 「同一マシンで複数クローンを併用しない」が前提として確立したとき |
| 録画クリップ切り出しの O(N²) 解消(`VideoRecordingFinalizer.extractClip` がクリップ 1 本ごとにソース動画**全域**から `AVMutableComposition` を組み直す) | 2026-07-30 精査で**意図的な設計と確認し、据え置き**。ソース総尺に比例することは呼び出し側が前提にしており、`VideoRecordingCoordinator` の `exportDeadline` がその比例分を織り込んで期限を決めている(コード内に明記)。効くのは `record: true` の run だけで、既定では走らない。さらに AVE 無応答によるハングには期限+断念ブレーカ+並列2の対策が既に入っている。区間ごとにソースを絞る最適化は、クリップ境界がソースファイル境界を跨ぐ場合の切り出し規則を作り直すことになり、**録画の正しさ(取りこぼし)に回帰が出る側**の変更になる | 長時間 run の `record: true` が常用ワークフローになり、書き出しが実測で run の支配項になったとき(まず1本あたりの `extractClip` 実測を取る) |
| CMP(iOS)の launch を縮める(SwiftUI より約 0.8 秒遅い) | 2026-09-18 に内訳を測り**アプリ自身の起動時間と確定**。in-app の launch の待ちは「ブリッジの `/status` が答えるまで」で、`/status` は**アプリのメインスレッドで**答える(`mainSync`)= アプリが起動処理を終えてメインスレッドが空くまで返らない。差はこの待ちだけ(CMP 2895ms / SwiftUI 2106ms・起動の指示は 4 SUT とも 0.7〜0.8 秒)で、**仕組みの違う XCUITest の launch でも同じ差**(CMP 3748ms / SwiftUI 2948ms)。ツール側の待ち方(80ms 間隔のポーリング)は全 SUT 共通 = 削れる部分が無い | CMP の起動が他の SUT と同じ速さなのにlaunch の待ちだけが長い、という逆の形が実データで出たとき |
| Android の autoInstall 差分判定に指紋キャッシュを入れる(iOS の `InstalledAppCheck` 方式を移植) | 2026-07-30 実測で**効果が小さく不採用**。ゲスト内 `md5sum` は 156MB の APK でも **0.30s**(3回とも安定)、run 全体への寄与は **+0.70s**(ワーカー構築 0.54s→1.24s。11MB の SUT との A/B)で、40 秒級の run の **1.75%**。しかも 156MB は E2E の SUT で突出しており、他(11MB)では差がほぼ出ない。一方で指紋キャッシュは**新しい状態ファイルと失効管理**を増やし、失敗モードが「アプリを入れ替えたのに古いまま実行される = 静かに誤った結果」方向になる(iOS 側は `get_app_container` の実在確認を併用して erase を検知している)。0.7 秒のために払う複雑さとして見合わない | APK が数百 MB 規模になり、`md5sum` が run 固定費の支配項になったとき(**まず `FT_PHASE_LOG=1` でワーカー構築フェーズを測る**) |

## PT-7 既知の落とし穴(ベンチ・検証時)

- **画質などを「最高品質の条件」を基準に比べない**。録画の OCR 比較(PT-3.31)で、基準の文字列集合を
  3000kbps・フル解像度のクリップ自身から作ったため、その条件だけ再現率が高く・誤読が 0 に出た(自分と比べているだけ)。
  **全条件の多数決(8条件中3条件以上で読めた文字列)を基準にし直すと差は消えた**。基準は被験条件から独立に作る。
  あわせて、偽のドライバで撮影のファイル名(ミリ秒)が衝突する・静止画の枚数はクリップのコマ数で数え直す、も踏んだ
- **1回の計測で性能を結論しない**。壁時計は「コールドスタート初回の供給オーバーヘッド」
  (デバイス起動直後の初回はブリッジ供給に +40〜50s 乗る)と「一過性のブリッジ切断+振り直し」
  (in-app が高負荷で応答不能になり別デバイスへ振り直し=再実行、1本 ~60s)で大きく揺れる。
  どちらも定常性能ではない。**各プロファイル 2〜3 回計測し、レポートの「振り直し」件数を確認**して
  定常値を取る(初回1回だけ見て「135s の外れ値・構造的脆さ」と誤評価し、再計測で定常 36s と判明して
  撤回した実害あり。2026-07-23)。振り直しは E2E ログの `🔁 Results discarded and requeued` で数える
- **iOS設定のデバイス画面.S0010 は iPhone Air に割り当たると決定的に失敗する**
  (PHOTOS_UPLOAD_DEVELOPER_MODE スイッチが Air では OFF というシナリオ設計起因)。
  N=3 のベンチ成功率が揺れるのはこのデバイス割当のくじ引き。高速化の回帰と混同しないこと
- runs プロファイルに片 OS のデバイスだけ指定すると、他 OS 専用シナリオは
  スキップされず失敗扱いで実行される。ベンチは `--scenario` で対象を絞る
- VSCode 拡張の monitor / host-metrics 常駐プロセスは、バイナリ再ビルド後も
  旧バイナリのまま生き残り、ベンチの CPU を汚したり旧ブリッジを自動再起動したりする。
  計測・APK 更新検証の前に Reload Window するか手動 kill する
  - **特に危ないのは sanitizer 入りのバイナリを掴んだまま残ったプロセス**(2026-07-30 実害)。
    TSan で調査したビルドから起動した monitor が生き残り、**CPU 17.3% を常時消費**していた。
    同時刻の別 monitor(同一リポジトリ・通常ビルド)は **0.0%** で、比較しなければ
    「monitor の常駐コストは 0.17 コア」と誤結論するところだった。
    **切り分け**: `sample <pid> 10` の Binary Images に `libclang_rt.*san` が居ないか見る。
    プロセスの起動時刻(`ps -o lstart=`)とバイナリの mtime を比べれば、掴んでいるイメージが
    古いことも分かる(`otool -L` は**ディスク上の現在のファイル**を見るので判定に使えない)
  - **別クローンから起動した常駐プロセスも混ざる**(実害: `~/Downloads/fleetest-mobile` の
    monitor が 1 日以上稼働し 3.6% を消費)。`ps` で**実行ファイルのパスまで**確認する
- ブリッジは単一スレッドなので、整定待ち中(最大 2s)はモニターの /screenshot が
  順番待ちになる(ベストエフォート表示のため許容している。仕様)
- `UiAutomation.setOnAccessibilityEventListener` は**1 枠しかない**。QuietWaiter が
  使用中なので、別用途でリスナが必要になったら QuietWaiter 経由で多重化すること
- 長時間ベンチ中の画面ロックに注意(GUI E2E 全般の既知問題)
- **フォールバック検証の誤検知(緩和済み)**: inapp-boost モードでシステム UI を tap するとき、セレクタの
  label が in-app の要素 label の**部分文字列**だと primary(in-app)が `contains` で誤解決し得た。
  現在は tap アクション経路で **primary が部分一致(substring)止まりなら fallback を照会し、
  fallback に完全一致(exact)があれば fallback を優先**する(`StepExecutor` の resolveDetailed/
  matchDetailed。primary が exact のときは fallback を照会せずコスト増なし)。
  **素の文字列は完全一致だけ**なので、この経路に入るのは `*語*` 等の部分一致を
  明示したときに限られる(判定は記法ではなく掴んだ要素。`LocatorResolver.quality`)。ただし `exist()` 等の
  アサーション経路は従来どおり(部分一致の存在確認は許容)なので、確証が要るときは
  **同一シナリオを XCUITest ブリッジを持たない in-app ブリッジ単独(フォールバック無)でも走らせ当該 tap が失敗することを確認**
  (negative control)。
- **inapp-boost モードでも XCUITest へ回る type がある**: 改行を含む文字列(iOS の Return キーの既定の挙動に揃えるため。
  `StepExecutor` が typeDriver を優先する)と、in-app ブリッジが 409 等で打てなかったとき(ロケータ付きは `StepExecutor` が
  `DriverError.isTextInputFallback` で、ref なしは `HybridFallbackDriver.type` が退避する)。それ以外は Compose を含めて in-app で打つ
  (`ScenarioRunnerMain` の `preferTypeDriver` は常に false)。XCUITest 経路の type は in-app より数倍遅い
  (Compose の実測で in-app 266ms・XCUITest 1.0〜1.3s)。type を含むシナリオの時間比較・回帰判定では、
  XCUITest へ回る type の数を揃えるか除外して比べる(改行入りは文字列で、退避はステップの注記で分かる)。
- **通知許可ダイアログのリセットは `simctl privacy` では効かない**(あれは TCC=写真/連絡先等)。
  通知権限は**アプリ再インストール(uninstall→install)でのみ未決定に戻る**。ダイアログ系の
  fixture を繰り返し検証するときは各回 reinstall する
- **アニメーション有効デバイスでは静穏判定後もアニメが画面を動かすため画像が stale になる**
  (a11y要素はFRESHだがscreenshotだけSTALE、という形で顕在化)。ブリッジ起動時と**run 開始時**に
  window/transition/animator の `*_scale` を自動で無効化する(2026-07-12組込み)。
  実機を追加したときも同様に自動適用される。
  **見た目の確認や録画のためにアニメーションを残したいときだけ**実行プロファイルの
  `enableAnimations: true`(GUI は実行プロファイル設定「アニメーションを有効にする」)にする。
  その場合は整定待ちが伸び、上記 stale の実害が戻る前提で使うこと(既定に戻すべき設定)
- **常駐 CLI は stdin EOF で即終了する**(`fleetest api {host-metrics,live serve,monitor}`、
  `fleetest-simstream`、`fleetest-androidstream`。拡張は stdin パイプを開いたまま保持している)。
  アドホックに spawn して計測・検証するとき、stdin を /dev/null 継承のまま渡すと即座に EOF を検知して
  終了し、0 サンプル/0 フレームになる(静止時の 0 と区別がつかず「helper が壊れた」と誤診しやすい)。
  子プロセスの stdin は開いたまま保持すること(`subprocess.Popen(..., stdin=PIPE)` で閉じない等)
- **タイル黒+「接続中/ブリッジ応答なし」が続く=ブリッジ死を疑う**(XCUITest ランナーの HTTP
  サーバだけ死んで xcodebuild 親が残ることがある。実例: 2026-07-14)。確認は
  `curl -m 3 localhost:<port>/status`、復旧は `fleetest devices up --profile <名>`
  (死んだポートだけ再供給される)。拡張のウォッチドッグが自動修復するが、
  `fleetest.autoRepairBridge` を OFF にしている場合や CLI 単独運用ではこの手順で
- **稼働中デバイスへ simstream/androidstream を並走 spawn して計測しない**(本番ストリームが
  不安定化し、webview の codecError→mjpeg フォールバックやストリームのギブアップを誘発した実例
  あり)。ヘルパー単体のベンチはモニターが掴んでいないデバイスで行う
- **「CPU 100% 張り付き+GPU は暇」はエミュレータのソフトウェア描画(SwiftShader)を疑う**。
  判定は `adb shell dumpsys SurfaceFlinger | grep GLES:`(SwiftShader なら CPU 描画、
  `Apple M1 ...(Metal)` なら host GPU)。DeviceBooter は `-gpu host` 起動で対策済みだが、
  手動起動のエミュレータや AVD 設定変更で再発しうる(headless では hw.gpu.mode=auto が
  SwiftShader に落ちる)
- **画面凍結(白フレーム固着)の真因は `-gpu host` + headless + macOS 27 / emulator 36.5.10**
  (切り分け実測 2026-07-17)。症状: ゲストは健全(`mWakefulness=Awake`・screen ON・adb/a11y/入力可)
  だが `screencap`/`screenrecord` が一様白(PNG 10-16KB)を返す。起動後 0〜3 分でランダム発生、
  約25秒周期でフラッピングする個体もある。**切り分け手順**(再発時の検証テンプレ): 空き AVD を
  `emulator -avd X -port P -no-window -no-snapshot -gpu <mode>` で直接起動(モニターのプロファイル外=
  stream されない)し、GPU モードだけ変えて同一ホスト・同一負荷で `screencap -p | wc -c` を比較。
  実測: host は screenrecord 有無問わず凍結、swiftshader_indirect は約20分健全。**readback(screencap/
  screenrecord)は真因でなく不安定な緩和**(アイドル host 機は readback ゼロだと確実凍結、readback で
  一時回復するが高負荷下では screenrecord 稼働中でも再凍結する)。根治は GPU モード変更(PT-5・PT-6・
  DS-12.3)。対処: 凍結個体だけ swiftshader へ per-device フォールバック(DS-12.4)
  - **トリガと軽量修復(対照実験 2026-07-25)**: 発生条件は**複数エミュレータの同時描画**
    (8台並列 run 中のみ発生。アイドル・1台単独への同一負荷では発生ゼロ=デバイス自身の負荷ではなく
    ホスト GPU の並行合成競合)。固着型は **`input keyevent KEYCODE_SLEEP`→`KEYCODE_WAKEUP`
    (表示パイプラインの無効化→再合成)で修復できる**。readback では回復しない。
    run 前の blank トリアージ(ProfileWorkerFactory.excludeOrRepairBlankScreenWorkers)はこの修復を
    先に試し、不発なら guest reboot を同期発行してブート完了を待ち、**どちらで直っても本 run で
    使う**=ワーカー全数維持(実装 AndroidHealthProbe.repairBlankDisplay。watchdog ラダーの
    第一手 adbWifiRepair.repairDisplay も同一手順)。修復は免疫ではない(次の並列描画で再発し得る)。
    **ホスト側証跡は `~/Library/Logs/fleetest/emulator/<AVD>.log`**(DeviceBooter が emulator
    stdout/stderr を保存・ブート毎 truncate。2026-07-25 実装)。根因の
    `GLDRendererMetal command buffer completion error` / `IOGPUCommandQueueErrorDomain 518` は
    ここにしか出ない(統合ログ・crash レポートは無音のまま)。**Metal エラー行数は劣化の定量指標**:
    健全ブートは 0〜2 件、劣化個体は数百件まで単調増加し高カウント個体が凍結する
    (スケール実測 2026-07-25: N=8 で 0〜30 → N=16 で最大 513/デバイス)。
    ただし**個体の異常判定には使えない**(2026-07-26 フリート全数検証): 実際に凍結した個体は累積
    カウントでも増加速度でもフリート最上位ではなく(凍結機 2486 件/128 件毎分に対し健全機は最大
    2560 件/288 件毎分)、ログのタイムスタンプ集計でもエラーは全機の同一時間帯(run 実行中)に
    一斉発生していた=ホスト GPU ドライバ由来の背景現象。health プローブは行数を数え閾値 100 で
    `metal-errors` を載せ続けるが(AndroidHealthProbe.issueMetalErrors)、**モニタータイルには
    表示せず・修復アクションも取らない**(monitorHealthWatchdog が actionable から除外。
    ユーザー決定 2026-07-26)。用途は下記の時系列記録による劣化分析のみ
    カウントの時系列は `~/Library/Logs/fleetest/emulator/metal-history.ndjson` に残る
    (MetalErrorHistory。変化時のみ追記・5MB 超で `.1` へロールオーバー)
  - **凍結の変種と修復応答(修復パラメータの根拠)**: ①瞬間ブリップ(数秒で自己回復。アプリ起動
    白画面の誤検知も混在し得る)②自然回復型(~30s)③固着・修復可(sleep/wake 1サイクル dwell 1.5s
    ≈4s で回復=最多)④固着・抵抗型(1サイクル+wake後6s待でも blank のまま。**dwell 3s の
    2サイクル目で回復**)⑤固着・難治型(sleep/wake ×3・回転トグル・wm size 再構成すべて不発。
    **guest reboot でのみ回復**。稀)。repairBlankDisplay/repairDisplay は ③④ を拾う2サイクル構成
    (成功 ~4s・抵抗型のみ ~11s)。⑤は run 前トリアージの guest reboot(同期・ブート完了待ち)/
    watchdog の後段(swiftshader 再起動)に落ちる設計。
    ⑥出生凍結(高並列下の新規ブートが最初から凍結。guest reboot・プロセス再起動も不発、
    swiftshader なら健全。N≈12〜14 から確率的に発生)⑦アプリ面だけ黒(壁紙・ステータスバー・IME は
    正常だが新規アプリウィンドウが全て黒。sleep/wake 1〜2サイクルで回復。**IME 等が写ると一様
    フレームにならず blank プローブに掛からない**=モニタータイル目視が現状唯一の広域検出)
  - **故障面は2つあり独立に壊れる(2026-07-25 スケール実測)**: (a) guest readback 白化
    (`adb screencap`=白 10-16KB だが gRPC getScreenshot=実画面。表示は生きておりテストも通る)
    (b) host キャプチャ黒(gRPC=一様黒 51KB だが adb=実画面)。切り分けは**両経路スイープ**
    (adb サイズと gRPC PNG デコード一様判定を並記)で行う。**gRPC 経路の blank 判定に PNG
    サイズ閾値を使わないこと**(emulator のエンコーダは一様黒でも 51KB を出す。30KB 閾値は
    adb 較正。gRPC 経路は画素一様判定 AndroidHealthProbe.uniformFrame)
  - **スケール上限(2026-07-25、N=8→16 段階実測)**: シナリオ成功率は表示層の崩壊と独立
    (N=16・凍結9/14台でも全段 18/18=**成功率は劣化の指標にならない**)。run 後の凍結台数は
    N=8 で 2 → N=14 で 9。**実用上限は 8 台+定期再起動**。10 台超で劣化加速、12 台超は新規ブート
    自体が信頼できない(⑥)。**劣化個体はアイドルでも CPU を空転消費**(実測 ~73%/デバイス)し、
    ホスト全体を遅くする(iOS の6ワーカー同時コールド launch が一律 +3.3s 遅れた実害。
    run が遅いときは top の qemu と run 同梱 host-metrics.ndjson を先に見る)
- **シミュレータのコールドブート直後は Spotlight インデックスが計測を汚す**: 設定トップに
  「検索とSiriを最適化中」行(id=com.apple.settings.spotlightIndexingProgress)が挿入され、
  CPU も食う(負荷下ではタイムアウト失敗を誘発。完了まで10分超の個体もある)。ベンチ前の
  整定ゲートは「設定トップの snapshot からこの id が消えるまで」で判定できる
- **エミュレータの初回コールドブートはゲスト内スワップで数分間激遅**(2GB AVD+Play サービスの
  学習ジョブ等。1シナリオ約3分の実例)。ホスト側 qemu CPU% は低くても遅い(メモリ/IO バウンド)。
  判定は `adb shell top` の Swap 使用と idle%、または1シナリオのプローブ実行(正常なら数秒)
- **シミュレータの表示名重複はブリッジ再利用のマッチングを壊す**(/status の device はシミュレータ
  表示名のため)。同名機が居ると毎回新規ブリッジ起動→供給タイムアウトの連鎖になる。
  `simctl rename` で一意にする
- **失敗が特定シミュレータ個体に集中したら(タップ後の画面遷移が起きない等)、その個体の再起動を
  先に試す**(shutdown→boot で解消した実例。セレクタや負荷を疑う前に個体差を除外する)
- **XCUITest ブリッジの3本目以降は負荷下で供給タイムアウトしやすい**。タイムアウト後に遅れて
  ready になり、次回の実行で「稼働中ブリッジを再利用」して成功する(=1回おきに成功・失敗が
  交互になったらこのパターン)。恒常的に3台以上の iOS 並列を使うなら供給タイムアウト延長か
  供給の直列化を検討(PT-8)。※この実測は供給が直列だった時代のもの。2026-07-15 の並列供給化
  (PT-3.2)後は無負荷コールドの 3 台 inapp-boost モード(6 ブリッジ)は成立を確認済みだが、負荷下の挙動は
  未再計測(悪化しうる方向なので交互パターンを見たらまずここを疑う)

- **iOS ブリッジのウェッジ(接続は受けるが無応答)の診断手順**: ① `curl -s -m 2 -o /dev/null -w "%{http_code}" http://localhost:<port>/status` で 000 なら無応答(200 が健全。ポートは 8123〜)。② run が固まって見えるときは `lsof -p <run pid> | grep ESTAB` — ブリッジポートへの ESTABLISHED が動かないのは無応答待ち。③ `sample <pid> 2` で全スレッドが workq/mach_msg でパーク+CPU 0% なら「返らない await」(死活確認系は withDeadline 必須。DS-12.4)。復旧は `fleetest bridge down --port <N>` で該当だけ停止(次の供給が作り直す)。**このコマンドは自リポジトリの `.fleetest/` に記録があるブリッジしか止められない** — 別クローンが起動したものは「the bridge on port <N> is not managed by this repository」と出るので、起動元のクローンで止めるか `lsof -ti :<N>` のプロセスを止め、iOS は `xcrun simctl terminate <udid> com.example.ftrunner.uitests.xctrunner` まで行う。**残存ブリッジの一覧は `fleetest doctor`** が出す(版が古い/記録が無いものを報告。停止はしない)
- **XCUITest ランナーの起動 ≈25〜30s/本はビルドではなくセッション確立コスト**(`xcodebuild test-without-building`=ランナー .app の sim へのインストール+XCTest セッション確立+/status 応答まで。共有ビルドはキャッシュで通常 no-op)。さらに供給は ProvisionLock(クロスプロセス flock、ポート採番の bindFailed(48) 対策)で直列化されるため、**壊れたブリッジが多いと run 開始が 10s→70〜80s 化する**。健全なフリートなら再利用スキャン(2s タイムアウト)だけで 1〜2s
- **iOS 10台同時のシナリオ第一波で AX スパイクが起き、健全なブリッジも数秒〜数十秒 /status に応答しなくなる**(2026-07-18 実測: 一斉離脱後の計測で 12本中11本が 200=一過性)。短い期限の死活確認はここで誤判定する(PT-6 プレフライト不採用の根拠)
- **Swift 構造化並行の罠: `withTaskGroup`+`cancelAll` はキャンセルに応答しない子タスクの完了を待つ**。ウェッジ機への URLSession(120s/リクエスト)を子に持つと、期限側が勝っても遅い方を待ち続けて run 全体が凍結する(実測: 全スレッドパークで5分以上)。死活確認の期限は「先着確定レース+遅い方は放置」(RunOrchestrator.withDeadline)にする
- **孤児ブリッジ累積で連続 run が逓減する(根本原因と2修正・2026-07-25 確定)**: in-app ブリッジは
  対象アプリが背面化で suspend されると TCP 受理・HTTP 無応答になり `scanRunningBridges`(/status)に
  映らない=再利用も stale 停止もされず、inapp-boost モードの run のたびに `.inapp` 状態ファイルが1デバイス1本ずつ
  積もる(実測: xcuitest↔inapp-boost 切替を繰り返すと 6→12→…)。さらに scan の /status プローブは
  引数なし `status()` が `sessionTimeout`(=Timeout.session=45s)を per-request の timeoutInterval に
  上書きするため、`BridgeClient(timeoutSeconds:2)` の 2s が効かず、**suspend ゾンビ1本で scan 全体が
  並列でも ~45s 待つ**(本数に依らず固定 ~45s。18本の合成でも 46s)。結果 iOS 壁時計が実行時間そのままに
  ~45s 逓増する。修正: ① `scanRunningBridges` を `status(timeout: 2)` にして本数に依らず ~2s 頭打ち、
  ② inapp 起動前に同 UDID の再利用対象外ゾンビを PortHolder で掃除し発生源を止める(`reclaimInAppOrphans`。
  blind な `simctl terminate` は同アプリ別ポートの稼働中ブリッジを誤殺し実行中ワーカーを連鎖死させる
  実害があるため使わない)。いずれも `BridgeProvisioner.swift`。手動掃除は `fleetest bridge down --all`
- **iOS 壁時計だけ伸びて「テスト実時間」が一定なら供給/scan を疑う(アプリサイズではない)**:
  install 深比較や SUT サイズを疑うのは誤り。実測で native 1M ≈ Flutter 94M ≈ 同じ ~47s overhead=
  サイズ無相関、真因は上項の孤児ブリッジ scan だった。フェーズ内訳は `FT_PHASE_LOG=1 fleetest run ...`
  (`ios-workers-start→ios-workers-built` が provision=scan+catalog。ここが膨らむ)
- **`simctl list` は ~0.5s の固定費(件数非依存)**: 279件でも booted 6件でも 0.57 vs 0.45s=
  CoreSimulator 呼び出し自体のコストで、クエリを狭めても縮まない(booted 限定は未ブート対象の
  resolve を壊すので不可)。provision は catalog を1回取得して scan/resolve で使い回す=per-run は
  1回で最小(これ以上削れない)。start-all-devices だけは 2回/デバイス(DeviceBooter の boot 確認+provision)だが、
  boot 中はデバイス状態が変わり catalog キャッシュは誤認を招くうえ効果も ~1% なので見送り

## PT-8 今後の改善候補(価値が出たら)

**この節は候補と完了記録が混在している**。「iOS の XCUITest 税」の項(2〜4)は**実装済みの記録**で
候補ではない(in-app 常駐ブリッジ・inapp-boost モードは既定で動いている)。候補として読むのは各行の
✅/❌/不採用の印が無いものだけ。

- ✅ **SpringBoard の劣化を検知して起こし直す**(PT-3.36 で実装)。効果がどれだけ続くか(再劣化までの時間)は未計測 ——
  再劣化が早いならシミュレータの再起動へ切り替える(既に供給の経路は「起動し直しで直らなかった」印でシミュレータを再起動する)
- **iOS 並列度の上限設定(実行プロファイル)** → **2026-07-29 ユーザー決定で不採用**(PT-6)。
  同時実行数は実行プロファイルに載せるデバイス台数で手動管理する。ただし
  「ブリッジウェッジの根本原因は 10台同時の AX スパイク(シナリオ第一波で健全ブリッジも無応答化)」
  という観測自体は有効なので、台数を決めるときの根拠として残す。実装したのは実行後の
  レーン稼働表示だけで、制御はしない(`LaneBalanceAdvice`)

- ✅ **失敗パスの調査効率**(2026-07-30 に記述を実態へ更新。**FM トリアージは 2026-09-15 に
  撤去** → MN-21): 旧記述の「タイムアウト時の
  最終 snapshot 添付(調査 1 往復化)は未実装」は**誤り**。失敗時には**要素一覧
  (`SnapshotRenderer`)・スクリーンショット・手前を覆う別 window の警告・
  白フレーム警告・修正提案**をレポートへ書き出している
  (`FTRuntime.handleFailure` → `ScenarioReportWriter`)。「timeout(5s×箇所)が支配」も
  **失敗は即シナリオ中断**(2026-07-27 決定)以降は 1 シナリオ 1 回で支配項ではない。
  なお **fail-fast 化は最適化ではなくトレードオフ**で、occlusion-guard は過渡的オーバーレイ
  (ローディング・スナックバー)が消えるのを timeout まで待つよう**意図的に**作られている
  (`StepExecutor+Assert.swift`。即失敗は脆い)
- ✅ **interop ホストの WebView 画面を「読みは DOM・触るのは XCUITest の座標」にする**
  (2026-08-02 実装。PT-3.13)
- ✅ **WebView 画面のスクロールヒント跳躍を iOS xcuitest でも発火させる**(2026-08-04 実装):
  未発火の原因はホスト側ではなく**供給の欠落**だった(XCUITest は WKWebView 配下の画面外ノードを
  実座標で報告するが、ランナーの画面交差ガードが落としていた。Android だけが
  `SnapshotResponse.offscreen` を供給していた)。ランナーが Android と同じ契約で供給するように
  変更(bridgeProtocolVersion 46)。実測(WebView シナリオ・アイドル3周 A/B・全3 SUT):
  scrollTo −22〜31%・scrollToTop CMP/Flutter −16%(SwiftUI 中立)・シナリオ全体 34.1→30.4s(−11%)。
  **inapp-boost モードには供給しない**(`WebViewDelegatingDriver` が落とす。contentOffset 短絡の方が速い)。
  残る床は `scrollToEdge` の毎周 `settledSignature`(WebView は snapshot 1枚 300〜500ms かかり、
  端確定に最低2周 = 減速中に比較すると早すぎる端判定になる実害由来で単純には外せない)と
  Web コンテンツの AX 活性化待ち(`exist` 3〜4s・ブリッジ差なし)。
- ✅ **`scrollToEdge` の端確定をヒントに任せる**(2026-08-05 実装。上の「再設計が要る」の答え):
  端は「署名が2回続けて不変」で判定していたが、**2回目は Android のフリング停止で1回空振りする
  形への保険**で、その代償として**端に着いてから捨てのスワイプを2回撃っていた**。
  `SnapshotResponse.offscreen` は「その方向にまだ内容があるか」の**肯定的な証拠**なので、
  ヒントを供給する画面(= WebView)でだけ**不変1回**に下げる(`StepExecutor.unchangedRoundsForEdge`)。
  供給の無い画面(ネイティブ・旧ブリッジ・inapp-boost モード)は `offscreen` が nil なので従来どおり。
  **同セッション A/B の実測**(E2E-CMP/ios-xcuitest・`WebViewの中身を操作できること.S0010` を
  交互ではなく連続で fix 5 周 / base 3 周):

  | | scrollToTop | scrollTo(対照・経路は無変更) | exist "見出し"(対照) |
  |---|---|---|---|
  | fix | **7,849ms**(7,796〜8,043) | 6,656ms | 2,967ms |
  | base | **9,118ms**(9,087〜9,148) | 6,534ms | 2,962ms |
  | 差 | **−1,269ms(−13.9%)** | +122ms(雑音) | +5ms |

  減った量は XCUITest のスワイプ1回ぶんと整合(1スワイプ約2.5秒のうち約1.6秒が quiescence)。
  **対照が動いていないこと**を同じ run から取っているのが判定の根拠(単独の壁時計では
  デバイス差・セッション鮮度に埋もれる)。
- **AX 活性化待ち約3秒は iOS 側の床でブリッジ差なし**(2026-08-05 に `results/runs` 全数で確認):
  `exist "WebView 見出し"` の中央値は **ios-xcuitest 2.96s(n=448)/ ios-inapp-boost 3.04s(n=283)/
  android 0.24s(n=174)**。DOM 経路(in-app)でも同じだけ掛かるので **AX ではなく WKWebView が
  初回に中身を出すまでの時間**。ホスト側に削り代は無い(強いて言えば `PollBackoff` が
  100→200→400→800ms と粗く、実測が 2.85〜2.96s に密集しているのは**5回目のポーリング境界**に
  張り付いているため。細かくすれば最大 0.5〜0.8s 前倒しできるが、全アサーションの
  ポーリング形を変えることになる)
- **iOS xcuitest は 1 スワイプが約 2.5 秒(内 1.6 秒が XCTest の quiescence 待ち)**
  ——「横が縦より高い」は**誤り**(2026-08-04 に測って訂正):
  スイート最長の `E2E-iOS` `スクロールで折り返し下の要素に到達できること.S0090`(78.0s)は
  横方向の4手で約 50 秒を使うが、**単価は横 2,567ms・縦 2,546ms でほぼ同じ**
  (`FT_EVENT_LOG_PATH` の actionMs ÷ スワイプ数)。差は「横のステップが探索・端送りで
  4スワイプ要る」だけで、方向の問題ではない。`scrollFrame` の有無でも変わらない
  (path 指定 2,546ms 対 全画面 2,620ms)。**削るなら1スワイプの単価かスワイプ本数**で、
  単価の内訳は `FT_FAST_INPUT=1` との差分から **quiescence 待ちが約 1.6 秒**と分かる
  (2,546→926ms)。PT-3.14 の「tap の quiescence は 29ms」はタップの値で、**スワイプでは
  桁が違う**(慣性が収まるまで XCTest がアイドルと認めない)
- ➖ **探索スワイプだけ quiescence を飛ばす案は不採用**(2026-08-04 実測・再提案しない):
  S0090 は 75.1→67.6s(−10%)になるが、**探索直後のタップが飲まれる** ——
  `tap("#row_30")` の後に `selected=-` で **E2E-iOS の S0080/S0060 が 2/2 で落ちた**
  (S0080 はまさにこの型の回帰テスト)。空打ちドラッグ+`settleAfterScroll` は
  「XCTest の quiescence が慣性を吸った後」を前提に組まれている。しかも **CMP の
  スクロール系は同一セッション A/B で改善ゼロ**(152.3/150.4s 対 153.0/153.5s)で、
  賞金自体が SUT を跨いで一般化しない。`.edge`/`.gesture` へ広げるのは更に悪い
  (ホスト側の整定が周回上限で打ち切られ、全ステップに打ち切り注記が付く)。
  **残る手はスワイプ本数を減らすことだけ**だが、刻みを広げる較正は PT-3.18/PT-3.19 で
  2度撤回済み(行き過ぎ = 探索失敗に直結)
- ❓ **全操作(タップ・長押し・スワイプ・ドラッグ)で XCTest の待ちを既定で外し、整定を木の観察だけにする案は判定できていない**
  (2026-10-09・`iosFastInput` 既定 true の版で `e2e.sh --local --ios-xcuitest`): E2E-CMP が 38 本中 22 本赤になり止めたが、
  **同じ時期は環境が不調だった** —— 変更前の 10/8 11:25〜12:57 にも XCUITest・in-app の両方で 17〜22 本赤(in-app は XCTest の
  待ちと無関係)、この日も赤のシナリオを1本だけ回すと両モードで緑、Simulator を起こし直して負荷の平均が 401 → 19 に落ちてから
  回すと 56/56 緑。**HEAD との対照も取っていない**ので、赤のうち変更が原因の分は分からない(当初「Compose は AX の木が遅れて
  追従するので木だけでは無理」と書いたが、確かめていない)。
  **測り直した(同日・Simulator を起こし直して負荷の平均 < 20・同じビルド a1927045 で `--set iosFastInput=true` だけを
  切り替え・SUT ごとに対照 → 木だけの順で交互)**: 全体の run は CMP 56/56 対 56/56・iOS 54/54 対 54/54(3分51秒 → 3分24秒)・
  Flutter 45/45 対 43/45・RN 46/46 対 45/46。木だけで赤の3本を交互に各5回: Flutter のセレクタ画面 5/5 対 5/5・
  Flutter の IME の Enter 5/5 対 5/5(= 全体の run の赤は偶然)・**RN 横スクロール S0090 5/5 対 2/5**(全体の run と合わせ
  6 回中 4 回落ちる。探索が `#tag_15` を見つけて止まった後も慣性で流れ、中心 (-4, 720) で画面外)。**判定: タップ・入力は
  木の観察だけで足りる / スワイプの慣性は足りない** → **タップ・ダブルタップ・長押しだけ既定で待ちを飛ばし、スワイプは待ちを
  残す**ように分けた(`QuiescenceWait.around` の `skipByDefault`。版 163)。**分けた版の確認**(同じ条件): CMP 55/56(赤1本は FM が使えない機械での OCR だけの可視性検証。単独で3回は 3/3)・
  iOS 54/54(S0080/S0060 を含む)・Flutter 45/45・RN 46/46・**S0090 単独 5/5**。この設定(当時の `iosFastInput`)は現在は無く、スワイプの待ちはコマンドごとの `settle: false` でだけ飛ばせる(上の記録は測ったときの名前のまま)。ランナーの `FastInput` も `QuiescenceWait` へ、リクエストの `fast` も `skipQuiescence` へ改名した(版 164)
- ✅ **代わりに「待ちの上限を縮める」を入れた**(XCTest の完了の知らせは使い続ける): ランナーの `QuiescenceWait`(当時の名前は FastInput)が操作の間だけ
  `_XCTSetApplicationStateTimeout` で上限を 60 → 6 秒に差し替えて戻す(`QuiescenceWait.quiescenceCapSeconds`。実測の正常な待ちは
  中央値 0.01〜0.1s・95% 点 1〜1.6s・最大 5.1s)。上限 0.3 秒の陽性対照で XCTest が打ち切って続行することを確かめた。
  **起動・前面化・入力の中の待ちは縮めない**(activate の待ちを切ると前面化が完了せず 45s で時間切れ)。**正常な待ちの最大より
  短くしない**(イベントループの知らせを打ち切ると後続が約 50s 止まった)。Simulator を起こし直した後の E2E-CMP
  `--ios-xcuitest` は 56/56・上限到達 0 回。併せて見張り(handlerTimeout)を 75 秒にした
- **iOS ブリッジ供給の堅牢化(高並列時)**: ランナーのコールドスタートが負荷下で
  供給タイムアウトを超え、run 全体が中断する(PT-7 の交互成功パターン)。候補: タイムアウト値の
  負荷連動延長、ランナー起動の直列化、タイムアウト後も起動継続中なら待ち直す再確認ループ。
  **「2 台までは安定」「3 台以上を常用する動機はない」は旧記述**(PT-3.1 は M1 Max 10 コアでの実測)。
  現在のマシンは M2 Ultra で、E2E は **iOS 6 レーンが日常**(2026-07-30 実測: 3 SUT × 6 レーン・
  稼働 92〜96%・91 シナリオ成功・振り直し 0 件)。台数の妥当性はマシンごとに PT-3.1 の手順
  (実行中の CPU idle を見る)で取り直すこと
- **iOS の「XCUITest 税」と高速化の仕組み**: 施策は 2 系統:

  **「税 = snapshot ~250ms」は旧説(2026-07-30 に外形計測で否定)**。ホスト側から HTTP 越しに
  測ると素の snapshot 取得は **29〜118ms**(要素 5〜22 個・M2 Ultra アイドル)で、支配項では
  なかった。実体は**操作直後の snapshot に掛けていた固定 350ms の整定待ち**で、
  `Runner/FleetestRunnerUITests/BridgeRouter.swift` の `handleSnapshot` にあった
  (ランナー内のコメントも「app.snapshot() は ~0.45s」と書いていたが、これは
  **350ms ガード込みの値を素のコストと取り違えた誤り**だった)。→ PT-3.8 で置換済み。
  1. **税の減額(XCUITest 経路内)**。3 施策のうち採否が分かれた:
     - ✅ **Reduce Motion 自動設定**(採用): `BridgeLauncher.enableReduceMotion()` が
       コールド起動時のみ `simctl spawn <device> defaults write com.apple.Accessibility
       ReduceMotionEnabled -bool true` を実行(Android の `disableAnimations()` の対称)。
       doctor に警告も追加(`animationScaleWarning` の iOS 版)。設定は以後起動される
       アプリに効くため /session がシナリオ毎に再起動する前提で有効。リスクゼロ・原則整合。
     - ✅ **/type の固定待ち削除**(採用): 旧 `usleep(400_000)`。当初 `keyboards.firstMatch.
       waitForExistence(timeout:1)` に置換したが**逆効果で不採用**(シミュレータのキーボードは
       別プロセス扱いで `app.keyboards` クエリが常にタイムアウト = type 中央値 1616→2248ms に
       悪化。2026-07-12 実測)。**最終解は待ちを完全削除**(`coordinate.tap()` が既に
       quiescence まで待つため後続 `typeText` は安定)。type 中央値 1616→1387ms(−230ms)・
       5 連続入力成功・成功率 100%。
     - ✅ **xcuitest launch の simctl 化**(採用 2026-07-21・既定 on): `FastLaunchDriver` が
       launch を XCUIApplication.launch()(実測 4.6〜5.4s)から simctl terminate+launch+
       activate 接続(≈2.4s)へ置換。シナリオ wall −14〜19%。復帰用のエスケープハッチは
       `FT_NO_FAST_LAUNCH=1`。attachOnly 化の不採用理由は PT-6 参照。
       **マージ後に同一バイナリ A/B(`FT_NO_FAST_LAUNCH` の on/off)で再計測した記録**は
       [performance-tuning/records.md](../performance-tuning/records.md)
       (シナリオ4本 × 36ラン・改良効果 −14〜21% を再現。既定 on になった今は取り直せない対照)。
     - ✅ **autoInstall 差分判定の指紋キャッシュ**(採用 2026-07-21): `InstalledAppCheck` の
       バンドル深比較(40MB で 0.86s/ラン)を、検証済みソース指紋(相対パス+サイズ+mtime の
       SHA256、.fleetest/install-check/)のヒット時にスキップ。0.86→0.41s(残りは列挙+
       get_app_container の実在確認=erase 検知のため残す)。
     - ✅ **inapp type の Compose 対応**(採用 2026-07-21): Compose は「フォーカスアンカーの
       OverlayInputView(入力セレクタ非応答)」と「実際のキーボード受け口 IntermediateTextInputUIView
       (UIKeyInput 準拠・isFirstResponder)」が**別ウィンドウの別ビュー**で、従来の first responder
       捕捉が前者を拾って 409 になっていた。「insertText: に応答し かつ isFirstResponder のビュー」を
       最優先する探索に変更(InAppInput.m FTInsertTextIntoFirstResponder)し、type 実測 262〜299ms
       (XCUITest attach 経路 1.0〜1.3s の約1/4)。inapp-boost モードの Compose 検出時 attach 優先
       (preferTypeDriver)は廃止し、409→attach フォールバックのみを安全網として残す。
       ログイン系シナリオ 18.9→15.3s(−19%)。
       **2026-07-28 追記**: `\n` を含む text だけは attach 経路(XCUITest)へ回す。改行の意味を
       OS 既定(Return キー押下)に揃えるためで、その入力だけこの高速化の対象外になる
       (`\n` を含まない通常の入力は従来どおり in-app。docs/design/)。
     - ✅ **FT_PHASE_LOG=1 のフェーズ計測**(採用 2026-07-21): run の固定費内訳を stderr に出す
       計測点(PhaseLog.swift)。実測: CLI 側固定費はほぼゼロ(0.05s)で、ラン毎オーバーヘッドの
       実体は iOS ワーカー合流(ブリッジ再利用スキャン 0.55s+インストール差分判定)。
     - ℹ️ **inapp launch(2.3s)は現状が床**(2026-07-21 精査): simctl 1コール化
       (--terminate-running-process)・80ms ポーリング済みで、残りは simctl とアプリ起動そのもの。
       検知側の伸びしろなし。
     - ❌ **snapshot の私有パラメータ絞り込み**(不採用): `snapshotWithParameters:error:`
       (maxDepth 等)は Xcode 27 beta 3 に実在し呼び出しも成功したが、**速度改善が実測ゼロ**。
       設定アプリのルート画面で有効要素が深さ 21 前後に集中しており、取りこぼさない安全な
       深さ上限(≥32)では削れるノードが無い。warm snapshot は元々 80〜90ms で
       ボトルネックでもない(遅く見えた 250ms 平均は初回/画面遷移直後の一過性)。
       私有 API 依存 + Xcode ベータ毎に壊れるリスクだけが残るため採用ゲート不通過。
       **再検討条件**: 要素数が数百規模の巨大画面が現れ、warm snapshot が実測で
       ボトルネックになったら(そのとき maxChildren/maxArrayCount の方が効く可能性)。
     税の減額の効果は限定的(action 支配項の quiescence ~1s/step は XCUITest 継続の限り残る)。
     **iOS の真のボトルネックは scrollTo(action 中央値 ~7.6s/回。swipe+再 snapshot ループ)と
     tap/type の quiescence 床**であり、大幅短縮には税の撤廃(下記2)が要る。
  2. **税の撤廃 = アプリ内常駐ブリッジ**(EarlGrey/Espresso と同クラス)。シミュレータは
     `DYLD_INSERT_LIBRARIES=<dylib>` を起動時の環境に載せれば任意アプリに
     リビルドなしで注入できる(シミュレータプロセスは SIP/hardened runtime 非適用)。
     **キー名は経路で違う**: simctl 経由は `SIMCTL_CHILD_` を前置する(simctl が剥がして子へ渡す)、
     CoreSimulator 直叩き(現在の既定)は `options["environment"]` に**接頭辞なし**で入れる。
     UIKit ビュー階層の直接走査(ms 級・IPC ゼロ)+ランループオブザーバと
     CATransaction/CADisplayLink による**真のイベント駆動整定**+プロセス内タッチ合成。
     既存 9 エンドポイントの HTTP 互換にすればホスト側は概ね無変更(単一実装原則と整合)。
     **3 点プロトタイプの実測結果**(SampleApp・iPhone 17 Pro シミュレータ、Xcode 27 beta 3):
     - 注入: `__attribute__((constructor))` の dylib が確実にロード、`connectedScenes`→
       `windows` から UIKit 階層を走査可能(accessibility ラベルも取得可)。
     - snapshot: プロセス内フル走査(ラベル/フレーム/enabled 収集込み)が **0.058ms/回**
       (XCUITest の warm 80〜90ms・cold 250ms に対し 3〜4 桁高速)。IPC 撤廃の効果。
     - 整定: `CFRunLoopObserver`(kCFRunLoopBeforeWaiting)で「アイドル 2 連続 かつ
       全レイヤ `animationKeys` 空」を整定判定。300ms アニメを **319ms・ポーリング 5 回**で
       検知(ビジーループなし=Android QuietWaiter の iOS 版)。XCUITest の保守的な
       暗黙 quiescence(~1s/action)を置換できる。
     - タッチ: 合成タップ(`UITouch` + `[app _touchesEvent]` + `sendEvent:`。`setWindow:`
       `_setLocationInWindow:resetPrevious:` `setPhase:` 等の private セレクタは Xcode 27
       beta 3 に実在)だけで、`becomeFirstResponder` を呼ばずに対象 UITextField が
       first responder 化(実イベントパイプラインが駆動)。`IOHIDEventCreateDigitizerFingerEvent`
       も dlsym 可能で代替経路として使える(EarlGrey/KIF がシミュレータで長年使う経路)。
     - Swift dylib: 単一 dylib に Swift `.o` + ObjC 構成子(`@_cdecl` を呼ぶ)を
       リンクすれば Swift でも注入可・UIKit アクセス可。→ リポジトリの `BridgeHTTPServer`/
       `BridgeDTO`(Foundation 依存のみ)を再利用できる。
     見込みは Android 並み(シナリオ ~2s 級)。制約: タッチ合成に私有 API を使う。
     **実機への注入は実装済み**(開発署名のアプリのみ。DS-11.2・PT-10)。
     当初「実機は注入不可(自ビルドアプリへのリンク方式のみ)」としていたのは実測の無い前提だった。
     **XCUITest ランナー(Runner/)は残す**(ユーザー決定 2026-07-12。当時は実機への注入が無く、
     単一実装原則の明示的な例外として「シミュレータ=in-app / 実機=XCUITest」の 2 経路を許容した)。
  3. **in-app ブリッジの実装(`InAppBridge/`)**:
     DYLD 注入で対象アプリに常駐し HTTP 応答する in-app ブリッジ。`build.sh` が `BridgeDTO`(共有)+ in-app 実装 +
     ObjC 構成子を単一 dylib(`InAppBridge/build/libFTInAppBridge.dylib`)にリンク
     (`swiftc -c -wmo`)。9 エンドポイント実装済み(/session は「注入先アプリ一致で OK」、
     lifecycle リセットはホスト再起動が担う)。**実装(Simulator で確認済み)**:
     - snapshot: `UIAccessibility` API で AX ツリー走査 → `ElementInfo`(DTO 完全互換)。
       起動時に **`_AXSSetAutomationEnabled(YES)`** で AX を活性化(XCUITest 相当。しないと
       `accessibilityFrame` が zero・label 空で全要素が落ちる)。フレームは `view.convert
       (bounds, to: nil)` で堅牢化。0.03〜0.06ms/回。
     - 整定: `CFRunLoopObserver` + 16ms ハートビート(キーウィンドウのみ対象)。**除外必須の
       アニメ2種**: ①無限反復(カーソル点滅・スピナー)②**iOS27 Liquid Glass の装飾モーフ**
       (`CASDFElementLayer`/`_UILiquidLensView` の `match-*`/`punchout`。タブバー等が常時走らせる)。
       いずれも数えると settle が cap(2500ms)に張り付く=**重要な罠**。除外後は遷移も 100〜250ms で収束。
     - **type(テキスト入力): XCUITest 比 1482→~500ms**(合成タップでフォーカス→ first responder
       (UIKeyInput)へ `insertText:`。合成タップの focus は view の touchesBegan/Ended に直接届く)。
     - **tap: `accessibilityActivate()`(VoiceOver ダブルタップ相当=要素のデフォルトアクション発火)**。
       これが決定打。**合成タッチ(UITouch+sendEvent / `_setHIDEvent:` / `_enqueueHIDEvent:` の
       5方式)はいずれも SwiftUI Button 等のジェスチャ認識器を発火できなかった**(HID の
       display-integration メタデータを完全再現できず。focus は効くが gesture 不発)。
       snapshot が ref→AX 要素を保持し、tap(ref) はその要素を activate する。座標指定(x/y)も
       直近 snapshot の point を含む最小要素を activate(SwiftUI の活性化要素は合成 AX ノードで
       hitTest の view 階層に無いため、hitTest+祖先 activate では発火しない)。活性化不能な要素は
       合成タッチにフォールバック。XCUITest 比 767→~280ms。
     - **swipe: `UIScrollView.setContentOffset` 直接操作**(スクロールのジェスチャ認識器も合成タッチで
       駆動できないため。面積最大の可視 `UIScrollView` を探し contentOffset を ±可視領域 85% 動かす。
       `accessibilityScroll` は SwiftUI List で片方向しか効かず不安定だったので不採用。双方向スクロール
       を Simulator で確認済み)。無い場合は合成スワイプにフォールバック。
     - **press: 合成タッチ(down→ランループ保持→up)で動作**(意外にも tap/swipe と違い長押し
       ジェスチャは発火する。保持中に gesture 認識器が touch を処理するため)。コンテキストメニュー
       (SwiftUI `.contextMenu`)を開き、メニュー項目を accessibilityActivate でタップする完全フローを
       Simulator で確認済み。
     - screenshot: `drawHierarchy` → PNG、45ms。
     - **ホスト統合(モード選択+lifecycle)= 完成**: machine プロファイルのデバイスに
       `mode`("xcuitest" / "inapp-boost")を持たせ、`mode=inapp-boost` のときサブプロセスが
       `InAppDriver`(launch=simctl 再起動+dylib 注入、他は HTTP で `BridgeClient` へ委譲)を使う。
       provisioner は注入起動済みブリッジを /status スキャンで発見・再利用、不足分は
       `InAppLauncher`(注入起動)で起動。**ホスト実行系(`FTBridgeClient`/RunOrchestrator/
       ScenarioHost)は mode フィールドを通すだけで概ね無改変**。
       **mode=inapp-boost の新規ブリッジ起動には注入対象アプリの bundleID が要る**(run プロファイルの
       apps.ios.app 経由でのみ得られる)。無い場合は XCUITest にフォールバックせず**明示エラー**
       (`inAppNeedsBundleID`。単一実装・フォールバックを作らない方針。device/live 等 bundleID を
       渡さない経路は mode=inapp-boost 非対応)。稼働中ブリッジ再利用時は launch しないので bundleID 不要。
     **実シナリオ実証(ログイン画面.S0010、Simulator)**:
     - 単発(warm・状態リセット無し): step 合計 ~11.0s(XCUITest)→ **~3.0s(3.7倍速)**。
     - **プロファイル経由 3 イテレーション: 全 passed=True**(以前は 2 回目以降ログイン済みで失敗)。
       各イテレーションの launch = `InAppDriver` の simctl 再起動+注入 **~2900ms**(fresh 状態確保。
       XCUITest の launch 4200〜5400ms より速い)。step 合計 ~6.2s(XCUITest ~11s の 1.6倍速)。
       **XCUITest 経路は回帰なし・FTCore 143 テスト全パス**。
     残り時間の内訳: launch(fresh 起動)2.9s + シナリオ自身の明示 wait(1s)+ 別プロセスの
     システム UI(パスワード保存シート「今はしない」)への optional タップ空振り(~750ms)。
     in-app ブリッジの実操作(type/tap/exist)は合計 ~1.1s。
     **AX id 忠実度=解決済み**: 当初 `.accessibilityIdentifier` を拾えず id 単独セレクタが
     解決不能だったが、原因は `as? UIAccessibilityIdentification` キャスト(SwiftUI の
     `AccessibilityNode`/`UIKitTextField` はセレクタに応答するがプロトコル準拠を宣言しない)。
     **セレクタ直接呼び出し(`FTAccessibilityIdentifier`)に修正して解決**。`ログインテスト.S0010`
     (`#email`/`#password`/`#login_error` 等の id 単独セレクタ+restartApp+エラーパス+textIs)が
     in-app 経由で passed=True。
     **軽微項目=すべて解決**: (a) 空 TextField の value に placeholder が乗る微差 → 実テキスト(.text)が
     空なら value=nil に修正(非空 SecureTextField は accessibilityValue のマスクを維持し実パスワードは
     晒さない)。(b) press → Simulator で確認済み(上記)。(c) 並列複数 in-app デバイス → シミュ1-inapp(8123)+
     シミュ2-inapp(8124)で 2 シナリオ並列全 passed(port/udid 配線が並列で正しい)。install 前注入起動の
     順序は mode=inapp-boost+autoInstall のとき注入起動が install より先に走る(現状はアプリ事前 install が
     必要=エラーメッセージで案内)。
     なお XCUITest の quiescence 自体を私有 API で無効化する案(WDA 方式)は、
     代替の整定信号がプロセス外から得られないため 2 とセットでない限り採らない
     (**2026-10-09 にタップ・ダブルタップ・長押しだけ既定で無効化した** —— 代替の整定信号は木の観察(`captureSettled`)で
     足りると 4 SUT の A/B で確かめた。スワイプは慣性を木で見届けられず残した。待ちの上限も操作の間だけ 60 → 6 秒。PT-8。
     **2026-10-21(ブリッジ v203)に「操作の前の」待ちだけ戻した** —— 前後とも飛ばすと、ポップオーバー・シートを開いた直後の
     タップが遷移の途中に当たって吸われる(開く操作から約 0.5 秒。木はその時点で最終位置を出すので木の整定では見張れない。
     E2EX-iOS の 42_固有部品 S0010 が 10-20 から決まって赤)。実費は静かな画面 2〜5ms・遷移の直後 147ms・アニメーション中
     最大 815ms・Apple マップ 2〜844ms(Simulator)。操作の後の待ちは飛ばしたまま。`QuiescenceWait.waitBeforeTouch`)
  4. **cross-app ハイブリッド(in-app 主 + XCUITest フォールバック)**: `mode=inapp-boost` を指定すると in-app(主・高速)で駆動し、対象要素が
     in-app snapshot に無いとき **XCUITest(システム UI)へ自動フォールバック**する。in-app は
     同一プロセスしか見えない(=速さの源泉と表裏)ので、既に前面にあるシステム UI(権限ダイアログ等)
     だけ XCUITest に委ねる。「XCUITest が in-app を起動」案とは別(あちらは launch 4200-5400ms と遅い)。
     - **配線経路(同期が必要)**: `BridgeProvisioner`(inapp-boost モードは in-app + xcuitest の2ブリッジを起動、
       `ProvisionedIOSDevice.xcuiPort`)→ `DriverConnection.xcuiPort` → `ScenarioHost` が `--xcui-port`
       で伝搬 → `ScenarioRunnerMain` が `SystemUIDriver(port:)` を構築 → `StepExecutor.fallbackDriver`。
     - **フォールバック解決**(`StepExecutor.executeAction`/`executeAssert`): 主 driver(in-app)の
       poll(最大3回)で解決できないとき **fallbackDriver.snapshot() で1回だけ**解決を試し、当たれば
       以降の act をその driver で行う。**注意: フォールバックは snapshot 1回のみ(poll しない)**。
       遅延して出るダイアログはシナリオ側で `wait` を入れる(通知許可等は `.action` に `wait(2)`)。
     - **ブリッジ発見**: `/status` に `bridge`("inapp"/"xcuitest")を追加し、`scanRunningBridges` は
       (UDID, bridge) で照合(同一 UDID に2ブリッジが共存するため port→UDID だけでは reuse が非決定的)。
       inapp-boost モードのデバイスは2ポート消費(8123-8154 で最大16台並列)。旧ブリッジは bridge=nil→"xcuitest" 扱い。
     - **springboard 非破壊参照モード**(`BridgeRouter.handleLaunch`): bundleID=com.apple.springboard の
       とき `target.launch()` せず参照だけ張って snapshot/tap 可。**launch すると springboard がホームに
       飛びアラートを消す**ので不可。`SystemUIDriver.snapshot()` は毎回 springboard を再 session(refs を
       張り直す)が、tap/press は再 session しない(refs が消える)。
     - **Simulator での A/B 検証済み**: 通知許可ダイアログ(springboard 別プロセス、in-app 不可視)に対し
       `tap("許可||Allow")` が **inapp-boost モード=passed(fallback label=Allow で解決)/ in-app ブリッジ単独=failed(ロケータ
       解決不可)**。同一アプリ・同一手順・唯一の差はフォールバック driver の有無 → フォールバック経路が
       働いた確証。既存 `ログインテスト.S0010` も inapp-boost モードで全 passed(通常シナリオに非回帰)。
       **アラート文言はロケール依存**(この個体は英語 "Allow"/"Don't Allow")。
     - **シナリオ単位の自動ルーティング**(ScenarioRunnerMain のドライバ構築): シナリオの対象アプリ
       (解決済みの既定アプリ。`FTCore.ScenarioAppResolution`)が in-app 注入先
       (in-app /status の sessionBundleID)と**異なる**とき、
       inapp-boost モードはそのシナリオを**丸ごと XCUITest ブリッジで駆動**(iOS設定アプリ等のシナリオが既定 ON でも
       動く)。XCUITest ブリッジを持たない in-app ブリッジ単独は明示エラー。**この分岐が無いと別アプリの注入起動がポート衝突で
       旧ブリッジの偽成功応答になり「裏のアプリを操作して失敗」する**(E2E で実際に発生)。
     - **suspend 時のルーティング(2026-07-15 修正。混在実行の必須対策)**: 上記ルーティングは in-app
       /status の応答に依存するが、**直前に別アプリ(system-UI)シナリオが走ると iOS が背面へ回った
       注入先アプリを suspend し、in-app ブリッジは TCP は受理するが HTTP 応答を返さなくなる**
       (pre-flight プローブが既定 45s ハング=当時の「The request timed out」)。
       対策: プローブは短タイムアウト(`BridgeClient.status(timeout:)`。今は `tunables.injectedAppProbeTimeout` = 10s)にし、**無応答時は provision
       時の注入先 bundleID(`DriverConnection.inappBundleID` → `ScenarioHost` が `--inapp-app` で伝搬)を
       注入先とみなして**分岐する(対象==注入先 → InAppDriver、別アプリ → XCUITest)。**無応答を一律
       InAppDriver に倒すと、suspend 中の別アプリ(Preferences 等)シナリオを in-app 経路へ誤ルーティング
       して破綻する**(この誤りで実際に回帰し、Preferences シナリオがハング → DS-8.8 の
       `waitUntilExit` 凍結で run 全体が固まった)。InAppDriver 経路は pre-flight `status()` を省略する
       (suspend でハングし、かつ冒頭 launchApp の注入 relaunch で bridge を必ず張り直すため不要)。
       混在させないなら `iosMode: "xcuitest"`(全 XCUITest)で回避もできる。
     - **未達**: リッチなサービス所有シート(iOS27 写真限定ライブラリ=com.apple.PhotosViewService)は
       app.snapshot() の1アプリツリーモデルでは掴めない。**推奨運用**: 単純アラートは inapp-boost モード、
       リッチシートや確実性重視は `simctl privacy grant`/`defaults write` でダイアログを最初から出さない
       方が安価・確実。**シナリオ途中の deliberate フルアプリ切替(sampleapp 操作中に設定アプリへ遷移等)
       は対象外**(フォールバックは「アプリ前面のまま出るシステム UI」向け。シナリオ丸ごと別アプリは
       上記ルーティングで XCUITest が担う)。
     - 使い方(推奨): **run プロファイルの `iosMode`("inapp-boost" 既定 / "xcuitest"。GUI の「iOS のモード」)で選ぶ**。
       iOS デバイスの実効モードが決まる(`ProfileResolver.resolve`)。`devices[]` のその device に `mode` を
       明示していればそちらが優先。inapp-boost モードは bundleID 必須
       (新規 in-app 起動に要る。`inAppNeedsBundleID`)。**既定が inapp-boost なので mode 無指定の iOS デバイスは
       inapp-boost モードで走る**(従来 XCUITest だった `ios.json` 等も高速化。XCUITest ブリッジだけに戻すには `iosMode: "xcuitest"`)。
- **シナリオ設計の見直し**: 上記 iPhone Air フレークのようなデバイス依存アサーションの排除は、
  どんな高速化より成功率に効く

### PT-8.1 回帰をマシン間で動的に割り当てる(2026-10-27 検討・**案 A を `Scripts/regress.py` として実装**)

**実装と確認(2026-10-27)**: `Scripts/regress.py`(使い方は docs/verification/operations.md の `Scripts/e2e.sh` の節)。下の「壊れる 4 か所」は
①スクリプトの `--build-only` ②③`--as-part`(印・推奨・陽性対照はまとめ役が全部の仕事が緑のときに1回・絞った回は書かない)
④`Scripts/test-scope-guard.py` が `regress.py` を全体の実行として扱う、で手当てした。E2EX・E2EY の Flutter だけに絞った 6 本で
3 台に 2 本ずつ配られ全部緑(段 1 の SUT の確認とビルド 98 秒・全体 5.7 分)。`--dry-run` の見込みは、今日の実測を記録に入れて
固定の割り当て 37.6 分 → 待ち行列 32.7 分。**残り: 同じコミットで固定の割り当てと交互に 2 回ずつ回して全体の所要を比べる(未実施)**。
約束(SUT の表とスクリプトの一致・仕事の選び方・`--as-part` で印を書かない)は `regressPlan.test.mjs` / `inappE2EGate.test.mjs` /
`e2exGate.test.mjs` が固定する
**利用者の run(1つのプロファイルがマシンをまたぐ run)の同じ効率化は RR-8.1**(シナリオを1本ずつ配る動的な割り振り。空いたマシンが
待つほうが早ければ渡さない規則もそちら)。**2026-10-27 に RR-8.2 へ統合**: 配る部分は `fleetest run --target …` が持ち、regress.py は
SUT のビルド・対象の一覧・後始末だけの薄い包みになった(仕事の選び方も RR-8.2 の規則 = 待つほうが早ければ待つ)


**動機(実測)**: 2026-10-27 の回帰はスイートをマシンに固定で割り当てた(E2E = この Mac・E2EX = M1Ultra・E2EY = M1Max。各マシンで
既定モード → xcuitest モードの順)。所要は **この Mac 35.6 分・M1Ultra 25.6 分・M1Max 29.7 分**(M1Max は Simulator が 4 台)で、
全体はこの Mac で決まった。完全に均せば約 30.3 分 = **伸びしろは約 15%**。仕事は run 37 本(E2E 13・E2EX 12・E2EY 12。1 本 2〜4 分・
合計約 91 分)で、粒が細かいので長い順に詰めればほぼ理想に届く。

**前提にした測定と決定**:
- 同じマシンで run を同時に回しても CPU で頭打ち(PT-6 の「iOS と Android の run を同時に」)。**1 台に 1 本ずつ・終わったら次**が単位。
  同じランナーでの並行実行(デバイス分割)は作らない(RR-18.2)
- run ごとの固定費(この Mac のフル E2E 20.6 分の内訳): シナリオ 73%・run の後始末 11%(ほぼ全部が録画の切り出し)・
  run と run の間 8%(次のプロジェクトのシナリオのビルド)・run の前の準備 8%(iOS 15〜17 秒/run)。録画の切り出しは
  **回帰では録画しない**ことで消した(スクリプトの既定 `--set record=false`。2026-10-27 ユーザー決定)。残りは削り代が小さい

**方式の候補**:

| 方式 | 中身 | 判断 |
|---|---|---|
| A. 待ち行列から空いたマシンが取る | 仕事 = run 1 本(スイート × SUT × OS/モード)。長い順に、空いたマシンへ渡す | **推す**。ばらつき・途中の失敗に強い |
| B. 最初に決め打ちで割り振る | 過去の所要から LPT でマシンごとの一覧を作り、各マシンは順に回す | A の簡易版。見積りが外れると均せない。A の効果の事前見積りに使う |
| C. 1 本の run をマシンをまたいで分ける | 既存の `--fleet --split`(シナリオ単位の LPT) | **推さない**。run ごとの固定費(25〜35 秒)を全マシンで払い、37 本それぞれで一番遅いマシンを待つ |

**A の作り(案)**:
- この Mac のまとめ役(仮 `Scripts/regress.sh`)が仕事の一覧を作り、マシンごとの作業者が「1 本取って実行 → 次」を繰り返す。
  仕事の実行は既存スクリプトの絞り込みをそのまま使う(全体の一部として、例: `FT_FULL_TEST=1 Scripts/e2ey.sh --rn --ios --ios-xcuitest --on M1Ultra`。RR-3 の
  SSH ディスパッチの上に載せ、新しい実行経路は作らない)
- 使うマシンは登録の `enabled` だけ(M1mini は無効 = 自動で外れる)
- 見積り: 仕事 × マシンごとの所要をまとめ役が自分の記録に残す(リモートの結果はリモートに残るので手元の run.json は使えない)。
  記録の無い仕事は先に回す(run の中の LPT と同じ)。そのマシンで記録が無ければ他のマシンの記録をレーン数の比で換算する
- マシンに届かない・作業者が落ちたら、その仕事を待ち行列へ戻す。仕事そのものの赤は回し直さない

**そのまま並べると壊れる 4 か所(先に手当てする)**:
1. **SUT のビルド**: 各マシンには自分のスイートの SUT しか無い。別スイートの仕事を取ると RN・Flutter の SUT のビルド(数分)が走り
   短縮が消える → 最初に全マシンで全 SUT の鮮度確認とビルドを並列に済ませる段を置く(各スクリプトにビルドだけの口を足す)
2. **検証済みの印**(`.fleetest/<bridge>-e2e-verified`): `e2e.sh` は SUT で絞ったときも全部成功なら書く。仕事ごとに呼ぶと一部だけで
   「検証済み」になる → 仕事の単位では書かず、全部の仕事が緑のときにまとめ役が 1 回だけ書く
3. **スイートの最後の 1 回だけの処理**(`verification_watch.py` の推奨・画像分類器の劣化の検査・陽性対照 `--negative`)→ まとめ役の最後へ移す
4. **テストの範囲のフック**(`Scripts/test-scope-guard.py`): まとめ役も全体扱いにし、全実施のときだけ `FT_FULL_TEST=1`

**確かめ方**: ①B を手元の記録で計算して見込みを確かめる(手間ゼロ)②A を 4 か所の手当てとあわせて作る(スクリプトとテストで 2〜3 日)
③同じコミットで今の固定割り当てと A を交互に 2 回ずつ回し、全体の所要を比べる(単発で判断しない。PT-2)

