# 検証: 切り分けと実機・録画・解決済みの事例

| 種別 | 範囲 | 読む場面 | 扱わないこと |
|---|---|---|---|
| 手順 | 受け手フロー・常駐プロセス・FM 全滅・供給の失敗・全滅したときの切り分け・凍結・実機・録画・版数・解決済みの事例 | テストが全滅したとき・実機や録画を検証するとき | 毎回効く最重要ゲート(→ CLAUDE.md「ビルド・検証」) |

節の一覧はこのフォルダの README.md。

## 受け手フロー(preflight / install.sh)の検証

- **更新は `Scripts/update.sh`**(install.sh を再実行 + `project sync` + プラグイン更新と版照合)。
  clone 構成でこれを回すとき、**受け手向けの整備がクローン自身に効かないこと**を確かめる
  (実害: install.sh の `.gitignore` 追記がリポジトリを dirty にし、次の更新が pull ガードで
  止まる。現在は clone 構成では skip する。`.gitignore` の項目は `ProjectScaffold.ensureGitignore`
  と対 — 片方だけ変えない)
- **クローンを dirty にしたまま `install.sh` を試すと必ず止まる**(ローカル変更の破棄を尋ね、
  端末が無い実行では中止する仕様)。本体を触りながら試すときは **`--no-pull`** を付ける
- 実行の記録は `<WORK_DIR>/.fleetest/install-<日時>.log`(実行ごとに別ファイル)。
  端末出力を追わずに後から失敗を追える
- **スキルが渡す新しい引数は、受け手のクローンが pull されるまで存在しない**。
  スキルからは**スキルと一緒に届いた Scripts/**(手順書と同じ版。プラグインのキャッシュ)の
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
数千段になっていれば、XCUI の操作失敗を起点にしたツールチェーン不具合(design/
「XCUITest ランナーは『操作の失敗』でプロセスごと落ちる」)。

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
SwiftUI・RN は描ける(docs/design/「描画崩壊の検査」・MN-90)。

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

## Android 凍結まわりの検証の罠

- **画面 OFF(KEYCODE_SLEEP)はフェイク凍結として万能ではない**: screencap は実凍結と同一の
  一様フレーム(<30KB)になるため **blank 検出・事前修復パスの検証には使える**(検出→sleep/wake
  修復→回復、が決定論的に再現する)。しかし **a11y 駆動(tap/type/textIs)は画面 OFF でも全て通る**
  (実測: シナリオ実行中に画面 OFF にしても 18/18 成功)ため、「シナリオ失敗→凍結判定→修復」の
  実行中経路は発火させられない。さらにシナリオの launch が画面を起こす過渡で別種の失敗が出る
  (注入アーティファクト。実凍結の症状ではない)。実行中修復パスの実発火はフェイクで強制できず、
  本番ログの「実行中の画面凍結を修復」で観測する
- **実凍結は事前修復が先に治すため「実行中だけ凍結」を意図的に作れない**(実凍結の誘発は
  8台並列 run の反復のみ。1台単独負荷・アイドルでは発生しない。PT-7)
- **凍結のホスト側証跡は `~/Library/Logs/fleetest/emulator/<AVD>.log`**(DeviceBooter が
  emulator stdout/stderr を保存。ブート毎 truncate)。根因の Metal エラー
  (`GLDRendererMetal command buffer completion error` / `IOGPUCommandQueueErrorDomain 518`)は
  ここにしか出ない(2026-07-25 実測)。凍結個体を調べるときはまずこのログを見る
- **エミュレータ操作は既定で emulator gRPC(EmulatorController)経由**(スクショ/キー・タッチ注入/
  停止等。実機・gRPC 失敗個体は自動で adb フォールバック。`Sources/FTAndroid/EmulatorControl.swift`)。
  gRPC 起因を疑うときは **`FT_EMULATOR_CONTROL=adb`** で全面 adb に切り替えて比較できる
  (gRPC を話すのは Swift だけ。拡張の凍結修復も `fleetest api repair-display` 経由でここを通るため、
  この環境変数1つで両方効く)。挙動差の切り分けはまずこれ。
  **iOS も同様に CoreSimulator 直叩きが既定**(DS-16.4)で、
  **`FT_SIMULATOR_CONTROL=simctl`** が殺しスイッチ。対象は**列挙だけでなく
  アプリ起動と未インストール検査も**(2026-08-02 拡張)なので、
  「launch がおかしい」ときもこれ1つで simctl 経路と比較できる
- **run が遅くなったら負荷トリアージを先に**: ① `top` で qemu の空転(劣化個体はアイドルでも
  ~73%/デバイス消費しホスト全体を遅くする)② run 同梱の `host-metrics.ndjson`(遅い run だけ CPU 飽和
  していれば環境要因)。Spotlight/mediaanalysisd のインデックスストームは CPU 数百%でも run を
  ほぼ遅くしない(M2 Ultra 実測)ので容疑から外してよい
- **guest reboot の完了判定は「1 でなくなる」→「1 になる」の2段で見る**: `adb reboot` 直後は
  まだ旧セッションが `sys.boot_completed=1` を返すため、いきなりブート待ちに入ると即成功して
  再判定が**凍結したままの旧画面**に当たる(run 前トリアージの実装 `ProfileWorkerFactory.rebootGuest`)。
  また再起動中は screencap 自体が失敗し、blank プローブは安全側の「非 blank」に倒れるので、
  **ブート完了を確認できない個体を blank 再判定に掛けてはいけない**(復帰と誤認する)
- **CPU 描画(swiftshader)フォールバックは emulator プロセスを再起動しないと戻らない**
  (`-gpu` は起動引数固定。ゲスト再起動・gRPC RESET では戻らない)。戻す経路はモニターの
  「GPUで再起動」「デバイスを全て起動」と、実行プロファイルの `recoverCpuFallbackToGpu`
  (DS-11)。**例外**: Wipe Data の再ブートは `startEmulator` の既定 `-gpu host` で
  起き上がるため、しきい値超過の個体は副作用で GPU に戻る(意図した復帰機能ではない)
- **凍結調査は両経路スイープで**(`adb screencap` サイズと gRPC スクショの画素一様判定を並記)。
  readback 白化と host キャプチャ黒は独立に壊れるため片経路だけでは誤診する。シナリオ成功率は
  表示層の劣化を映さない(凍結9/14台でも 18/18 成功する)。変種一覧・スケール上限・Metal エラー
  指標の正本は PT-7

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

- 実行プロファイルのデバイス編集フォーム(`updateDeviceInMachineProfile`)は実機で表示が変わる:
  iOS は機種/OS 行を隠し **udid** を、Android は AVD 行の代わりに **serial** を readonly 表示する
  (いずれも実体を指すので変更不可)。実機で識別子を空にした保存は拒否する
- デバイスタイルは実機に「実機」バッジを出す。右クリックの起動/停止は**項目を残したまま
  ラベルを「ブリッジを起動/停止」に変える**(実機は端末そのものを起動・停止せず、操作対象は
  ブリッジだけ)。**項目を隠してはいけない**: 隠すとモニターから実機のブリッジを起動できず、
  タイルが「接続中」のまま何もできなくなる(2026-07-25 に実際にそうしてしまった)
- `kind`/`serial` は拡張側の 2 箇所(`config.ts` の `MachineDeviceEntry` と `monitorModel.ts` の
  同名型)に独立定義がある。**両方直すこと**(vscode 非依存を保つための意図的な重複)
- webview→拡張の `machineDeviceUpdate.fields` に `serial` を足した。**拡張と webview のバンドルは
  別々に更新されうる**ので、受信側は欠落を "" に補う(旧 webview と混ぜても壊さない)
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

## 常駐ブリッジのセッション(iOS xcuitest を CLI で直接叩くとき)

`bridge up` で立てた常駐ランナーへ curl 等で直接 `/snapshot`・`/tap` すると、最初の1回が
`409`(セッション無し)で返ることがある。ランナーはアプリ参照(`sessionBundleID`)を `/session`
で初めて確立するため。**先に `POST /session` を投げる**こと(Runner/FleetestRunnerUITests/BridgeRouter.swift)。

- `simctl launch` で既に起動済みのアプリへ後付けで繋ぐ場合は `{"bundleID":"...","attachOnly":true}`。
  attachOnly は activate/launch せず前面到達だけ確認する(前面に無ければ即エラー)。通常 run は
  driver が自動で `/session` を張るのでこの手順は不要=CLI 直叩き時だけの話。
- **`/status` の `sessionBundleID` は次の `/session` まで残る in-memory 値**。対象アプリを
  アンインストールしても消えないため、削除済みアプリの死んだ参照が見えることがある(無害。
  次の `/session` で上書きされる)。`/status` の session 欄=「今アタッチ可能」の保証ではない。

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

## 未インストールのアプリを launch するとランナーが死ぬ(2026-08-06)

外部フィードバック #7「Safari 操作後にブリッジが切断」は **Safari と無関係**だった。
報告元のログで確定した経過:

1. ポート 8123 のランナーで未インストールの `com.example.myapp` を launch → `TEST EXECUTE FAILED`
   でランナー終了(04:47:34)。この時点で 8123 は死亡
2. 以後 `port` を指定しなかった呼び出しは、**既定 8123 決め打ち**(当時)で死んだポートを叩き続け、
   `Connection refused` になった。Safari を操作していた 8124 は別デバイスで、切断時も生きていた
   (ログは t=187s まで継続)

「ツールごとにポート解決経路が違うのでは」という推測は否定された ——
`ft_snapshot` も `ft_screenshot` も同じ `driver(_:)`・同じキャッシュ鍵(`driverCacheKey` は
port を含む)を通る。**port を書いた呼び出しと書かなかった呼び出しが混在していた**のが実態。

**ランナー死は直接再現できる**(遊休ブリッジ1本を潰すので、使っていないポートで):

```
curl -s -X POST http://127.0.0.1:<port>/session -d '{"bundleID":"com.example.nonexistent"}'
```

無応答(**待受は継続**)が約5秒 → 10秒以内にランナーのプロセスが消え、待受も消える。
原因は `XCUIApplication.launch()` の失敗 issue が main queue 上で記録されること(`requireLiveApp`
のコメントにある無限再帰と同じ経路)。対処も同じで、**XCUI に触れる前にホスト側で弾く**
(`MCPServer.installedVerdict`(判定そのものは `InstalledAppCheck.launchGuard`))。

**この実験は「応答しないが生きている」状態の witness でもある** —— 上の約5秒間、`/status` は
返らないのにポートは待受している。ブリッジ探索が「応答なし=死」と読むと、この隙に
**別デバイスのブリッジへ黙って乗り換える**。`BridgeDiscovery.isBound`(TCP 接続可否)で
死と忙しいを分けること。外部ログでは整定待ちで **33.7 秒**ブロックした区間が観測されている。

## 横カルーセルの戻しが数十 px 足りず flake していた(2026-08-30・**解決** — scrollToLeftEdge)

5 SUT の `フリックが正しく動くこと.S0010` が、`flickRightToLeft` → `scrollLeft(scrollFrame:, repeat: 3)` →
`exist "#tag_01"` で落ちていた(E2E-iOS ios-inapp で 25/108 = 23%。既存メモでは「FM の死が引き金」
と読んでいたが、それは負荷状態の交絡だった)。

**決め手はホスト側プローブ**(各 scrollLeft 後の `tag_0x` の x を記録)。**通った run でも
戻り切っていなかった**:

| | scrollLeft 1回 | 3回の合計 | 慣性距離 | 先頭タグの位置 | exist |
|---|---|---|---|---|---|
| 通った run | 221px | 663px | ≈ 700px | 38px 画面外(82px 見える) | 木に載る → ✅ |
| 落ちた run | 221px | 663px | ≈ 770px | 85px 画面外(17/19 で一定) | 木から落ちる → ❌ |

合否を分けていたのは**数十 px の慣性のばらつき**で、シナリオの「距離に依存させない戻し」という
前提が誤りだった(scrollLeft×N は距離依存)。**修正はシナリオ側** —— 戻しを距離非依存の
`scrollToLeftEdge(scrollFrame:)` に(5 SUT の 10 箇所。ユーザー決定。ツール側で刻み幅を
60%→85% に上げる案は「依然として距離依存で、全 scrollFrame スクロールの挙動が変わる」ため不採用)。
検証: 5 SUT の単発 7/7 緑 + E2E-iOS スイート 25周で **0/25**(修正前 23%)。

**教訓**: 「部分可視で木に載る/落ちる」境界の上に立っていた検証は、緑でも安定していない。
scrollLeft/Right の repeat で「端へ戻す」つもりの書き方は他にもある(`05_スクロール.swift` の
repeat 2/3。こちらは失敗履歴なし・意図未確認)。

## interop WebView のタップが吸われる(2026-08-30・**解決** — 直前の接続確認)

`E2E-CMP` × iOS × inapp モードの `WebViewの中身を操作できること.S0010` が、
**interop タップ**で約 13% 落ちていた(素の tap 通算 11/83)。多くは scene 2 の最初のタップ:

```
❌ 11. [expectation] textIs "wv_result=*" == "wv_result=link"
   expected "wv_result=link", actual "wv_result=-"
   (the preceding tap ... did not change the screen at all)
```

**再現条件は `Scripts/e2e.sh --cmp --ios` のフル1周だけ**(1周 = 1標本・約2分)。
**`--broadcast` で1シナリオを全台へ配る形では再現しない(0/120)** —— 10レーンが同じ軽い
シナリオを流すだけでは、実スイートの「各レーンが別々の34シナリオを回す」混雑が作れない。
効率は10倍(1周10標本)だが**測っている現象が別物になる**。

### ホスト層は無実(計測で確定)

`WebViewDelegatingDriver` に計測を入れて25周回し、失敗3件と成功周を突き合わせた:

| | 失敗周 | 成功周 |
|---|---|---|
| snapshot | `webViewPath=dom-interop mode=domInterop webElems=13` | **同一** |
| tap | `via=delegated point=(77.25738525390625,266.734375)` | **同一** |
| タップ後 | 次の snapshot まで 434ms・要素 13 のまま | 754ms・13→8 |

**1bit も違わない同じ命令を出して、24% の回だけページに届かない**。差はタップ後にしか出ない。
したがって DSL / StepExecutor / WebViewDelegatingDriver / in-app ブリッジは原因ではなく、
消えているのは **XCTest の合成タッチ → Compose interop → WebKit** の間。

**ステップ所要の分離は症状であって原因ではない**(失敗 443〜519ms / 成功 729〜1313ms)。
画面が変われば整定待ちのポーリングが入り、変わらなければ即返るというだけ。
**この分離を手掛かりに原因を探さないこと**。

### 否定済みの仮説(再調査しない)

| 仮説 | 否定した根拠 |
|---|---|
| `InAppWebViewDOM.capture` が nil を返し木が空になる | `dom-unread` の注記が全実行で発火 0 |
| XCUITest 側の WebView a11y 活性化待ちが足りない | `hasWebContent` を待つ実装に変えても scene1 の所要が伸びず **no-op**(post 9194ms vs pre 10505ms)。そもそも scene 1 に約9秒使っており活性化(約2.3秒)は完了している |
| アイドル後の「冷え」 | 120秒アイドルを毎周置いて **0/30** |
| `XCUICoordinate.tap()` の DOWN/UP が同一瞬間に潰れている | `press(forDuration: 0.05)` に替えて **2/25**(ベースライン 9/62 と Fisher p≈0.51 で差なし) |
| `FastInput` の quiescence スキップ | `iosFastInput` は既定 false・プロファイル指定も無い = **元から素通し**。実験する前にコードで否定 |

### 測定の教訓(この件で実際に払った)

- **長い実行の前に計測器が鳴ることを単発で確かめる** —— stderr が捕まらない計測のまま12周
  (約25分)回して情報ゼロ。出力先をファイルにして解決した
- **実行中の E2E を中断しない** —— 中断すると次の周のデバイス状態が汚れる。汚れた1周目の
  3/10 を陽性対照と誤認し、A/B の判定を1回無効にした
- **変更が本当にその経路を通るかを、既存テストが落ちることで確かめる** —— press 化では
  `testDomInteropReadsFromPrimaryAndTapsByCoordinate` が落ちたので経路が確認できた。
  接続確認修正ではこれをやらず、no-op を50分測った

### 決着(2026-08-30)

**原因**: attach したままの XCUITest セッションは、**ランナーに問い合わせないまま置いた直後の
座標イベントを、200 を返しつつ届け損なう**。domInterop は読みを in-app(3ms)で済ませるため
ランナーが数秒沈黙し、そこへ最初のタップを撃っていた。これで全証拠が繋がる —— ページは
pointerdown すら見ない(JS プローブ)・inapp モード限定(xcuitest モードは毎ステップ ランナーが
働く)・委譲モードでは出ない(同上)・「最初のタップ」に偏るがギャップ約1秒の後段でも数%落ちる。
既存コメントの前科「attach 直後の最初の座標タップが 200 でも不発(CMP で再現)」の残りだった
(mode 入場時の接続確認1回では、その後の沈黙で冷え直す)。機構(testmanagerd の何が冷えるのか)は
非公開で特定できていない —— 修正は観測に立脚した防御。

**切り分けの決め手**(各25周):

| arm | 変えたもの | 結果 |
|---|---|---|
| ベースライン | — | 6/25(以降の素 tap arm 通算 11/83 = 13.3%) |
| `FT_WEBVIEW_DOM=off` | DOM 経路を殺す(委譲モードへ) | **0/25** |
| 実験W | DOM 読みはそのまま・タップ直前に `delegated.snapshot()` | **0/25** |
| 本修正(最終確認) | 全委譲イベント直前の接続確認 + プローブ無し SUT | **0/25** |

両介入の共通項は「タップ直前にランナーの経路が使われていること」だけ = 因果が閉じる。
接続確認あり通算 **0/50** vs なし 11/83(p ≈ 0.0008)。

**修正**: `WebViewDelegatingDriver.pingDelegatedBeforeEvent` —— domInterop の委譲イベント
(tap / press / type の focus タップ / clearInput)直前にランナーへ木を1回読ませる。
実行プロファイル `iosPreActionPing`(既定 true)で止められる(docs/design/ §プロファイル)。
**時間閾値にしない**(短いギャップでも確率的に落ち、安全な境界を引けない)。
コスト実測: 該当画面のイベント1回 +約0.4s・当該シナリオ +3.0s(16.1→19.1s)・
**スイート全体は差なし**(88.9s vs 90.0s。10レーン並列に隠れる)。

### 手つかずの隣接品

`domInteropPoint` は **DOM 矩形の素の中心**を返すが、DOM 側の可視判定 JS は
**見えている部分の中心**で `elementFromPoint` を撃つ(`WebViewDOMSnapshot.swift` の `hittable`)。
**判定と実射で基準がずれている**。今回の失敗は対象が画面内に完全に収まっており座標も一致して
いたので**この件の原因ではない**が、部分的に隠れた要素では実害が出うる。
