# 検証: 環境と運用

| 種別 | 範囲 | 読む場面 | 扱わないこと |
|---|---|---|---|
| 手順 | ランナーの再ビルド・OS 更新後の再学習・モードの片方だけ・再起動直後・モニターと E2E・実機の E2E・クラッシュダイアログ | E2E を回す前・環境の変化の後 | 毎回効く最重要ゲート(→ CLAUDE.md「ビルド・検証」) |

節の一覧はこのフォルダの README.md。

## iOS ランナー(Runner/)の再ビルドは供給時に自動化済み(2026-07-28)

`BridgeProvisioner.prepareSharedBuilds` はランナーのソース
(`Runner/FleetestRunnerUITests/`・`Runner/FleetestRunnerApp/`・`Runner/FleetestRunner.xcodeproj/project.xcproj`・
共有 DTO の `Sources/FTCore/BridgeDTO.swift`)が xctestrun より新しければ
build-for-testing を自動で再実行する(`BridgeLauncher.runnerNeedsRebuild`。
InAppLauncher.needsBuild と対の mtime 判定)。稼働中の旧ランナーは
`BridgeAPI.bridgeProtocolVersion` の /status 照合(xcuitest・inapp とも)で停止→立て直される。
以前は「xctestrun が在れば build を飛ばす」実装で、Runner 変更後に旧ランナーが起動し続ける罠が
あった(2026-07-26 に isChecked 追加で実害・2026-07-28 に /pressEnter 追加で再発し自動化)。
**Xcode/SDK の更新も検知する**(2026-07-29): 判定にツールチェーンの指紋
(`xcodebuild -version` + iphonesimulator SDK ビルド版。`ToolchainFingerprint`)を含め、
成果物の隣(`<DerivedData>/.toolchain`・`InAppBridge/build/.toolchain`)に記録する。
**Xcode を上げてもソースの mtime は動かない**ため、これが無いと旧 Xcode のランナー/旧 SDK の
dylib が使われ続ける(macOS・Xcode がベータのうちは頻発する)。in-app dylib
(`InAppLauncher.needsBuild`)も同じ判定。

**残る罠**: mtime 判定なので、`git checkout` 等でソースの mtime が動かない巻き戻しは検知できない。
疑わしいときは従来の手動手順が今も有効:

```
fleetest bridge down --all --platform ios
find .fleetest/DerivedData -name "*.xctestrun" -delete
fleetest bridge up --platform ios --device <名前>     # ここで再ビルドが走る
```

(Android ブリッジ側は versionCode 照合で自動再インストールされるため、この問題は iOS 側だけに出る)

**この自動化が効くのは `BridgeProvisioner` を通る経路だけ**(2026-08-06 に踏んだ)。
MCP の **profile 無しの iOS 経路**(`ft_snapshot` 等を `platform: ios` だけで呼ぶ形)は
`ExploreDriverResolver` が**生きているポートへ素で繋ぐ**ので、provision を通らず版も照合しない。

- 実害: ランナー側の修正2件を入れ、`bridgeProtocolVersion` も上げ、`swift test` も緑にした状態で
  デバイスで確認したところ、**snapshot は直る前の木を返し続けた**。原因は稼働中の旧ランナー(v52)の
  再利用で、`fleetest bridge down && fleetest bridge up` するまで「直っていない」ように見えた
- 対処は**繋ぐたびに /status の版を照合し、ズレていれば既定で拒否する**
  (`MCPServer+Driver.swift` の `enforceVersion` / `bridgeVersionSkew`。2026-08-09 に警告のみから反転)。
  古いブリッジは自分の版の挙動・注記で答え、そこから書かれたセレクタは黙って誤るため
  "Refusing to operate…" を throw して応答を信用しない。意図して古いブリッジを使うときは
  `allowVersionSkew: true` で押し通せるが、**その間は毎回の応答に警告が付く**
- **ブリッジを直したときの検証手順**: 版を上げる → `fleetest bridge down && fleetest bridge up`
  → デバイスで確かめる。**down/up を省くと必ず旧版を測る**。iOS のシミュレータはブリッジを
  起動し直すと**アプリが消えていることがある**ので、`ft_install` からやり直す

## macOS・Xcode を上げたら `--retrain-classifiers` を1回付けて回す(2026-10-07)

シナリオはサンドボックスの中で動き、書ける場所を名指しで開けている(SB-5.3)。OS の部品
(Core ML のコンパイル・Create ML の学習・Foundation の作業フォルダ)は `TMPDIR` を見ずに決まった場所へ書くので、
**OS が書く場所を変えると、その機能は赤にならず黙って別の経路へ倒れうる**。実際に、Core ML のコンパイル先を閉じた版では
分類器が全 SUT で使えなくなり、a11y で読める部品の checkIsON/OFF は緑のまま通った。

- e2e.sh は、見本はあるのに分類器を学習・読み込みできなかった run(注記 `vision-classifier-unavailable`)を赤にする。
  理由はシナリオ末尾の ⚠️ 行に分類器の言ったまま出る
- **学習の経路は見本を変えたときしか通らない**(学習済みのキャッシュがあれば読むだけ)。`Scripts/e2e.sh --retrain-classifiers`
  は各 SUT のキャッシュを消してから回す。Create ML の出力先 `T/CreateMLModels/` を閉じていたことは、これで初めて見つかった
- 赤の原因を探すときは、run の間に `log stream` で拒否を拾う(SB-9.1)

## 1回の実行が見るのは iOS の2モードのうち片方だけ

`Scripts/e2e.sh` の iOS は **既定が `ios-inapp` プロファイル**(2026-08-11 に xcuitest から反転)。
**利用者の既定モードは inapp モード(in-app ブリッジ優先)**(`RunProfile` の `iosMode ?? "inapp"`)なので、
既定スイートが見るべきは in-app 側。**XCUITest ブリッジ**(ランナー・スナップショット・型写像・
ジェスチャ申告)を触ったら **`Scripts/e2e.sh --ios-xcuitest`** を追加で回すこと。
逆に inapp モードだけを回したいときは `--ios-inapp`(既定と同じモードで iOS のみ)。

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

## 再起動直後の最初の xcuitest 供給は冷えたブートがランナーの予算に混ざる(2026-09-14)

Mac の再起動直後(シミュレータ 0 台)に `--ios-xcuitest` を回すと、8 台のランナーが**何も書かないまま**
`startupTimeoutSeconds`(180 秒)を跨いで全滅する。xcodebuild は設定を書き出した後、
テスト本体が始まるまでログに何も書かず、しかも Shutdown のシミュレータを**自分でブートしてから**始めるので、
8 台同時のブート(3 分超)がそのままランナーの予算に載る。ツール側は 3 つで受ける:
①ランナーを起動する前に `SimulatorBoot.ensureBooted`(`simctl bootstatus -b`)でブートを待ち切る(予算の外)
②冷えたシミュレータを起こす起動は in-app の注入と同じく**同時 2 台**(`BridgeProvisioner.needsLaunchSlot`。
枠は台ごと = 再利用・引き取りだけの台は枠を待たない)
③起動待ちはログの伸び・**ランナーアプリのプロセスがシミュレータに現れた**・`Test Suite started` の 3 つを進みとして
数え直す(`BridgeStartupWait`)。陽性対照は**次の再起動直後の `--cmp --ios-xcuitest`**(ログに
「booting the simulator before starting the xcuitest runner」が並び、落ちなければ効いている)。

## Mac の再起動の後、シミュレータのソフトキーボードが出なくなる(2026-09-19)

再起動の直後の `e2e.sh --ios-inapp` で、ローカル機の `keyboardIsShown` だけが決定的に赤(E2E-CMP / Flutter の 03。
リモートの3機は緑)。欄に焦点は立つがソフトキーボードが出ない = iOS がハードウェアキーボードがあると見なして
縮めている。デバイスごとに見ると `com.apple.keyboard.preferences` の `AutomaticMinimizationEnabled` が true のデバイスだけ出ず、
false のデバイス(-02)は出た。**Simulator.app 側の `ConnectHardwareKeyboard` は無関係**(シミュレータは Simulator.app
無しの画面なしで動いていた・書いても効かない)。**`com.apple.Preferences` に書いても効かない**(書く先は
`com.apple.keyboard.preferences`)。false にすると Simulator の起動し直し無しで次の焦点から出る。

**ツールが供給時に書く**(`IOSSoftwareKeyboard`。run の iOS 供給 = `ProfileWorkerFactory.buildIOSWorkers` と、ブリッジの
コールド起動 = `BridgeLauncher` の2か所・シミュレータだけ・失敗は警告して続行 = `IOSReduceMotion` と同じ形)。
陽性対照: 8台中7台が true の状態から CMP / Flutter の 03 が緑、使ったデバイスはすべて false に直った。
**実機はホストから変えられない**(実機でソフトキーボードが出ないときは端末側でハードウェアキーボードを外す)。

## 長く生きた XCUITest ランナーは AX 照会のたびに数秒待つ状態に落ちることがある(2026-09-14)

同じ 1 シナリオがデバイスによって 6 秒と 22 秒に割れたら(tap 0.5 秒 → 4 秒)、そのデバイスのランナーのログに
`Ignoring failure to get hierarchy for remote element in process <pid>` が**約 3.7 秒おき**に並んでいないかを見る。
SpringBoard の remote element(DragUI の `druid`)を引けなくなった後も参照し続け、存在確認 1 回ごとに XCTest が
remote element を諦める時間だけ待つ。隣のデバイスでは同じ行が 0.03 秒で出る = デバイスの差ではなくランナーの状態。
**`bridge down --port <N>` でランナーを起動し直せば直る**(シミュレータの再起動は要らない。druid を意図的に
再起動しても再現しないので発生条件は未特定)。ツールは再利用の入口で `GET /systemalert` を 1 問測り、
`RunnerAccessibilityHealth.slowProbeSeconds`(2 秒)以上なら起動し直す。配線の陽性対照は
`FT_FAKE_SLOW_RUNNER_PORTS=<port>`。**1 シナリオだけの実行が遅い、と見えたら先にこれを疑う** ——
2026-09-14 は単発実行が常に同じデバイス(-01)を選ぶせいで「単発実行の経路が遅い」に見えた。

**2026-09-16 の追記(2 つ)**:
- **run の途中でも再発する**。素の xcuitest レーン(シミュレータ)では、緑のシナリオの直後に**ステップの
  snapshot 所要が 2 秒以上だったときだけ**同じ 1 問で測り直し、劣化していれば同じポートで起動し直す
  (`RunnerMidRunRecheck`。inapp モード / 実機は対象外 = 理由は同ファイル)。健全な run は 1 問も払わない
- **他のセッションが使っているデバイスのランナーは起動し直さない**(2026-10-06): run-lease・MCP の印が他のプロセスに
  あれば、供給・MCP の自動回復・ライブ操作の自動起動は起動し直さずに「another session is using this device」と1行出す。
  run が自分のレーンを測り直すときだけは、MCP から引き取ったデバイスでも起動し直す(`hasForeignLeaseUnlessOwnRun`)。
  陽性対照は lease を手で書く —— **Bash ツールの zsh では `$BASHPID` が空**なので、`sleep 900 & SP=$!` の pid を書く
  (MN-70.1)
- **ランナーを起動し直しても直らない形がある**。起動し直した直後にもう 1 問測り、新しいランナーでも遅ければ
  「the slowness is not in the runner process」と 1 行出して、そのプロセスではもう起動し直さない
  (`RunnerRestartFutility`)。実測: -01 は起動し直すたびに 2.7〜3.0 秒のまま(同時刻の他のデバイスは 0.03 秒)で、
  **シミュレータの再起動で 0.03 秒に戻った**(同じ 3 シナリオの合計 42.3s → 22.1s)。この形では上の
  「シミュレータの再起動は要らない」は成り立たない。確かめ方は `curl -w '%{time_total}' 127.0.0.1:<port>/systemalert`
  をデバイスごとに数回(アイドルでも 3 秒ならデバイスの側)
- **起動し直しても 1 問にも答えないデバイス**(`/systemalert` が時限まで返らない。`ProbeOutcome.noAnswer`)は、その run では供給から離脱させ
  (run 中の測り直しならレーンを離脱させ、ワーカー復帰も止める)、次の run の供給で階段を登る: シミュレータ再起動 → 直らなければ同じ供給の中で
  初期化(erase)→ 直らなければ `wipeDidNotHelp` で終端。初期化はリースが無い・アプリが入れ直される供給のときだけ(満たさないときは
  `fleetest api wipe-device` の案内を 1 行出す)。印は `.fleetest/slow-runner-<udid>.json`。経緯は MN-98
- 陽性対照(3 通り。どれも `--device <1 台> --scenario` ×3 の素の xcuitest 実行): 劣化したデバイス・注入なし →
  起動し直し 1 回 + 上の 1 行 + 以降は無言 / 健全なデバイス・注入なし → 測り直しの行 0 件 / 健全なデバイス・注入あり →
  緑のたびに「restarted …; a one-element query now takes 0.0Xs — the lane continues」

## 入力・キー系は Compose だけで検証しない(フレームワークで経路が割れる)

Compose の入力欄は独自のキーイベント処理を持つため、**他フレームワークで死んでいる経路でも緑になる**。
実害(2026-07-28): Android の `pressEnter` はソフトキーボードが出ていると `keyevent 66` が
View/XML の `EditText` に届かない(IME が消費する)のに、CMP SUT の E2E は通っていた。
E2E-Android(View/XML)を回して初めて赤くなり、a11y の `ACTION_IME_ENTER` 経路へ作り直した
(design/ §実装で得た知見)。**入力・キー・IME 系を触ったら E2E-Android と E2E-iOS を必ず含める**。

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
**対照は「全部止めた」まで作ってから読む**(§「切り分けは『実験系が効いているか』を先に確かめる」
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

`Scripts/e2e.sh` / `e2ex.sh` / `e2e-negative.sh` / `e2e-devices.sh` は実行中だけ macOS の問題レポーター(Simulator のアプリが
落ちるたびに出る。陽性対照のクラッシュ検知が毎回落とす)を止め、終了時に元の値へ戻す(`Scripts/crash-dialog.sh`)。
`e2ex.sh --on` は向こうの機械で止める。止めても `.ips` は書かれるのでクラッシュ検知は効く(陽性対照で確認済み)。

- `DialogType` は**書くだけでは効かない** —— ReportCrash を `launchctl kickstart -k gui/$(id -u)/com.apple.ReportCrash`
  で読み直させる(戻すときも同じ)
- 同じ機械で重なっても、戻すのは最後に終わったスクリプトだけ(保持者を `~/.fleetest-crash-dialog/holders/<pid>` で数える)
- **SIGKILL で戻せずに死ぬと、次にどれかを回すまで止まったまま**。手で戻すなら:
  `defaults delete com.apple.CrashReporter DialogType && launchctl kickstart -k gui/$(id -u)/com.apple.ReportCrash && rm -rf ~/.fleetest-crash-dialog`
  (元から `DialogType` を設定していたなら `~/.fleetest-crash-dialog/original` の2行目の値を書き戻す)
