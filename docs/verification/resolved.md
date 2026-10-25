# 検証: 解決済みの事例

| 種別 | 範囲 | 読む場面 | 扱わないこと |
|---|---|---|---|
| 記録 | 直した不具合・製品が吸収した制約の調べ方と原因 | 同じ型の症状を調べるとき・直し方の根拠を確かめるとき | 現在の検証の手順(→ このフォルダの他のファイル) |

現在の仕様ではない。日付はその時点のもの。直した結果として残る規律は、各手順のファイルと design に置く。

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

## スクロールした直後のタップ(2026-07-27 修正済み)

スクロール探索(`scrollTo` / `tap(scroll:)`)の直後は、そのまま操作しても**別の要素を掴む(Android)**
**まったく効かない(iOS)**。`StepExecutor` の探索終端で2つの処置を**この順で**行って解消した。
利用者側の書き方は変わらない(回避策を覚える必要はない)。

1. **空打ちの極小ドラッグ(iOS のみ)**: Compose のスクロール容器は次の1タッチを消費してしまい、
   タップもプレスも効かない。クリックにならない 2pt ドラッグでその1回を肩代わりする
2. **静止待ち**: frame が連続2回同じになるまで待つ(最大 600ms・スワイプした周回だけ)

**`/tap` が古い ref の座標を撃っている率は `FT_STALE_TAP_PROBE=1` で測る**(保守者の測定スイッチ。XCUITest ランナーの ref の
`/tap` が撃つ直前に木を撮り直し、要素がもう控えた枠に居なかった回に注記 `stale-ref-at-tap`。断らずに撃つので判定は変わらず、
タップ1回ごとに撮り直しの費用(簡単な画面で実測 +21ms)を払い、撃つのもその分遅れる = 性能の測定と同時にしない。シナリオの子へ届くのは
`FT_` 接頭辞が子の環境の許可リスト(`ScenarioSandbox.inheritedEnvironmentPrefixes`)を通るからで、`e2ex.sh --on` の ssh の先へは
届かないので、ランナー機で直接 `FT_STALE_TAP_PROBE=1 Scripts/e2ex.sh …` と起こす)。

**空打ちが今も要るかは `FT_EMPTY_DRAG=off` で測る**(保守者の殺しスイッチ。2026-09-12 の計測:
止めて E2E-CMP / ios-xcuitest を3回回すと `S0080`(`selected=-`・注記 swallowed)と横向きの `S0020` が
3/3 で赤、E2E-Flutter は 2 回中 1 回 `S0080` が赤。単発の MCP witness(`scrollTo '#row_40'` → tap)では
吸われないので、**空打ちの要否は E2E の規模で判定する**)。

**木の形・型の名前からフレームワークを推定してはいけない**(同日の計測): Compose の XCUITest の木は「画面全体の
scrollView + 内側のリストは scroll 印の無い `other`」だが、実アプリのコーパス(iOS 22 画面)の
**10 画面(Safari の 7 画面・設定・写真・地図の経路)が同じ形**で、Flutter は容器が本物の scrollView
= UIKit と同じ形なのに空打ちが要る。型の名前も RN が Compose / Flutter と同じ顔ぶれ。誤検知は「行を押す」側に倒れる。
**使えるのは要素のクラス名だけ**(XCTest の非公開属性 5004 → `ElementInfo.axClass`。Compose / Flutter の要素は
`UIAccessibilityElement`、RN は `UIView`、SwiftUI は `NSObject`)—— 材料(.app/.ipa)と台帳の後の第3段として
掴んだ要素単位で使う(`AccessibilityClassHint`)。固定コーパス `Tests/Fixtures/AXClass/` が各フレームワークの値を
等号で固定する(Xcode の版で属性が変わったら落ちる = そのときは取れない側へ縮退する設計を確かめ直す)。

**iOS の空打ちを Android でやってはいけない**: Android では 2pt ドラッグが**クリックとして発火**し、
タップしていないのに行が選択される(= 二重実行)。`releasesScrollTouch` が唯一の分岐理由。

**空打ちは「対象が覆われていないとき」だけ打つ**(2026-07-27)。覆われている点を触ると
**覆っている側が反応する**。実害: E2E-iOS の `#txt_offscreen` はスクロール後に
**タブバーの帯(y 778〜840)の中**へ出るため、空打ちがタブバーに届いてホームタブへ切り替わり、
直後の `exist` が「要素が見つかりません」で **5/5 失敗**した(11:19 の空打ち導入から
E2E-iOS を回すまで気付かなかった)。**距離を伸ばしても・画面端から離しても直らない**
(ドライバの press→release はタップとして届く)。判定は
`StepExecutor.pointIsTakenByFrontElement`(**触る1点**が手前の別要素に入るか。
面積比の `OcclusionSuspicion.covering` では部分的な重なりを取りこぼし、並列実行の
フル E2E でだけ再発した)。

切り分けの記録(同じ実験を繰り返さないために):

| 試したこと | iOS の結果 | 分かること |
|---|---|---|
| `scrollTo` → `tap`(中間行) | ❌ `selected=-` | 現象 |
| `scrollTo` → `wait(2)` → `tap` | ❌ | **時間では解けない**(慣性・アニメーション待ちではない) |
| `scrollTo` → `tap` → `tap` | ✅ | **2回目は届く** = 1タッチが消費されている |
| `scrollTo` → `press` | ❌ | 別ジェスチャでも同じ |
| `scrollTo` → **固定ヘッダ**を `tap` | ✅ | タッチは配送されている。スクロール容器の中だけの問題 |
| **ios-inapp-boost** プロファイル | ✅ 全て | in-app(ref)経路は無傷 = 座標の精度の問題ではない |
| ランナーで **XCUITest クエリ解決**して `element.tap()` | ❌ | **不採用**。届け方を変えても効かない |
| ランナーの整定待ちを 0.35→1.2s | ❌(揺れる) | **不採用**。1回の緑は雑音だった(なお 2026-07-30 にこの固定待ち自体を収束判定へ置換した。PT-3.8) |
| 「画面に収まるまで追加スワイプ」 | ❌ | **不採用**。frame は画面中央に完全表示でクランプではない |

- **既知の残: Android の `#row_25` 付近が確率的に落ちる**(`ロケータを解決できません` /
  スクロール探索自体の失敗)。**変更前から同じ**(ベースライン 3 回中 2 回で再現)なので本件とは別問題。
  フリング中に対象行がリサイクルされて消えるのが疑わしい

## 横カルーセルの戻しが数十 px 足りず flake していた(2026-08-30・**解決** — scrollToLeftEdge)

5 SUT の `フリックが正しく動くこと.S0010` が、`flickRightToLeft` → `scrollLeft(scrollFrame:, repeat: 3)` →
`exist "#tag_01"` で落ちていた(E2E-iOS ios-inapp-boost で 25/108 = 23%。既存メモでは「FM の死が引き金」
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

`E2E-CMP` × iOS × inapp-boost モードの `WebViewの中身を操作できること.S0010` が、
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
pointerdown すら見ない(JS プローブ)・inapp-boost モード限定(xcuitest モードは毎ステップ ランナーが
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
実行プロファイル `iosPreActionPing`(既定 true)で止められる(docs/design/profiles.md「プロファイル」)。
**時間閾値にしない**(短いギャップでも確率的に落ち、安全な境界を引けない)。
コスト実測: 該当画面のイベント1回 +約0.4s・当該シナリオ +3.0s(16.1→19.1s)・
**スイート全体は差なし**(88.9s vs 90.0s。10レーン並列に隠れる)。

### 手つかずの隣接品

`domInteropPoint` は **DOM 矩形の素の中心**を返すが、DOM 側の可視判定 JS は
**見えている部分の中心**で `elementFromPoint` を撃つ(`WebViewDOMSnapshot.swift` の `hittable`)。
**判定と実射で基準がずれている**。今回の失敗は対象が画面内に完全に収まっており座標も一致して
いたので**この件の原因ではない**が、部分的に隠れた要素では実害が出うる。
