# 検証: E2E の運用

| 種別 | 範囲 | 読む場面 | 扱わないこと |
|---|---|---|---|
| 手順 | E2E の回し方・モニターとの関係・実機と録画の検証・受け手フローの検証・後片付け・版数 | E2E や実機の検証を回すとき | 毎回効く最重要ゲート(→ CLAUDE.md「ビルド・検証」) |

E2E と実機の検証を回すための手順。

## macOS・Xcode を上げたら `--retrain-classifiers` を1回付けて回す(2026-10-07)

シナリオはサンドボックスの中で動き、書ける場所を名指しで開けている(SB-5.3)。OS の部品
(Core ML のコンパイル・Create ML の学習・Foundation の作業フォルダ)は `TMPDIR` を見ずに決まった場所へ書くので、
**OS が書く場所を変えると、その機能は赤にならず黙って別の経路へ倒れうる**。実際に、Core ML のコンパイル先を閉じた版では
分類器が全 SUT で使えなくなり、a11y で読める部品の checkIsON/OFF は緑のまま通った。

あわせて、docs/verification/constraints.md の各節の `確認環境:` を見て、上げる前の macOS・Xcode でしか確かめていない制約を見直す
(再現を確かめたら `確認環境:` を新しい版に更新する)。

- e2e.sh は、見本はあるのに分類器を学習・読み込みできなかった run(注記 `vision-classifier-unavailable`)を赤にする。
  理由はシナリオ末尾の ⚠️ 行に分類器の言ったまま出る
- **学習の経路は見本を変えたときしか通らない**(学習済みのキャッシュがあれば読むだけ)。`Scripts/e2e.sh --retrain-classifiers`
  は各 SUT のキャッシュを消してから回す。Create ML の出力先 `T/CreateMLModels/` を閉じていたことは、これで初めて見つかった
- 赤の原因を探すときは、run の間に `log stream` で拒否を拾う(SB-9.1)

## 1回の実行が見るのは iOS の2モードのうち片方だけ

`Scripts/e2e.sh` の iOS は **既定が `ios-inapp` プロファイル**(2026-08-11 に xcuitest から反転)。
**利用者の既定モードは inapp モード(in-app ブリッジ優先)**(`RunProfile` の `iosMode ?? "inapp"`)なので、
既定スイートが見るべきは in-app 側。**XCUITest ブリッジ**(ランナー・スナップショット・型写像・
ジェスチャ申告)を触ったら、変更が通るシナリオを **xcuitest モードで** 追加で回すこと
(`fleetest run --project <P> --profile ios-xcuitest --scenario <クラス>`)。
全実施を頼まれたときのスイートは `Scripts/e2e.sh --ios-xcuitest`(iOS だけを xcuitest モードで)、inapp モードだけなら `--ios-inapp`。

**モード指定は iOS だけを回す**(2026-08-11)。Android にモードの選択肢は無く
(`iosMode` は iOS 専用)、一緒に回すと既定スイートと1バイトも違わない実行をもう一度
払うだけになる(実測 244 秒 = このスイートの重複分)。OS の絞り込みは `--ios` / `--android`。

**印は回さなかった側に付く**: e2e.sh は `BridgeSourceSet` の digest を
`.fleetest/<bridge>-e2e-verified` に記録し(**全部成功したときだけ**)、次の実行で
**回さない側**のモードのブリッジの入力が動いていれば開始時と終了時に警告する。落とさず警告だけ。

**E2EX(`Scripts/e2ex.sh`)も同じ仕組みで別の印 `.fleetest/<bridge>-e2ex-verified` を書く**
(全部成功したときだけ。`--on` で回した回の印は向こうのクローンに残る)。**警告は in-app の印にだけ出す**
(`--ios-xcuitest` の実行のときだけ見る)—— E2EX の XCUITest は断続的な赤が残り
(FD-5.1。決まって赤のものは 2026-10-08 に 1 本 = 90_不具合の回帰 S0020)で全部成功するとは限らない = 警告にすると下の節と同じ「鳴りっぱなし」になる。
XCUITest ブリッジの検証は E2E の `--ios-xcuitest` の印が担う。両方向は `vscode-fleetest/test/e2exGate.test.mjs` が固定する。

### xcuitest の digest 警告は 2026-09-14 まで「鳴りっぱなし」だった(打鍵の中抜けを v104 で直した)

2026-08-30 〜 09-14 のあいだ、この警告は**未検証の意味ではなかった**: `--ios-xcuitest` は
2026-09-02 と 09-14 に回して E2E-CMP / E2E-iOS / E2E-Flutter は全緑、**E2E-RN だけが2本**
(`hello123`→`hllo123` / `persist99`→`prsist99`)**打鍵の中抜け**で落ち、記録は全プロファイル成功が
条件なので digest が更新されなかった。

**2026-09-14 に `TypeReadback.plan` へ `.retype` を足して直した(ブリッジ v104)**: 実際値が期待値の
順序を保った部分列で、落ちた文字に可視文字を含むとき、消してから全文を打ち直す(ランナーは
delete × 実際値の文字数 + 期待値 / ホストは clearInput + type)。守る規律3つ:
- **前方一致の後にしか置けない**(`hel` は `hello123` の部分列でもある。先に見ると今自己修復できている
  「末尾の欠落 → 追送」を全文打ち直しに変える)
- **打ち直しは `TypeReadback.maxRetypes`(1)回まで** —— 打ち直しても同じ形で欠けるなら、それは
  打鍵の落ちではなくアプリ側の加工(英字を捨てる数字欄)。2回目は v104 より前と同じく受理する。
  上限が無いと「消す→打つ→同じ値」が停滞に達して緑だった step が 422 になる
- **ホスト側の `readbackTarget` は前方一致の説明を部分列の説明より先に採る** —— ヒントが value に
  載る欄(`expected = 単一行hello123`)では撃った文字だけの `hello` がヒント付きの期待値の部分列にも
  なり、`expected` を目標にすると**ヒント文字列ごと欄へ打ち込む**(`TypeReadbackTargetTests` が固定)

**誤検知の監視**: 打ち直しが起きた事実は緑でも残る(DSL の注記 `type-retyped` / 諦めた回は
`type-retype-abandoned` / XCUITest ランナーの `OKResponse.note` → `driverFallback` / MCP の返答)。
印(`.fleetest/<bridge>-e2e-verified`)は e2e.sh が全緑で自動的に書き、打ち直しの回数は門ではない ——
**印が付いた後で結果 JSON から打ち直しを数え、真陽性(打った本文の中央が欠けた形)だけであることを
確かめる**(初回の数え上げ = 2026-09-14: 39 run・type ステップ 190 で打ち直し 2 回、どちらも真陽性(E2E-RN xcuitest の
`persist99`)・誤検知 0)。

**2本を `_disabled/` へ退避して印を通す案は採らなかった** —— この2本が**打鍵の中抜けを検出できる
唯一の場所**で、消すと検出器を失う。**記録条件を緩める案も採らない** —— 「既知の失敗」を表現する
仕組みが無く、赤を抱えたまま「検証済み」を名乗る装置になる(e2e.sh のコメントにある通り)。

## 入力・キー系は Compose だけで検証しない(フレームワークで経路が割れる)

Compose の入力欄は独自のキーイベント処理を持つため、**他フレームワークで死んでいる経路でも緑になる**。
実害(2026-07-28): Android の `pressEnter` はソフトキーボードが出ていると `keyevent 66` が
View/XML の `EditText` に届かない(IME が消費する)のに、CMP SUT の E2E は通っていた。
E2E-Android(View/XML)を回して初めて赤くなり、a11y の `ACTION_IME_ENTER` 経路へ作り直した
(docs/design/dsl-syntax.md「Android の Enter はキーイベントでは届かない」)。**入力・キー・IME 系を触ったら E2E-Android と E2E-iOS を必ず含める**。

## モニターと E2E(**止めるのは性能を測るときだけ**。2026-08-21 に運用変更)

**運用**: モニターを止めるのは**こちらが性能を測るとき**だけ。合否を見るだけの実行では止めない
(止めている間の利便性の損失が大きい、という 2026-08-21 のユーザー判断)。問題が出たら見直す。

**`Scripts/e2e.sh --performance` は pause/resume を自分で行う**(2026-09-01)。開始時に
`monitor pause --for 60`(SIGKILL 時の安全網)、終了時は trap で必ず `resume`(失敗・Ctrl-C 込み)。
**手で pause しない** —— 戻し忘れが実害になった(計測後の resume が後続作業に埋もれ、利用者が
「モニターが戻らない」と報告)。**リモートランナーの monitor も止めない** —— run 中は
ランナー側の占有機構(dispatch.lock → monitorLock)が配信を退避するので手動の pause は不要。

**ただし下の実測は捨てない** —— 配信は**遅くするだけでなく落とすことがある**。
だから **Android が赤くなったら真っ先に配信の有無を疑う**。判定材料は run.json の
`workerAnomalies`(`degraded` / `requeued`)で、理由が `the device disappeared` /
`an unreachable bridge` ならこの壊れ方の署名(アサーション失敗は別の話)。

**モニターと同時に E2E を回すと Android が実際に赤になる。** 同じコード・同じ盤面・同じ台数で
3条件を取った:

| 条件 | Android プロファイル | 接続断 | ワーカー離脱 |
|---|---|---|---|
| モニター常駐(観測+配信) | **3/4 失敗** | 11 | 3 |
| `fleetest api monitor` だけ kill(配信は生存) | 1/4 失敗 | 2 | 3 |
| **配信まで止める** | **4/4 成功**(108/108) | **0** | **0** |

失敗はすべて `Cannot reach the driver` / `adb: device offline` /
`the device disappeared (offline/not found)` で、**アサーション失敗は1件も無い**。

**2026-09-20 の 3 時間負荷テストでも同じ向きの差が出た(壊れ方は「凍結」)。** 手元の Mac で
フリート(シミュレータ 8 + エミュレータ 8)+ 実機 4 台 + MCP 2 セッションを同時に回し、
途中 30 分だけ `monitor pause` して 3 区間を取った:

| 区間 | 配信 | 時間 | 凍結で離脱したワーカー | 頻度 |
|---|---|---|---|---|
| 周回 1〜4 | あり | 56 分 | 12 | 0.21/分 |
| 周回 5〜7 | **なし** | 32 分 | 1 | **0.03/分** |
| 周回 8〜10 | あり | 34 分 | 6 | 0.18/分 |

離脱したデバイスは Android エミュレータ 13・iOS シミュレータ 5 で、**すべて手元の Mac**
(同じ run のリモート 2 機は 0・**実機 4 台も 0** = 仮想デバイス固有)。凍結の実体は
**アプリの窓が真っ白のまま固着**で、`screencap` の md5 が 3 秒あけて同一・端末は Awake・
focus はアプリのまま。検知は真陽性で、requeue と guest restart の回復も働く(回復は離脱の約 4 割)。
**配信を止めると load average も 34 → 14 に落ちる**ので、配信は「負荷の大きな一部」であって
唯一の原因ではない(配信なしの区間でも 1 件出た)。

**止め方は `fleetest monitor pause`(2026-08-24 追加)。** kill では止まらない ——
拡張が `api monitor` も配信ヘルパーも数秒で再起動する(受け手はこれで無人計測の条件が
作れなかった)。保持ファイル(`.fleetest/monitor-hold.json` = `FTCore.MonitorHold`)を
`api monitor` が毎周期見て、hold 中は観測を止め全タイルを state:"unknown" で出す。
unknown のタイルには拡張が配信ヘルパーを張らない(qualifying 判定)ので、ヘルパーも
子の screenrecord も畳まれる。解除は `fleetest monitor resume` か `--for <分>` の期限:

```
fleetest monitor pause --for 30   # 30分。省略すると resume まで
# … 計測 …
fleetest monitor resume
```

**効くのはこの機械の monitor だけ**(fan-out の子 = `--device-machine` 付きは hold を見ない。
リモートランナー機で pause しても、そこへ接続している別の機械の配信は止まらない)。

拡張が動いていない(パネルを開いていない)ときの旧手段は pkill 3連打
(`fleetest api monitor` / `fleetest-androidstream` / `screenrecord --output-format=h264`。
1つ目だけだと配信が8台ぶん全部生き残る)。

**中途半端に止めた対照からは誤った結論が出る。** 観測ループだけ止めた回で接続断が 11→2 に減り、
残り2件が1台(emulator-5558)に集中していたので「その個体の問題」と報告した ——
**実際はそのデバイスの配信が残っていただけ**で、配信を止めたら同じデバイスを含む全台が緑になった。
**対照は「全部止めた」まで作ってから読む**(testing.md「切り分けは「実験系が効いているか」を先に確かめる」
と同じ型を、止め方の側で踏んだ形)。

これで長らく保留だった「**E2E の再キューは環境か実装か**」も**環境**と確定した
(xcuitest 実行で観測した19件の再キューも同じ機構と見てよい)。

## 実機の E2E は `Scripts/e2e-devices.sh`(2026-10-13)

E2E(5 SUT の共通契約)を**実機に `--broadcast` で流す**入口。仮想デバイスのスイート(`e2e.sh`)とは別に回す
—— 実機は機種ごとに同じシナリオを1回ずつ回して差を並べるのが目的で、分配しない。使う実機用プロファイル:
E2E-iOS・CMP・Flutter・RN の `ios-device`(SE3 = この Mac・iPhone 13 = M1Ultra。iPhone wave は個人の端末なので無効のまま)/
E2E-Android・CMP・Flutter・RN の `android-device`(Pixel 4a + Pixel 3a)。iOS の実機用アプリは各 SUT の
`scripts/build-ios-device.sh` が `dist/ios-device/` に作る(ソースが新しければこのスクリプトが作り直す)。
Flutter と RN の実機用は **Release 構成**(Flutter の Debug は flutter の道具なしでは実機で起動できない・RN の Debug は Metro が前提)。
- **小さい画面と遅い機種でだけ出る赤を拾う**のが役目(2026-10-12 に 510 回中 14 回の赤 = 6 種を見つけた:
  折り返しの下の要素・キーボードで縮む窓・動いている一覧へのタップ・慣性の長さの前提・端末に残った永続設定・
  ホームボタン機)。シナリオや SUT の配置を変えたら e2e-sut.md の「両方の画面で」の確かめ方として回す
- **陽性対照とブリッジの検証済みの印(`.fleetest/*-e2e-verified`)には触らない**(実機は XCUITest だけで、
  利用者の既定モードの経路を通らない)
- **全実施を頼まれたとき以外は `--scenario <Class か Class.method>`(繰り返し可)で絞る**(絞らない起動は
  `Scripts/test-scope-guard.py` が断る)。直したシナリオの確かめは、SUT と OS も絞って
  `Scripts/e2e-devices.sh --cmp --ios --scenario 画像で要素を探す.S0030` の形で回す
- iPhone 13 の分は M1Ultra がこの clone と同じコミットでないと適合チェックで落ちる(`Scripts/align.sh`)。
  手元の実機だけなら `--local`
- 所要の目安: iOS 56 本 × 2 台で約 21 分(並行)・Android は 1 SUT あたり 15〜17 分(2 台並行)

## クラッシュダイアログは回帰スクリプトが止めて戻す(2026-10-03)

`Scripts/e2e.sh` / `e2ex.sh` / `e2ey.sh` / `e2e-negative.sh` / `e2e-devices.sh` は実行中だけ macOS の問題レポーター(Simulator のアプリが
落ちるたびに出る。陽性対照のクラッシュ検知が毎回落とす)を止め、終了時に元の値へ戻す(`Scripts/crash-dialog.sh`)。
`e2ex.sh --on` は向こうの機械で止める。止めても `.ips` は書かれるのでクラッシュ検知は効く(陽性対照で確認済み)。

- `DialogType` は**書くだけでは効かない** —— ReportCrash を `launchctl kickstart -k gui/$(id -u)/com.apple.ReportCrash`
  で読み直させる(戻すときも同じ)
- 同じ機械で重なっても、戻すのは最後に終わったスクリプトだけ(保持者を `~/.fleetest-crash-dialog/holders/<pid>` で数える)
- **SIGKILL で戻せずに死ぬと、次にどれかを回すまで止まったまま**。手で戻すなら:
  `defaults delete com.apple.CrashReporter DialogType && launchctl kickstart -k gui/$(id -u)/com.apple.ReportCrash && rm -rf ~/.fleetest-crash-dialog`
  (元から `DialogType` を設定していたなら `~/.fleetest-crash-dialog/original` の2行目の値を書き戻す)

## 覆い(別ウィンドウのモーダル)の witness は E2EAppIOS にある(2026-08-20)

**自前 SUT に1つも無かった形**を足した: `E2EAppIOS` の `OverlayWindow` が
**キーウィンドウにしない別 UIWindow** に載るモーダルを出す(SDK のアプリ内メッセージ相当)。
2形あるのが要点 —— **全画面モーダル**(背面は隠れる)と**上部バナー**(背面は隠れない)。
片方だけだと「手前の窓だけ見せる」実装でも緑になり、**判定を分けられない**。

回帰は `TestProjects/E2E-iOS/scenarios/15_別ウィンドウのモーダル.swift` の5本
(木に載る / `irregularHandler` が閉じる / バナーは背面を隠さない / `suppressHandler` の中では閉じない /
**条件判定が覆いを閉じてから答える**)。条件判定の1本は 2026-08-20 に追加 ——
`ifCanSelect` は `perform` を通らないので、操作・検証側を直しても自動では守られない。
**この形の失敗は赤くならない**(分岐が黙って飛ぶ)ので、witness 側で不成立を赤くしてある。
**覆いに関する変更を入れたらこの5本を回す**(修正前は落ち、修正後は5本とも緑、が対照)。

**操作側の確認は木では取れない**: 合成タッチの宛先が正しい窓かは、**座標タップ**で確かめる
(`POST /tap {"x":…,"y":…}` でモーダルが閉じるか)。木に載っているのに閉じられない、が
2026-08-20 に実際に残った形。**スクリーンショットも見る** —— モーダルが写らない画像を
証跡として残していた。

## 検証スクリプトそのものの罠

- **エラーを保存・表示するときは切り詰める前に入れ子を畳む**。`prefix(N)` で素の description を
  切ると**真因が構造的に落ちる**(最上位は「The operation couldn't be completed.」のような
  定型文で、原因は `NSUnderlyingError` / `NSMultipleUnderlyingErrors` の奥にある)。
  実害: FM の全滅原因が 300 文字の切り捨てで数日間まったく見えなかった(`FMHealth.describe` 参照)
- **pipefail 下で `cmd | head` を条件式・値の取得に使わない**。head が1行読んで先に閉じると
  上流が **SIGPIPE(141)** で死に、pipefail がそれを失敗として拾う。1行目が欲しいだけなら
  変数へ入れてからパラメータ展開で切る(`${out%%$'\n'*}`)。実害: `if x="$(xcodebuild -version | head -1)"`
  が正常な Xcode を `unusable` と判定し、受け手に無関係な license 同意を案内した(2026-07-29)。
  **矛盾する出力は誤判定の兆候**(このときは `xcode=unusable` と `xcode_first_launch=done` が同時に出ていた)
- **空の結果は成功と見分けがつかない —— 件数を必ず確かめる**(2026-08-03 に3回踏んだ)。
  実験や反復が**そもそも実行されていない**のに、出力は「失敗0」に見える形が3つあった:
  ①A/B で `fleetest` を差し替えたが実行の実体は `fleetest-scenarios-<project>`(→ どんな変更も差なし)/
  ②バックグラウンドの負荷ループが起動せず、**無負荷の測定を「負荷下」と報告**した/
  ③**未マッチの glob で `&&` の連鎖が切れ**、30回の反復が丸ごと走らなかったのに
  「30回中 回失敗」と出た。**判定に使う前に「何回走ったか」「生成物が在るか」を数える** ——
  `ls <出力>/*.log | wc -l` が期待値と一致するか、負荷を掛けたならそのログが実在するか。
  (計測基盤についての同じ規律は PT-4 にもある)
- **zsh の未マッチ glob はエラーになる**(bash と違い素通ししない)。`rm -f dir/*.log` は
  対象が無いと `no matches found` で失敗し、`&&` で繋いだ後続が**丸ごと実行されない**。
  使い捨ての作業ディレクトリは `rm -rf d && mkdir -p d` で作り直す(glob を書かない)
- **zsh は未クォート変数を単語分割しない**。`for x in "a b" "c d"; do set -- $x; ...` は
  bash の感覚だと 2 引数に割れるが zsh では割れず、`$1` に全体が入る。
  実害: SUT×プロファイルの再検証ループが全件「プロジェクトが見つかりません」で空振りした
- **合否を後続コマンドの exit code で潰さない**。`Scripts/e2e.sh > log; echo "EXIT=$?"` のように
  末尾へ何か足すと、**シェル全体の exit code は最後のコマンドのもの**になる。
  バックグラウンド実行の完了通知もそれを見るため「exit 0」と報告されるのに
  中身は `❌ E2E に失敗があります` という食い違いが起きる(2026-07-27 に実際に誤読した)。
  `$?` を表示したいなら**その値でそのまま終わる**(`exit "$?"`)か、ログの `❌` 行で判定する
- **E2E の実行中に `swift build` しない**。走っているランナーの実行ファイルを差し替えると
  プロセスが **SIGKILL** される(`Scripts/e2e.sh: ... Killed: 9`)。シナリオの失敗と紛らわしいので、
  検証中はビルドを挟まない(2026-07-27 に実際に踏み、Flutter の profile が丸ごと落ちた)
- **`log` は絶対パスで叩く**(`/usr/bin/log`)。shell 関数に食われて
  「too many arguments」になる。さらに**自分の述語文字列が `log` プロセス自身のログに出て
  偽の一致行になる**ので、必ずプロセス名まで確認する

## `Scripts/e2e.sh`(fleetest 自身の E2E)

- SUT(`E2EAppCMP/` 他)の鮮度を見て必要なら再ビルドし、各プロファイルを順に回す。オプション:
  `--rebuild` / `--ios` / `--android` / `--cmp` / `--ios-native` / `--android-native` / `--flutter` / `--rn` /
  `--ios-xcuitest`(iOS を xcuitest モードで回す。既定は inapp モード。上記「1回の実行が見るのは…」節) /
  `--ios-inapp`(既定と同じモードで iOS のみ) /
  `--record`(録画パイプラインの整合チェック付き。詳細は下記「録画」節) /
  `--local`(各 run に `--runner local` = この Mac のデバイスだけ。E2EX を M1Ultra で同時に回すときの形) /
  `--performance`(性能計測モード。上記「モニターと E2E」) / `--negative`(最後に陽性対照スイートも回す) /
  `--retrain-classifiers`(各 SUT の画像分類器のキャッシュを消してから回す) /
  `--align`(下記)
- **`e2e.sh` / `e2ex.sh` / `e2ey.sh` は引数に関係なく「スイート全体」として `Scripts/test-scope-guard.py` が断る**(全実施を頼まれたときだけ
  `FT_FULL_TEST=1`)。絞った確認は `fleetest run --project <P> --profile <prof> --scenario <クラス>` で通るシナリオを名指しする
- **回帰の分担(ユーザー指示 2026-09-28)**: E2E はこの Mac(M2Ultra)で `Scripts/e2e.sh --local`、
  E2EX は `Scripts/e2ex.sh --on M1Ultra`(ssh でランナーのクローン `~/fleetest-runner/foundation-tester` に入り、
  **そこで SUT をビルドして**そこのデバイスで回す。残りの引数はそのまま渡す)を**同時に**起こす。向こうで動くのは
  align 済みのコミットなので commit → `Scripts/align.sh` → 実行の順。M1Ultra の道具(Flutter は
  ~/.local と ~/flutter、Homebrew の CocoaPods)は `~/.zprofile` の fleetest-tools ブロックの PATH にある
  (`zsh -lc` は `.zshrc` を読まない)
- **`--align`: リモートランナーの版ズレは「部分実行」ではなく「1本も走らない」**(2026-08-28)。
  複数機に跨るプロファイル(E2E-Android/android)は**開始前**の適合チェックで弾かれるので、
  手元を更新した直後のフルスイートはそのプロファイルのリモート担当ぶんが丸ごと欠ける
  (実際に 22 本中 14 本しか走らず、結果表には「1 of 14 failed」としか出ない)。
  `--align` を付けると実行前に `api remote-compat` を引き、**ランナーがこの clone の祖先
  (`remoteBehind`)のホストだけ** `fleetest remote align` する。**対象のホストは同時に揃える**
  (出力は機ごとのログへ分けて最後にまとめて出す。`Scripts/align.sh` と同じ形。1機ずつ待つと台数ぶん伸びる)。
  **既定では触らない** —— align はランナーの `.build` を差し替えるので、他人(や自分の別セッション)の
  run の下で走らせるとその run を SIGKILL で殺す(RR-18.3 規則2)。
  **向きを取り違えない**: `localBehind`(この clone が古い)・`diverged`(ブランチ作業)・
  未 push・toolchain 不一致・到達不能は**触らずに理由を1行出す**(align では直らない/直す側が逆)。
  判定の写しは `Scripts/e2e-align-plan.py` の1箇所だけで、祖先関係の計算は Swift 側
  (`FTRemote.RemoteCompat`)に任せる(2つ目の実装を作らない)。
  align が見るプロファイル集合は `planned_profiles`(実行ループの写し)なので、
  **実行後に実際に回した組と突き合わせて食い違いを警告する**(片方だけ直すと黙ってズレるため)
- **両OSを1プロファイルにまとめない**: platform 未指定シナリオは既定 platform のキューにしか入らず
  他方のワーカーが空回りする(DS-11.4)。SUT はネットワーク依存ゼロなのでバックエンド死活の
  切り分けは不要
- **フレームワーク差の退行は SUT を跨がないと出ない**。ブリッジのスナップショット/型写像
  (`SnapshotBuilder`・`BridgeRouter`)を触ったら SUT を絞らず全部回す。片方だけ通って
  もう片方が黙って空振りする類の退行が実際に出る(Compose の Button は `Cell`、View/XML は `Button` 等)
- **ディープリンクの URL スキームは SUT ごとに固有でなければならない**(2026-08-09)。
  iOS の E2E シミュレータには4つの iOS SUT が同居するため、共有スキームだと `openurl` の
  解決先が端末ごとに揺れる(実測で別アプリへ配送された)。`DeepLinkSchemeSyncTests` が
  契約(`E2EAppCMP/docs/ui-contract.md`「ディープリンク」)との一致と SUT 間の重複を検出する

## SUT の Info.plist はコミットするソース —— URL スキーム等は直接編集する

iOS の SUT(E2EAppCMP / E2EAppIOS ほか)の `Info.plist` は `project.xcproj` と並ぶコミットするソースで、
ビルドでは書き換わらない。`DeepLinkSchemeSyncTests` が契約(`E2EAppCMP/docs/ui-contract.md`)との一致を守る。
Flutter / RN の SUT の `Info.plist` も同じ(ソース)。

## E2E を同時に2つ走らせない(2026-08-09)

同じシミュレータ群で2つのスイート(サブエージェントの検証と自分の反復)を並行させたところ、
単独なら 22/22 緑のプロファイルが 16/22・11/22 失敗に崩れた。**フレーク判定の反復を始める前に、
他に実行中の run が無いことを確認する**(`ps aux | grep e2e.sh`)。サブエージェントにデバイス
検証を許可したら、その間は自分で回さない。

## 受け手フロー(preflight / install.sh)の検証

- **更新は `Scripts/update.sh`**(install.sh を再実行 + `project sync`。スキルのコピーの更新は install.sh のステップ7.8。版が変わったら新しいリリースの注釈を表示)。
  clone 構成でこれを回すとき、**受け手向けの整備がクローン自身に効かないこと**を確かめる
  (実害: install.sh の `.gitignore` 追記がリポジトリを dirty にし、次の更新が pull ガードで
  止まる。現在は clone 構成では skip する。`.gitignore` の項目は `ProjectScaffold.ensureGitignore`
  と対 — 片方だけ変えない)
- **clone 構成でクローンを dirty にしたまま `install.sh` を試すと必ず止まる**(ローカル変更の破棄を尋ね、
  端末が無い実行では中止する仕様。外部構成では尋ねずに破棄する = `--keep-local` で尋ねる側へ)。本体を触りながら試すときは **`--no-pull`** を付ける
- 実行の記録は `<WORK_DIR>/.fleetest/install-<日時>.log`(実行ごとに別ファイル)。
  端末出力を追わずに後から失敗を追える
- **スキルが渡す新しい引数は、受け手のクローンが pull されるまで存在しない**。
  スキルは**クローンのローカルの Scripts/**(SKILL.md の3つ上。手順書と同じ版)の
  ファイルを `bash` で呼ぶ(`curl | bash` はエージェントの安全確認に止められるので使わない)。
  実害: `--platform` を渡した初回が「不明なオプション」で落ちた(2026-07-29)
- 個別コマンドを叩いて確かめる前に、**preflight と install.sh の出力に既にあるか**を見る
  (`tool_root=` / `[ok] MCP` / `[ok] ルート解決`)。取り直しは承認回数を増やすだけ

## 常駐プロセスの掃除

- **ディレクトリを消しても `.build` が戻る**のは、生きているプロセスが作り直しているから。復活させる
  主体は MCP の rebuild-on-start(`.mcp.json` が起動のたびに `swift build`)と拡張のパネル respawn。
  **VSCode 終了で止まらないのは XCUITest ランナーだけ**(親から切り離してあり PPID=1)。
  順序と掃除の1行(`pgrep -fl` / `pkill -f`)は docs/user-docs/uninstall_ja.md
- 再ビルド後の検証前に旧バイナリの常駐プロセス(monitor/host-metrics)を kill する
  (生き残って検証を汚す・旧ブリッジを自動再起動する。PT-7)
- ブリッジには無通信 TTL(既定2時間。DS-4.1)があるが、**検証の掃除で TTL を
  当てにしない**(旧版ブリッジには入っていない・モニターのポーリングが心拍になり失効しない)
- **調査で `fleetest api monitor` を手で回すときは stdin を開いたままにする**
  (`tail -f /dev/null | fleetest api monitor ...`)。**stdin の EOF が終了指示**なので、
  スクリプトからバックグラウンド実行すると /dev/null が即 EOF になり、
  **1行も出さずに正常終了**する(「監視が何も返さない」ように見える罠)

## 実機(kind: physical)の検証

プロファイルの書き方は DS-11.2。ここは実機でだけ踏む罠だけを置く。

### Android 実機

- **画面ロックは「なし」にしておく**。PIN/パターンが設定されていると adb から解除できず、
  ロック中は `UiAutomation.getRootInActiveWindow()` が対象アプリにならないので **全シナリオが
  launch 500(「アプリの画面が表示されませんでした」)で落ちる**
- run 前に `AndroidPhysicalDevice.prepareForRun` が点灯・ロック解除を行う。**消灯は抑止しない**
  (2026-09-05 ユーザー決定。`svc power stayon` は true も false も撃たない —— false を旧版の後始末として
  撃っていた頃は、持ち主の「充電中はスリープしない」を run・MCP のたびに消していた)。
  その代わり**シナリオごと(子プロセス)と MCP の呼び出しごとに1往復で画面を確かめ、消灯・ロック中の
  ときだけ起こす**(`wakeIfAsleep`。0.07〜0.15 秒)。run 開始時の1回だけだと、途中で1回消えた後の
  全シナリオが launch 500 で落ち、消灯に一言も触れなかった(2026-09-11 Pixel 4a で 22/24 赤)
- **ロック状態の判定に `isKeyguardShowing` と `mCurrentFocus` を使ってはいけない**。
  Pixel 4a/Android 13 実測(2026-07-25)で、実際には解除されランチャーが見えている状態でも
  `true` / `NotificationShade` を返し続けた。**信用できるのは `topResumedActivity` の有無だけ**
  (ロック中はどのアクティビティも resume されないので行ごと消える)
- `wm dismiss-keyguard` は非同期で **解除完了まで実測 3〜7 秒**。待たずに launch すると
  run の初回シナリオだけが落ちる(8 run 中 1 件の flake として現れた)
- **Android 側の画面凍結(blank-screen)判定は実機では動かない**。閾値(30KB)が 1080x2424
  エミュレータ較正で、誤判定すると健全な実機に `adb reboot` を撃つため、事前トリアージ・
  事後プローブ・失敗時の blank 証跡判定のいずれからも実機を除外してある。
  **2026-09-25 に観測だけは足した**(修復は今も無い): `BlankWorkerTriage` が両 OS の実機を
  対象に含め、一様な絵を `FrozenEvidence.darkScreenPhysical`(`isConclusive=false`)として
  **警告1行に留める** —— 消灯と wedge を分ける材料が無いので確定させない。
  `adb reboot` を撃つ経路は上の3つのままで、そこに実機は入らない(docs/design/ の該当節)。
  **2026-09-25 に修復も入った(Android 実機だけ)**: `mWakefulness=Awake` なのに一様なら
  画面の sleep/wake を1回撃つ(`AndroidPhysicalDevice.cycleScreen`)。**再起動は撃たない**・
  **戻らなくてもレーンからは外さない**・**消灯かもしれないデバイスには撃たない**。
  iOS 実機は点灯状態を取る材料が無いので観測だけのまま
- ブリッジ起動時のアニメーション無効化と `hidden_api_policy=1` は **実機では設定が永続する**
  (使い捨てのエミュレータと違う)。戻すときは端末の開発者オプションから
- 検証実績: Pixel 4a(Android 13 / arm64)で E2E-Android 全 21 シナリオ×6 連続グリーン
  (消灯状態からの復帰込み。2026-07-25)

### iOS 実機

- **署名が要る**。`~/.config/fleetest/config.json` の `developmentTeam`(または環境変数
  `FT_DEVELOPMENT_TEAM`)に Apple Developer の Team ID を入れる。bundle id プレフィックスは
  `bundleIDPrefix` / `FT_BUNDLE_ID_PREFIX`(既定 `com.example` のままだと他チームが登録済みの
  App ID と衝突しうる)。ビルドは `-allowProvisioningUpdates` 付きで走る
- **Team ID は証明書の OU**。`security find-identity -v -p codesigning` の
  `Apple Development: <you> (XXXXXXXXXX)` の**括弧内は証明書 ID であって Team ID ではない**
  (取り違えると `No Account for Team "..."` で落ちる。2026-07-25 に実際に踏んだ)。正しくは:
  ```
  security find-certificate -c "Apple Development: <you>" -p | openssl x509 -noout -subject
  # → subject= UID=..., CN=Apple Development: ... (証明書ID), OU=GF42S2868Q, ...  ← OU が Team ID
  ```
- 端末側は「このコンピュータを信頼」と **Developer Mode の有効化**が前提。
  `xcrun devicectl list devices` に出ることを先に確認する
- **端末のロックを解除しておく**(Android と同じ前提)。ロックされていると xcodebuild が
  `Unlock <name> to Continue` で無言のまま止まる。**ビルドと起動の前にホストが現況を見て促す**
  (`IOSPhysicalDeviceLock`。`xcrun devicectl device info lockState` の **`passcodeRequired`** =
  「今パスコードの入力が要るか」で、静的な設定の有無ではない。実測 0.23 秒・消灯 true /
  解除 false・自動ロック 30 秒での遷移も観測)。**ビルド前は促すだけで待たない**(ビルドに解除は
  要らないので、その数分の間に解除してもらう)/ **起動の直前は解除まで待ち**(2 秒刻み・上限は
  `BridgeLauncher.startupTimeoutSeconds` と同じ 180 秒)、**待ち切ったら撃たずに落とす**
  (撃っても deviceprep に拒否され、もう 180 秒待って同じ理由で死ぬだけ)。
  **パスコード未設定の端末では常に false** なので見落とすが、誤検知は出さない側に倒してあり、
  従来の xcodebuild ログからの検出(`IOSDeviceTransport.blockingCondition`)に落ちる。
  **`devicectl device info displays` の `backlightState` は使えない**(消灯中でも `activeOn`)。
  **端末の自動ロックは「なし」にしておくこと**(設定 → 画面表示と明るさ → 自動ロック)。
  **ツールは起こさない**(2026-09-05 にランナーのパルスを廃止した。版 89)——
  合成した入力は実機では本物の HID で、「無害な玉」という前提が OS の版で反転する
  (iOS 26.5.2 では `press(.home)` が SpringBoard に届かず、**26.6 では届いて対象アプリが
  run の途中でホーム画面へ落ちた**)。`isIdleTimerDisabled` も効かない(2026-08-27 実測:
  10 秒ごとに貼り直してもちょうど 30 秒で寝る。ランナーは対象アプリを起動した時点で背面に
  回り、idle timer の申告は前面アプリのものしか効かない)。
  自動ロックのまま走らせると、待ちの長いステップで寝て以後の launch が拒否される。
- **端末で開発者証明書の信頼が要る**。ビルドとインストールが成功しても、起動時に
  `The application could not be launched because the Developer App Certificate is not trusted.`
  で落ちる。iPhone の **設定 → 一般 → VPN とデバイス管理** からデベロッパ App の証明書を「信頼」する。
  **「初回だけ」ではない**: 証明書やプロビジョニングプロファイルが作り直されると再度必要になる
  (2026-07-26 に一度信頼済みの端末で再発)
- **端末が起動を拒否した条件は xcodebuild の終端マーカーを待ってはいけない**。証明書未信頼の
  エラーはログの 20 秒時点に出ていたのに、`** TEST EXECUTE FAILED **` も `Testing failed:` も
  最後まで出ず、締切 181 秒まで待たされたうえ「LAN アドレスを取得できません」という無関係な
  理由で失敗した(2026-07-26 実測)。証明書未信頼・Developer Mode 無効は単独で終端扱いにする
  (`IOSDeviceTransport.runnerFailureReason`)。理由を特定できない失敗だけは誤検知を避けるため
  従来どおりマーカー待ち
- `devicectl list devices` の **Identifier 列(UUID)と `hardwareProperties.udid`(`00008130-...`)は
  別物**。`xcodebuild -destination id=` が受け付けるのは後者だけ(`devicectl --device` はどちらでも
  通る)。プロファイルの `udid` には後者を書く(前者を書いても解決はする)
- **`connection.state` は当てにならない**: USB 接続中で `devicectl list devices` が
  `available (paired)` と表示している実機でも `disconnected` のままだった。未接続の実機は
  そもそも一覧に出てこないので、一覧に居ること自体を到達性の主信号にしている
- `hardware.reality`(CoreDevice の `DeviceReality`)は **`physical` / `simulated` / `virtual`(VM)
  の三値**だが、**実機は値を出さずキーごと省略する**(Xcode 27 beta 4 実測: 68 台中 67 台が
  `simulated`、実機 1 台はキー欠落)。`"physical"` 一致で拾うと**実機が 1 台も見えない**ので、
  必ず「`simulated` 以外」で弾くこと
- SUT の実機ビルド例: `E2EAppIOS/scripts/build-ios-device.sh`(`-sdk iphoneos` + 自動署名 →
  `dist/ios-device/`)。シミュレータ版(`dist/ios-simulator/`)とは実体が別なので
  **apps プロファイルを分ける**(`ft_e2e_ios_device.json` / 実行は `ios-device`)
- **xcodebuild のテストログは CRLF**。Swift では `"\r\n"` が 1 つの Character なので
  `split(separator: "\n")` は CRLF を**一切分割しない**(ログ全体が 1 行になる)。
  ランナーの `FT_BRIDGE_ADDR` 宣言を拾う所で踏んで 180 秒待って失敗した。
  ログを行単位で見るコードは `split(whereSeparator: \.isNewline)` を使うこと
- ブリッジの到達手段の確立に失敗したら**必ず `launcher.stop()` する**。xcodebuild は実機で
  走り続けるので、止めないと失敗のたびに常駐ランナーが端末に溜まる(実測で 5 本残った)
- **実機とシミュレータを同じ run に混ぜられる**が、xctestrun は種別ごとに別物なので
  `prepareSharedBuilds` は**種別ごとに build-for-testing する**(1 つだけビルドすると、
  選ばれなかった側が `xctestrunNotFound` で落ちる)
- 検証実績: iPhone 15 Pro(iOS 26.5.2)で E2E-iOS 全 20 シナリオ = LAN ×3・USB ×6 連続グリーン
  (2026-07-25〜26)。ブリッジ供給は約 8 秒。壁時計は USB 181〜211s / LAN 241〜259s
- **トランスポートは端末の接続形態で決まる**: `devicectl` の `transportType` が `wired` でなければ
  (= WiFi のみ)**iproxy は USB トンネルを張れない**ので lan に落ちる。ここを見ずに
  「iproxy があれば usb」で選ぶと、`network connection was lost` で 180 秒待って失敗するだけの
  無情報な結果になる(2026-07-25 に実際に踏んだ)。明示指定 `FT_IOS_DEVICE_TRANSPORT` は尊重する
- **端末ロックの検出は締切後にもう一度ログを読む**。xcodebuild は諦めた時点で初めて
  `Unlock <name> to Continue`(deviceprep Code=-3)を書くことがあり、待機ループ内の読み取りだけでは
  間に合わずタイムアウトとしか出ない(`BridgeLauncher.waitUntilReady` の physicalDiagnosis)
- **ブリッジのトランスポートが 2 択**(デバイス内のループバックはホストから見えない。
  Xcode 27 の devicectl にポート転送は無い)。`FT_IOS_DEVICE_TRANSPORT=lan|usb` で明示、
  未指定なら iproxy があれば usb、無ければ lan。**usb を強く推奨**(下記実測):

  | 経路 | 1 往復(`/status`) | ばらつき | E2E-iOS 20 本 |
  |---|---|---|---|
  | シミュレータ(loopback) | 1.1 ms | σ 0.2 | 174.6s(6 台並列で壁 38.5s) |
  | 実機 **usb**(iproxy) | **4.7 ms** | σ 0.7 | **181.3s** |
  | 実機 lan(WiFi) | 47.9 ms | σ 26.9 | 241.1s |

  LAN が遅いのは **iOS の WiFi 省電力**(ICMP でも avg 74ms / σ 32ms)。DSL の 1 ステップは
  セレクタ解決・操作・整定確認で 8〜13 回ブリッジを往復するため、48ms × 10 回 ≈ +0.5s/ステップに
  なる。ペイロードは 0.1KB なので**帯域ではなく往復回数**の問題(2026-07-25 実測)。
  usb にすると 1 シナリオあたり 12.1s → 9.1s で、シミュレータ(8.7s)とほぼ同等になる:
  - `lan` … ランナーが `0.0.0.0` に bind し(`FT_BIND_ALL=1` を xctestrun に注入)、自分の
    LAN IPv4 を `FT_BRIDGE_ADDR=<ip>:<port>` としてテストログ(`.fleetest/bridge-<port>.log`)に
    1 行出す。ホストはそれを読んで宛先にする。**Mac と端末が同じネットワークに居ること**
    (クライアント分離 WiFi では不可)
  - `usb` … `iproxy`(`brew install libimobiledevice`)で USB トンネルを張り 127.0.0.1 を維持する
- 実機とシミュレータで DerivedData を分けてある(`.fleetest/DerivedData-device`)。混在させると
  `findXCTestRun` が iphoneos/iphonesimulator の誤った方を掴む
- **mode=xcuitest ならデバイスで動く、は誤り**だった箇所: `FastLaunchDriver`(xcuitest でも既定 ON・
  中身はアプリの再起動)と `LaunchPreflightDriver`(未インストール検査)は
  実機では無効化される(`--physical`)。素の `XCUIApplication.launch()` 経路に落ちる。
  どちらも 2026-08-02 に CoreSimulator 直叩き優先へ変えたが(DS-16.4)、
  **シミュレータ専用という前提は変わっていない**(simctl も CoreSimulator も実機には効かない)
- アプリは `xcrun devicectl device install app` で入る(**署名済みの .app/.ipa が要る**)。
  SUT のシミュレータ用ビルド(`-sdk iphonesimulator`)はそのままでは使えない
- **UDID の先頭は機種共通**(`00008130-` は iPhone 15 Pro 系の固定値)。先頭 8 文字を
  識別子として表示すると同型機が全部同じ表示になる。個体固有なのはハイフン以降

### iOS 実機ブリッジが立たないとき(3 大原因)

原因はほぼこの 3 つ。**いずれも現在は原因が名指しで報告される**ので、まずメッセージを読む
(そうなるまでに 3 回とも「180 秒待って無情報なタイムアウト」を踏んでいる)。
ログは `.fleetest/bridge-<port>.log`:

| 症状・ログ | 原因 | 対処 |
|---|---|---|
| `Unlock <name> to Continue`(deviceprep Code=-3) | 端末ロック | 解除し、**自動ロックを「なし」にする**(ランナーは端末を起こさない。上の「端末の自動ロックは「なし」にしておくこと」) |
| `Developer App Certificate is not trusted` | 証明書未信頼 | 設定 → 一般 → VPN とデバイス管理 |
| `network connection was lost` が延々続く | WiFi 接続なのに usb を選んだ | USB で繋ぐ(自動で lan に落ちる) |

検出側の設計上の要点(**同じ間違いを繰り返さないため**):
- ロックは「失敗」ではなく「進まない」だけなので、xcodebuild のログから拾う経路では throw せず
  促す。ただし xcodebuild は**諦めた時点で初めて**理由を書くことがあるので、待機ループ内だけでなく
  **締切後にもう一度**ログを読む(`BridgeLauncher.waitUntilReady` の physicalDiagnosis)。
  **起動の直前の判定(`IOSPhysicalDeviceLock`)だけは待ち切ったら throw する** —— あちらは
  「今ロックされている」ことを端末に直接訊いており、撃っても拒否されるのが確定しているため
  (推測ではなく現況。`.unknown` では throw しない)
- 証明書未信頼・Developer Mode 無効は**終端マーカーを待たずに確定**させる(理由を特定できない
  失敗だけマーカー待ち)。詳細は上の「iOS 実機」節
- トランスポートは `transportType` で決める。`FT_IOS_DEVICE_TRANSPORT` の明示指定は尊重する

### 実機とモニター・API

- `api list-devices` / `api monitor` は実機を返す。**状態判定は両者で共有**(`determineStates`)なので、
  片方を直せば両方直る。実機で踏んだ罠:
  - **Android 実機は `avd` が無いので、AVD 前提のままだと永久に offline**(「avd が未設定です」)。
    `serial` を `adb devices` の接続一覧で確認する分岐が要る
  - **iOS 実機の `/status` は device に機種名("iPhone")を返す**。実行プロファイルのデバイス名
    (例「iPhone wave(実機)」)と一致しないため、名前照合では永久に connected にならない。
    ランナープロセスの `-destination id=<UDID>` で帰属を決める(`BridgeLauncher.portsMatching`)
  - LAN 経由の実機ブリッジは 127.0.0.1 に居ないので、ポートスキャンは `.endpoint` を見る
  - **`ps -p <pid列>` を使ってはいけない**: 範囲外の pid が 1 つ混じるとエラーになり、
    **生きている分も含めて出力が空になる**(pid ファイルは壊れた値を持ち得る)。全プロセスを
    列挙して pid で引く。また monitor は 2 秒間隔でこれを呼ぶので、pid ごとに `ps` を spawn すると
    常駐ブリッジ本数 × 0.5 回/秒のプロセス生成になる(1 回にまとめる)
- `api installed-devices` は `ios.physicalDevices` / `android.physicalDevices` に接続中の実機を返す
  (既存の `devices` / `avds` はシミュレータ・AVD のまま)。
  AVD には `model`(config.ini の `hw.device.name`)と `os`(`image.sysdir.1` の `android-<API>`
  から導出)も付く — エミュレータはプロファイルに機種/OS を持たないため、表示はここが唯一の出所
- `kind`("virtual"/"physical")を `list-devices` と `monitor` の各デバイスに追加した。
  拡張側は必須の欄として読む(欠けた行は不正。2026-09-20 の方針で後方互換の読み替えは置かない)

### 実機と VSCode 拡張

- デバイスタイルは実機に「実機」バッジを出す。右クリックの起動/停止は**項目を残したまま
  ラベルを「ブリッジを起動/停止」に変える**(実機は端末そのものを起動・停止せず、操作対象は
  ブリッジだけ)。**項目を隠してはいけない**: 隠すとモニターから実機のブリッジを起動できず、
  タイルが「接続中」のまま何もできなくなる(2026-07-25 に実際にそうしてしまった)
- `kind`/`serial` は拡張側の 2 箇所(`config.ts` の `MachineDeviceEntry` と `monitorProfileForms.ts` の
  同名型)に独立定義がある。**両方直すこと**(vscode 非依存を保つための意図的な重複)
- 機種/OS はプロファイルに無ければ `installedDevicesRequest` で取りに行くが、**要求は
  1 デバイス 1 回に絞ること**。この要求は毎回 `fleetest api installed-devices` を spawn する
  (devicectl + adb getprop で数秒)ので、値が埋まらないデバイス(未接続の実機・`hw.device.name`
  の無い AVD)では 応答→再描画→再要求 が閉じず CLI を叩き続ける(2026-07-25 のレビューで検出)
- **ネイティブ `title` は表示遅延を指定できない**(ブラウザ/OS 固定で約 1 秒)。省略表示の全文を
  素早く出したい所は自前ツールチップ(`hoverTip.js`、0.2 秒)を使う。要点は
  ① `position: fixed` で body 直下に出す(名前ピルの親 `.tile-header`/`.lane-header` は
  `overflow: hidden` なので子要素方式だと切られる)② 対象に `title=""` を置いて祖先の `title` が
  遅れて二重に出るのを止める

### 実機の画面配信(fleetest-devicepoll)

**実機は両OSとも `fleetest-devicepoll`**(スクリーンショットのポーリング → MJPEG)に一本化した。
既存の 2 ヘルパーが実機で使えないため:

- `fleetest-simstream` は CoreSimulator/SimulatorKit の私有 API で deviceSet から UDID を引くので
  **iOS 実機では原理的に不可**。macOS 27 では iOS 実機を AVCaptureDevice として出す
  **DAL プラグインも消えている**(`/System/Library/CoreMediaIO/Plug-Ins/DAL` が存在せず、
  カメラ権限を付与した Info.plist 埋め込みバイナリでも CoreMediaIO デバイス数 0。2026-07-25 実測)
  ので、QuickTime 方式の代替も無い
- `fleetest-androidstream`(adb screenrecord)は Android 実機だと **画面が動いている間しか
  フレームが流れない**(操作中 455KB / 静止画面はキープアライブの 20 バイトのみ)。
  エミュレータは静止時もフレームが出るためこの差は顕在化しない
- あわせて **`screenrecord --time-limit 0`(無制限)は API 34 以上でしか使えない**ことも判明
  (Android 13 実機は即終了して 47 バイト)。androidstream は API レベルで `0` / `180` を選ぶ

devicepoll の要点:
- 宛先は iOS が `--host/--port`(ブリッジの `/screenshot`)、Android が `--serial/--adb`
  (`exec-out screencap -p`)。拡張は `api monitor` の `kind`/`host`/`port`/`serial` で振り分ける
- 出力は **v1(MJPEG)固定**。`--max-width` は既存ヘルパーと同じく**幅**の上限
  (ImageIO の `kCGImageSourceThumbnailMaxPixelSize` は**長辺**基準なので長辺換算して渡すこと。
  そのまま渡すと 1080x2340 で 360 指定 → 166x360 になる)
- 実測(2026-07-25、fps=2 / max-width 360): Android 実機 360x780 が 7 秒で 13 枚、
  iOS 実機 360x781 が 8 秒で 16 枚。**静止画面でも出る**のがこの方式の要点

## 録画(record:true)の検証

録画パイプライン(Recorder/Finalizer/Coordinator/`RecordingWallClock`)を触ったら、
ユニットテストでは AVFoundation・デバイス境界を捕まえられないため、record:true の実 run で確認する:

- **録画パイプラインの退行は `Scripts/e2e.sh --record` で検知できる**(各プロファイルの一時コピーに
  record:true を付けて実行し、`Scripts/check-recordings.py` が schemaVersion・クリップ数・
  クリップ長・mp4 存在を機械チェックする。元のプロファイルは書き換えない)
- **クリップ数 = シナリオ数**(シナリオが来なかったアイドルワーカーの録画は破棄される)、
  **クリップ長 ≒ シナリオ durationMs**(ミリ秒オーダーで一致するのが正常)、index.json(schemaVersion 2)の整合
- **VFR の罠**: simctl/screenrecord は「画面が変化した時だけ」フレームを吐く。切り出しは
  「区間開始前の最後のフレームを retime して先頭に置く」+「endSession で区間終了まで保持」が無いと
  先頭/末尾が欠ける(実測: 11.1s ソースが endSession 無しで 8.7s に縮んだ)
- **codec は H.264 固定**(再生側 = 拡張 webview の Chromium は HEVC 不可)。simctl に bitrate ノブは
  無く、圧縮はファイナライズの再エンコードで行う(bitrate は run profile の recordBitrateKbps、
  解像度は recordFullResolution。`VideoRecordingFinalizer` の shrinkThreshold を誤ると Android
  ソースの二重縮小になる実害があった)
- **サイズの目安**: 1テスト 0.1〜3MB(iOS 約50〜150KB/s、Android は静止的で約8〜30KB/s)。
  大きく外れたら解像度判定(shrinkThreshold)かビットレートを疑う
- Android screenrecord は180秒上限のセグメントループ。停止は**デバイス側プロセスへ kill -2**
  (ホストの adb クライアント kill ではファイルが壊れる)。iOS simctl は SIGINT 停止・SIGKILL 禁止
- **ホストの HW エンコーダ(AVE)無応答でファイナライズがハングし得る**(実害 2026-07-27:
  macOS 27 beta で 5 並列エクスポート+モニターの simstream 5 本の負荷中、`finishWriting` →
  `VTCompressionSessionInvalidate` → RemoteVideoEncoder の同期 XPC が AVE 応答待ちのまま止まり、
  全シナリオ成功後に run が終わらなかった)。保護は VideoRecordingCoordinator に実装済み:
  クリップ 1 本ごとに期限 `max(60s, ソース総尺)`・1 本でも期限超過したらその run の残りクリップを
  断念(警告 1 回)・エクスポート同時実行は 2 本。期限側は敗者 task を放置する
  (`cancelWriting` は固着した VT セッションのロックで共倒れし得るため呼ばない)
- **「全シナリオ完了済みなのに run が終わらない」の診断**: `sample <fleetest の pid>` を取り、
  `VTCompressionSessionInvalidate` / `RemoteVideoEncoder_EncodeFrame` が居れば上記のエンコーダ
  無応答(相手側の VTEncoderXPCService プロセスも `AVE_UCRecv` で待っている)。ツールは期限で
  自力離脱するので待てばよい。頻発するなら OS 再起動でしか AVE は復旧しない
- **切り出しは今はハードウェア優先**(2026-10-18 に変更。採った理由と実測は PT-3.37・docs/design/ の録画の節)。
  以下は 2026-09-17 にソフトウェアへ固定したときの記録:同じ素材・本番と同じ条件(12 秒クリップ
  16 本・同時 2 本・期限 60 秒)で交互に 8 回ずつ回した実測: ハードウェアは 8 回中 2 回で 1 本ずつ
  `VTCompressionSessionInvalidate` から戻らず期限の 60 秒を払った(その回の所要 64s、他は 10.5〜10.9s)。
  ソフトウェアは 0 回・11.1〜11.6s。1 本の中央値は 1.35s / 1.39s でほぼ同じ、12 秒クリップの大きさは
  2.79MB(指定 1500kbps の +24%)/ 2.07MB(−8%)。画質とモニターの配信を流した負荷下は比べていない。
  計測は `VideoRecordingFinalizer.swift` を写した単体プログラムで行った(FTCore の内部関数で外から呼べない)
- **端末側に録画セッションが残った iOS シミュレータ**(simctl が `Host recording is already in progress` か
  `A recording is already in progress` = どちらも EBUSY で即落ちる。Xcode 27.2 で SIGKILL した client の後に残るのは後者。client プロセスが残っていなくても解けず、shutdown → boot でだけ解ける)は、
  録画ありの run の**供給段階**で `HostRecordingProbe` が見つけ、凍結の回復と同じ経路で再起動する
  (健全機の検査は 1 台約 0.4s・全台並列)。**陽性対照**: 起動中のシミュレータで
  `xcrun simctl io <udid> recordVideo --codec=h264 --force /tmp/x.mov &` を 3 秒走らせて `kill -9` する
  (SIGKILL で殺した recordVideo はセッションを残す = この状態を作れる。`Recording started` が出てから殺す)→ もう一度 recordVideo を撃って
  EBUSY になることを確かめる(2026-10-18 に `A recording …` の形で再確認し、run の再起動で解けた) → そのデバイスを含む record:true の run を回し、
  `hold a stale host recording session … rebooting` と `the stale recording session(s) are gone` の2行が出て、
  そのデバイスのクリップが index.json に載り `sourcesFailed` が無いことを見る
- **録画が run の途中で止まったときの静止画への切り替え**(`VideoRecordingCoordinator.prepareScenario`)の陽性対照(2026-10-18 に両 OS で確認):
  1 台に絞った run(`--device … --runner local`・15 本)を起こし、45〜50 秒後から run が終わるまで録画を止め続ける。
  Android は端末上の自分の screenrecord(cmdline に `/sdcard/ftrec-` を含むもの = 配信は巻き込まない)を 0.5 秒ごとに止める /
  iOS は `pkill -INT -f 'io <udid> recordVideo'` を 0.2 秒ごと(**SIGKILL にしない** = 端末側のセッションが残り再起動まで録画できなくなる)。
  見るもの: `the screen recording stopped and could not be restarted — … still frames` の1行・全シナリオ緑・index.json の
  `sourceIssues` に `stillFramesFallback: true`・静止画のクリップが再生できること。Android を `kill -9` で止めると最初のセグメントが
  読めなくなり、その区間のクリップは `no readable recording covers this scenario` として失敗に数えられる(黙って欠けない)
- **iOS の録画の試し撮りが止まらずに残っていないか**: run の後に `ps -axo command | grep -E '^/[^ ]*simctl io .* recordVideo'` が空で、
  `results/` に `*~smoke.mov*`(試し撮り)や `*.sb-*`(simctl の一時ファイル)が残っていないこと(残っていたら MN-87 の形)

### WebView を触ったときの検証

- **DOM 経路は in-app だけ**(`InAppWebViewDOM`)。利用者の既定モードは inapp モード = in-app ブリッジ優先で、
  既定の e2e.sh も iOS を in-app で回すので既定スイートに入る(2026-08-11 の反転前は
  xcuitest 既定で、この経路が丸ごと未検証のまま緑になっていた)。**`--ios-xcuitest` 側も回す** ——
  WebView は xcuitest では a11y 経路になるため、両方通さないと片側の退行が残る。
- **SUT を絞らない**。WebView の埋め込み方がフレームワークごとに違い、退行が SUT を跨がないと出ない:
  ネイティブ(WKWebView 直)/ CMP(UIKitView interop)/ Flutter(platform view)。
  実例: CMP と Flutter は interop が合成タッチと `insertText` を横取りするため DOM 経路を使わない
  (uikit ホストのみ有効)。この分岐は E2E でしか壊れているとわからない。
- **効果測定は `FT_WEBVIEW_DOM=off` との A/B** で取る。比較は
  `TestProjects/E2E-iOS/results/runs/<YYYY-MM>/<run>/scenarios/WebViewの中身を操作できること.S0010.json` の
  `timeline`(scene 2 以降の exist/textIs の中央値)と `scenes[0].durationMs`。
- **ブリッジ版を上げ忘れない**。iOS = `bridgeProtocolVersion`、Android = `VERSION_CODE` +
  `expectedBridgeVersionCode`。上げないと稼働中の旧ブリッジが再利用され、**変更が入っていないのに緑**になる。
  開発中に同じ版のまま APK/dylib を差し替えるときは、明示的に `adb uninstall com.example.ftbridge` /
  アプリ再注入で入れ直すこと(実際に1度踏んだ)。検出の仕組みは下記。

## ブリッジ版数の上げ忘れ検出(2026-07-30)

`BridgeContractTests` が2段で検出する。実装を変えたらここが落ちるので、**版を上げてから**期待値を
貼り替える(貼り付け用のリテラルは失敗メッセージが出力する)。

| 段 | 何を見る | 捕まえる事故 |
|---|---|---|
| ルート表 | ハンドラの `case ("GET", "/status")` 等を正規表現で抽出 | エンドポイントの増減 |
| ソース指紋 | `BridgeSourceSet` が挙げる入力の内容 SHA256(ファイル単位) | **ルートが同じでハンドラだけ変えた**・入力ファイルの追加/削除 |

- **入力ファイルの一覧は `Sources/FTCore/BridgeSourceSet.swift` が唯一の定義元**。
  `InAppLauncher` の dylib 再ビルド判定も同じ一覧を使う(再掲するとズレる。実害: 共有 DTO の
  `WebViewDOMSnapshot.swift` が `build.sh` の入力なのに再ビルド判定から漏れ、そのファイルだけを
  編集しても古い dylib が注入され続ける状態だった)
- **指紋は生バイト = コメント編集でも落ちる**(意図的)。文字列リテラル中の `//` を素朴に削る
  コメント除去は**変更を見逃す側**に倒れるため、誤検出の側を選んでいる。版を上げるに値しない
  変更なら期待値の貼り替えだけでよい
- `AndroidRunner/build.sh` は `VERSION_CODE=` 行だけマスクしてハッシュする。マスクしないと
  「版を上げた」こと自体で指紋が動き、「ソースが変わった」信号が濁る
- **残る限界: 版を上げること自体は強制できない**。期待値を更新して版を据え置くことは手続き上
  できてしまう。リポジトリ内の期待値は書き換え可能なので原理的にここが上限で、達成しているのは
  「無音で緑」を「版数の判断を意識的に迫られる」へ変えることまで
- **反復開発中は「同じ版・別バイナリ」も再利用される**(2026-08-01 実害)。版を先に上げてから
  実装を差し替えていく開発ループでは、途中のビルドも最終ビルドも同じ版数なので、provision の
  版一致再利用が**古い方の稼働中ランナー**を掴む。計測・e2e の前に該当ブリッジを
  `bridge down` してから張り直すこと(版の照合では検出できない)
- **計測ハーネスは対象の版を開始時と終了時の両方で読む**(2026-08-01 実害)。計測中にランナーが
  死ぬとモニターが respawn するが、**張り直すのは別クローン・別ビルドのことがある**
  (どの clone の監視が先に気付くか次第)。開始時の /status だけ見て「v29 を測った」と
  思い込むと、途中から旧版を測っていても気付けない。終了時にも読んで食い違いを申告させる

### 保留: ブリッジ自身にソース指紋を申告させる案(再発明防止)

版数を人間が上げる代わりに、**ブリッジがビルド時に自分のソース指紋を埋め込み `/status` で申告し、
ホストは自分が計算した指紋と一致するものだけ再利用する**——これなら上げ忘れという概念自体が消える。
**Android で詰むため未着手**: コミット済み `AndroidRunner/prebuilt/ftbridge.apk` があるので、
`.java` へのコメント1行の編集でも受け手側のホストが「指紋不一致」で再インストールを試み続ける
(APK が古いままなので永久に一致しない = `AndroidBridgeVersionSyncTests` が警告している状態に
全編集で入る)。全編集で APK の作り直し・コミットが必須になる。

**再検討条件**: Android ブリッジの APK をコミット済み成果物ではなく供給時ビルドに変えられたとき、
または指紋の対象を「ソース」ではなく「ビルド成果物(dex)」に取れる安価な手段ができたとき。
