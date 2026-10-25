# 設計: 背景・全体構成・FM 呼び出し・CLI

| 種別 | 範囲 | 読む場面 | 扱わないこと |
|---|---|---|---|
| 正典 | 方針・全体アーキテクチャ・リポジトリ構成・FM 呼び出し層・CLI UX・E2E の検証方法(DS-1〜3・5・6・9) | 全体の構成や方針を変える前 | ブリッジ(→ [bridge.md](bridge.md))・DSL(→ [dsl-syntax.md](dsl-syntax.md)) |

Foundation Models framework(オンデバイス 3B モデル。macOS 26+、視覚検証は 27+)を最大限活用する、
iOS / Android 両対応のアプリ E2E テストツール。iOS を先行実装し、Android は同じ
`AppDriver` 抽象の上に後続実装した(経緯・時系列は DS-7, DS-8 参照)。

- ステータス: iOS / Android とも実装済み・運用中(GUI 入口は VSCode 拡張に一本化)
- 決定事項: ハイブリッド型 / 自作 XCUITest ブリッジ+自作 Android ブリッジ / シミュレータ優先 / Swift + FoundationModels

---

## DS-1 背景と方針

### DS-1.1 Foundation Models framework(macOS 26+ / 画像入力は macOS 27 = WWDC 2026)の前提

| 機能 | 内容 | 本ツールでの用途 |
|---|---|---|
| 新オンデバイスモデル (AFM 3) | ロジック・tool calling が大幅改善、Vision(画像入力)対応 | エージェントの頭脳 |
| Guided Generation (`@Generable`) | constrained decoding による型安全な構造化出力。パース失敗が原理的に起きない | 全ての LLM 出力(修復案、レポート) |
| Tool calling (`Tool` プロトコル) | 並列/直列の呼び出しグラフを framework が自動処理 | 画面詳細のオンデマンド取得など補助的に使用 |
| マルチモーダル | 画像+テキスト入力(NSImage/CGImage/CVPixelBuffer/URL) | スクリーンショットの視覚検証 |
| Dynamic Profiles | セッション中にモデル・ツール・instructions を切替 | verifier の役割切替 |
| `LanguageModel` プロトコル | オンデバイス / PCC(32K ctx) / Claude / Gemini / MLX を同一 Session API で差替 | **使わない**。PCC は完全に禁止(下記)、外部 LLM も同様 |
| 制約: コンテキスト ~4K トークン級 | TN3193 参照。プロンプト+応答で共有 | **設計全体を規定する最重要制約** |
| 制約: ホスト全体で共有される資源 | 許可枠(既定1、環境変数で上書き可)で制限される。並列度が枠を超えるとレイテンシが伸びる(PT-3.5) | 並列実行では FM 呼び出し数と枠が実行時間の下限に効く(PT-3.5) |

**可否判定の罠**: `SystemLanguageModel.default.availability` は「端末が対応しているか」しか見ておらず、
モデル資産側の理由で**全呼び出しが失敗していても `.available` を返す**(専用ケース
`.appleIntelligenceNotEnabled` があるのに返さない。2026-07-22 実測)。可否を人へ報告する場所では
実際に1回推論する `FMDoctor.checkLive()` を使う(`fleetest doctor` / MCP の `ft_doctor` が採用)。
同期の `FMDoctor.check()` はホットパス用で**可否を保証しない**。

**FM 失敗は握りつぶされる**: occlusion-guard・screenLooksLike はいずれも FM 失敗時に nil を返して
素通りする契約なので、FM が全滅してもテストは緑のまま**機能だけ無効**になる(自己修復は
2026-09-15 に指紋照合のみとなり FM を呼ばないため、この契約の対象から外れた → MN-22)。
**ただし黙らない**(2026-08-23): occlusion-guard(`exist` の既定 `requireVisible`)は **FM に訊いたのに
判定が返らなかったステップ**に `StepNote.visibilityGuardSkipped`(`visibility-guard-skipped`)を立て、
結果 JSON の `notes` から run 横断で数えられる(立てるのは FM まで到達した回だけ。マスタースイッチ OFF・
macOS 26・インクゲートで省いた回は「訊く必要が無かった」)。同時に **requireVisible は2段**になった:
Tier-0 幾何 = 収まる軸の中心が画面外なら不可視(`TapTargetGeometry.offscreenScrollGateCentre`。
スクロール探索の「見つかった」ゲート・逆走査 `reverseSweep`・MCP の `ft_scroll_to` 再照合と同じ述語で、
**文言は呼び手ごと**)→ Tier-1〜 FM。iOS の木は画面外の要素も frame ごと残し、FM 側は crop が
画像の外に落ちると nil(素通り)なので、**通り過ぎた要素への exist は FM が生きていても FM では
塞がらなかった**(2026-08-20 受け手報告・横スクロール区画)。幾何の段は FM の有無に依らず
`fmTextVisibilityCheck || ocrTextVisibilityCheck` の下で効く(`StepExecutor.visibilityGuardActive` が唯一の入口。FTRuntime の
保持値の高速経路もこれを見る)。
**Tier-2 は Vision OCR**(2026-09-07): インク足切りを通って「FM に訊く」と決まった crop に、まず
`FTCore.RegionText` が OCR を当て、**期待文字列が丸ごと読めたら可視として素通り**させる
(FM を呼ばない)。crop 矩形は `FTCore.OcclusionCrop` を FM と共有するので、両者は同じ画素を見る。
実 run で FM の段に届いた crop 163 枚のうち **97% がここで片付き**、FM に回ったのは本当に
描かれていない 2 枚だけだった(p50 92ms。FM は 1.3〜2.8s)。守る規律は4つ:
**①丸ごと読めなかったことだけを反転の根拠にしない**(日本語モデルを載せた版では可視な
テキストの 29% を 1 文字誤読した)。FM の段(`fmTextVisibilityCheck`)が使えるときは丸ごと読めなかった回を**全部** FM に回し、
`OCROnlyVisibility.merge` で**見えていると読めた側を採る**(赤は両方が見えないと言った回だけ。割れた回は注記
`ocr-read-what-fm-missed` / `fm-read-what-ocr-missed`。OG-5.22)。FM の段が無い・使えないときは
`OCROnlyVisibility` の判定だけで赤にする/ **②一致は完全含有だけ**(先頭一致を許すと、部分的に覆われて
残りだけ読めた回を通してしまい誤った緑になる)/ **③読ませる言語は期待文字列から決め、言語補正は日本語の集合でだけ掛ける**
(`RegionText.languages(for:)` / `usesLanguageCorrection(for:)`。ASCII の期待値に日本語モデルを載せると
所要が 2.3 倍。en ロケールの端末は「単」を中国語フォントの字形で描き、補正なしだと「单」と読む。
2026-09-15)/
**④読めなければ拡大して読み直す**(`upscaleLadder = [1,2,3]`。×4 で悪化するので上げ続けない。
**1行も読めない crop は段を上げない** = 覆いが消えるのを待つ poll 周回で毎周 3 回払わない)。
版(revision)は固定せず OS の既定に従い、**版・認識レベル・言語補正・言語規則が動いたことの検出は
実 crop の固定コーパス**(`Tests/Fixtures/OcclusionCrops/`)が担う。既定 on・殺しスイッチは
`FT_OCCLUSION_OCR=0`・`measure` でコーパス採取(実測は OG-5.17)。
**①の例外は FM が判定を返さないときだけ**(2026-09-26。macOS 26・実呼び出しの失敗):
近道が読んだ行を `TranscriptMatch.judge` に通し、行が無ければインク量で分ける(`FTCore.OCROnlyVisibility`)。
不可視なら FM の反転と同じく赤(警告の段階でコーパス・E2E の誤った赤 0 を確かめてから上げた。
実測はOG-5.19)。
**先頭だけ描かれた形**は `TranscriptMatch` が FM と OCR で共通に分ける: 省略記号 → 緑(`text-ellipsized`)/
割合 > 0.5 → 緑(`text-partially-hidden`)/ 以下 → 赤(ユーザー決定)。

**FM 段は転写 + ホスト照合**(2026-09-15): OCR で読めなかった crop に FM が答えるが、**FM に期待文字列は
渡さない**。訊くのは「何が描かれているか」(転写 1 欄・prompt は定数)だけで、可否は `FTCore.TranscriptMatch`
が期待文字列と突き合わせて決める(含む / 先頭 2 文字以上の切り詰め / 5 文字以上なら len÷5 の誤読・先頭文字
必須 / 末尾だけ = covered / 空 = notRendered / 無関係 = textMismatch)。等倍で読めなければ 2 倍で読み直し、
転写が 1 文字差で惜しいときだけ OCR に丸ごと読めたかを確かめる(素通りの向きだけ)。期待文字列を渡して
「見えるか」を訊く旧形は、空白・別の文字の crop でも期待文字列を写して visible=true と答えていた
(おうむ返し。OG-5.18・MN-19)。

**近道が本道より高くつかないための3つの門と、コンパイルの置き場**(2026-09-10。経緯は
MN-18): ①**モデルが載って実際に読めるまで近道は撃たない**
(`RegionText.isModelReady`。コンパイルの探りが 1 行以上読めた回だけ ready。Vision が `[]` を返し続ける日がある)/
②**諦めた読みが走っている間は撃たない**(`abandonedInFlight`。積み増すと 12 本が全部予算切れになり
戻った瞬間に協調スレッドプールが止まる)/ ③**予算 1.3 秒 = 置き換える相手(FM 照合)の実測下限**
(`RegionText.occlusionBudget`。尽きたら FM へ落ち注記 `ocr-budget-exhausted`。**諦めても読みは止めない**
= そのままコンパイルとして効く。合流点は `TaskBudget`)。判定は3つとも変えない(読めなかったのと同じ扱い)。
コンパイルの実体は Espresso(認識器)の **AOT コンパイル**で、キャッシュは
`~/Library/Caches/<プロセス名>/com.apple.e5rt.e5bundlecache` に**プロセス名と署名 ID で**鍵付けされ(SwiftPM の Debug ビルドは
ID に LC_UUID が入るので、`ScenarioHost.build` が ID を製品名に揃える。PT-3.33)、
**コンパイル(コールド 20〜45 秒 × 言語集合 2)がそのプロセスの生存中に終わったときだけコミット**される。
1 シナリオ = 1 プロセスの実行バイナリは終わる前に死んで `.tmp` を残すだけなので、
**run の開始時に同じプロセス名の待てる子 `fleetest-scenarios-<project> compile-ocr` を背景で 1 本起こす**
(`ScenarioHost.listForRun`。**その run で OCR の段か FM のテキストの可視性検証が有効なときだけ** = `ScenarioHost.ocrCompileNeeded`
(プロファイル・`--set` で両方を切った run では起こさない。機械分担の親は起こさず機械ごとの run が決める)。dry-run / MCP / codegen の一覧取得 `list` では起こさない・機械で同時に 1 本
= `OCRModelCompileLock`・**親の死を生き延びる** = `FT_PARENT_PID` を渡さない唯一の例外)。シナリオ側の探りは
同じロックを**待ってから**読む(8 レーンが同じモデルを同時に焼かない)。認識器は **ANE を避けて CPU/GPU**
に載せる(定常の所要は同じ 100〜160ms。判定の近道を FM フラップと同じ部品に依存させない。装置で読みが
変わる 1 行はコーパスに固定)。実測: シナリオ側のコンパイル 22,980ms → 218ms、実 crop の初回読み 21,830ms → 98〜122ms。

**launch 直後の未描画画面は「覆い」と見分けられない**(2026-09-03): `restartApp` / `launchApp` は
木が引けた時点で戻るので、a11y の木は新インスタンスの要素を返しているのに画面はまだ
launch storyboard(全画素同一)ということが起きる。負荷の高いランナーでは描画が既定の待ち窓に
間に合わず、occlusion-guard が**正しく**「見えていない」と言って赤になる(実測: crop 265x100 が
全画素 (255,255,255))。そこで launch 系コマンドの直後だけ `StepExecutor.firstFrameGatePending` を
一度きり立て、**最初に FM の可視性判定が返った回**で消費する(可視でも消費 = 描画済みなら猶予は
要らない)。不可視かつ crop の `RegionInk.luminanceStdDev` が **`StepExecutor.firstFrameBlankStdDevCeiling`
(= 1.0。8-bit 輝度の量子化1段階未満 = ディザ・圧縮の揺らぎしか無く構造が無い、の定義であって
調整値ではない)未満**なら、そのステップの deadline を
**一度だけ**同じ式(`step.timeout ?? FlowStep.defaultWaitSeconds`)で延ばして待ち直し、
`first-frame-pending` を立てる。延ばしても一様色のままなら従来どおり赤にして `first-frame-timeout`
を添える。**通る経路は増やさない**(flip は返し続ける) —— 変えるのは待つ長さだけなので、
誤った緑は1つも作らない。**厳密 0 では本番の crop に効かなかった**(2026-09-04 のフル E2E で
M1Max の launch storyboard は min=253 / max=255 = stdDev ≈ 0.1 で猶予が一度も付かず赤。
`nearBlankPNG` の対照と、上限をリテラルで固定するテストで縛る)。**stdDev は Tier-1 のインク足切りを通らない経路(幾何が疑い有り・閾値 0)
では未計算**なので、門が開いている回だけ測り直す(この取りこぼしは実装直後のレビューで見つけた)。

**FM 判定の控え `VisibilityVerdictMemo`**(2026-09-04): occlusion-guard の FM 判定を、
**FM への入力そのもの**(スクショのバイト列の hash・frame・screen・期待文字列)を鍵に控える。
「読む回数を減らす」変更なので、2回目の読みが担っていた砦を列挙した —— ①画面が変わった
(→ バイト列が変わり鍵が外れるので控えは効かない)②要素が動いた(→ frame が変わり鍵が外れる)
③期待値が違う(→ 鍵が外れる)④FM の死活・ブレーカの回復(→ nil は控えないので次は必ず訊く)。
残るのは「同じ画像・同じ領域・同じ文字列に FM が違う答えを返す」だけで、FM は同一画像に
決定的(92_screenLooksLike の実測)なのでそこに砦は無い。**控えは直近のスクショ1枚ぶん**
(バイト単位で変わった瞬間に丸ごと捨てる = 上限の定数を置かない)。効く場面は `select(...).textIs(...)`
のように同じ要素を続けて確かめる書き方 —— textIs が保持値を再検証するのは「検査を静かに消さない」
ための設計(FTRuntime の保持値の高速経路)で、控えはその検査を**同じ答えで**満たすだけ。
起点: E2E-iOS ジェスチャ S0010 は FM 60 回中ほぼ半分がこの重複で、M1Ultra(vision ≈ 2.6s/回)では
158s = 180s の予算超えで kill された(FM の遅さは M1Ultra の性質で、09-01 から同じ)。

`FMHealth`(Sources/FTCore/FMHealth.swift)が呼び出しの回数・レイテンシ・成否を計上し、
実行後に stderr へ警告する。結果 JSON の `fm` にも載る(PT-4.2)。
**これは理論上の話ではない**: 実績値では 6066 呼び出し中 5673 失敗(93.5%)で、
成功を含む run は 582 中 58 しかない。**E2E の「緑」は基本的にツリー一致の緑**であり、
可視性検証を含むとは限らないことを前提に読むこと(切り分け手順は docs/verification/)。

**全 FM 呼び出しは `FMCallAdmission.enter()` を通す**(Sources/FTCore/FMCallAdmission.swift)。
①サーキットブレーカ(FM は累積 20〜30 回で死に再起動まで回復しないので、連続 3 回失敗したら
以後呼ばない)②ホスト単位の許可枠(`FMCallSlots`。FM はホスト全体で共有される資源で、既定1枠。
詳細と実測は PT-3.5)の順に見る。
**新しい FM 呼び出しを足すときは必ずここを通す**(監査点を 1 つに保つのが目的)。
なお**ロックの有無自体は全滅の防止には効果が無いことが実測で確認済み**(残しているのは p50 が
下がるため。経緯と対照データは docs/verification/)。

**PCC(Private Cloud Compute)は完全に禁止**(ユーザー決定 2026-09-07)。macOS 27 SDK の
FoundationModels はモデル型を2つ持ち、**`PrivateCloudComputeLanguageModel` を使うとアプリの
画面情報が Mac の外へ出る**。受け手向けドキュメントが「画面情報は Mac の外に出ない」と
断定しているので、これは表現ではなく守るべき不変条件。使ってよいのは
`SystemLanguageModel`(オンデバイス)だけ。

守っているのは型ではなく **`LanguageModelSession` の init の既定値**である点に注意:

| init | `model:` の既定 |
|---|---|
| `init(model: SystemLanguageModel = .default, …)` | **あり**(オンデバイス) |
| `init(model: some LanguageModel, …)` | **なし** —— 明示しないと選べない |

つまり `model:` を省く限りオンデバイスに束縛されるが、**`model:` を1つ書くだけでクラウドへ
出られる**。機械で止めるのは `PrivateCloudComputeProhibitionTests`(ソース走査。①PCC の型名を
名指ししない ②セッションに `model:` を明示的に渡さない ③走査自体が Sources に届いていることの
確認)。PCC のインスタンスは型名を書かずには得られないので、①だけで経路は閉じる —— ②は二重の備え。

### DS-1.2 3B モデルに合わせた基本方針: 決定的な再生 + 失敗時のみ FM 介入

小さいモデルに毎ステップ判断させ続ける自律エージェント型は、コンテキスト溢れと
判断ミスが蓄積する。本ツールは **ハイブリッド型** を採る:

1. **実行モード**: 保存済みシナリオ(Swift DSL。DS-10)を FM なしで決定的に再生。
   高速・安定で CI 向き。失敗時のロケータ自己修復も指紋照合のみで FM を呼ばない(DS-10「ロケータの指紋」)。

(M2 で計画していた、FM がアプリを自律探索してシナリオを自動生成する explore モード
[`fleetest explore` / ExplorerProfile] は廃止済み。ロケータ自己修復に FM を使う設計も
2026-09-15 に撤去 → MN-22)

コンテキスト対策の原則:
- アクセシビリティツリーは **圧縮テキスト(set-of-mark 形式)** にして 1 画面ずつ渡す
- セッションは **呼び出し毎に新規作成**し、会話履歴は持ち回らない(DS-5.1)
- 出力は全て `@Generable` で構造化(自由文を返させない)

---

## DS-2 全体アーキテクチャ

```
┌─ macOS ホスト ────────────────────────────────────────────────────┐
│  fleetest CLI / MCP サーバ / VSCode 拡張(拡張は fleetest api を呼ぶ。   │
│  MCP サーバは FTCore/FTBridgeClient を直接リンクし fleetest api を経由しない) │
│  ├─ FTFoundationModels        : FoundationModels エージェント層               │
│  │   ├─ ReplayAssist      (画面検証。ロケータ修復は撤去済み DS-10) │
│  │   └─ OcclusionVerifier / FMDoctor / TestbaseDrafter               │
│  ├─ FTDSL          : Swift DSL(DS-10)/ セレクタ式 / ロケータの指紋 │
│  ├─ FTCore          : AppDriver プロトコル / StepExecutor(実行機) / 判定の型 │
│  ├─ FTBridgeClient  : iOS ブリッジへの HTTP クライアント・起動管理  │
│  └─ FTAndroid        : AndroidDriver + Android ブリッジ管理        │
└──────────────┬─────────────────────────────┬───────────────────────┘
               │ HTTP (localhost:8123〜 —     │ adb forward ⇄ 常駐ブリッジ
               │ シミュレータはホストと       │ (AndroidRunner/。iOS ブリッジと
               │ ネットワークスタック共有)     │  プロトコル完全互換の instrumentation)
┌──────────────▼───────────────┐   ┌──────────▼──────────────────────────┐
│  iOS シミュレータ             │   │  Android エミュレータ / 実機         │
│  FleetestRunnerUITests         │   │  BridgeInstrumentation(常駐)        │
│  (XCUITest 内 HTTP サーバ,    │   │  ├─ QuietWaiter: a11y イベント静穏  │
│   WDA 方式)                   │   │  │   検知で操作応答(固定 sleep 廃止)│
│  └─ XCUIApplication で        │   │  └─ SnapshotBuilder: AccessibilityNodeInfo
│     対象アプリを起動・操作     │   │     直接走査(型語彙を iOS と共通化) │
└────────────────────────────── ┘   └───────────────────────────────────┘
```

**`AppDriver` プロトコル**が唯一のプラットフォーム境界。iOS ブリッジ(Runner/)・Android
ブリッジ(AndroidRunner/)・InApp ブリッジは共通コア 13 エンドポイント(status/session/
snapshot/tap/type/clear/pressEnter/swipe/press/doubletap/pinch/screenshot/terminate)を
共有しつつ、XCUITest は 34、Android は 23、InApp は 18 という差分がある(追加分の内訳は DS-4.3 の表)(唯一の正は DS-4.3 の表 = `Tests/FTCoreTests/BridgeContractTests.swift`)。
`FTFoundationModels` / `FTCore` / `FTDSL` はプラットフォーム非依存のまま両OSで動く
(ブリッジ設計の詳細は DS-4、Swift DSL の詳細は DS-10)。

FTCore の中では、**実行機の状態を使わない判定は `StepExecutor` の static に置かず、中身を表す名前の型に置く**
(ロケータ解決 = `LocatorResolver`・容器推定 = `ContainerGeometry`・タップ先の幾何 = `TapTargetGeometry`・
遮蔽 = `OcclusionGeometry`・読みの照合 = `TranscriptMatch` 等)。**依存は実行機 → 判定の一方向**で、
判定の型から `StepExecutor` を参照しない(理由と測り方は MN-57)。

```swift
// 抜粋(全定義は Sources/FTCore/AppDriver.swift)
protocol AppDriver {
    func status() async throws -> StatusResponse
    func install(packagePath: String) async throws       // .app / .apk
    func launch(bundleID: String) async throws
    func snapshot() async throws -> SnapshotResponse     // 圧縮済みツリー
    func tap(ref: Int) async throws
    func tap(x: Double, y: Double) async throws
    func type(ref: Int?, text: String) async throws
    func swipe(_ direction: FTSwipeDirection) async throws
    func screenshot() async throws -> Data               // PNG
    func terminate() async throws
    // ほかに uninstall / activate / openAppSwitcher / home / back / clearInput /
    // hideKeyboard / clearAppData / openURL / pressEnter / drag / press /
    // doubleTap / pinch / rotate / snapshot(bypassingCache:) / isAppForeground 等
}
```

未対応ドライバ(InAppDriver/SystemUIDriver 等)は activate/openAppSwitcher/home/drag/
座標 press にデフォルト実装(launch へのフォールバック、または 501 エラー)が用意されている
(Sources/FTCore/AppDriver.swift)。

---

## DS-3 リポジトリ構成

```
foundation-tester/
├── Package.swift                  # CLI とライブラリ (macOS 26+。視覚系のみ 27+)。マーカー区間にプロジェクト毎の
│                                  # executableTarget を自動生成(DS-11。fleetest project create/sync)
├── Sources/
│   ├── fleetest/                   # CLI エントリポイント(+ ProjectCommands / ProfileRunner / Api*Command)
│   ├── FTCore/                    # AppDriver, StepExecutor, ScenarioHost, RunOrchestrator,
│   │                              # TestProject / RunProfile / LocalConfig(DS-11)。
│   │                              # セレクタ文法(FTSelector)・コマンド索引(CommandIndex)・
│   │                              # コード生成(ScenarioCodeGen)もここ = DSL ランタイム非依存。
│   │                              # 判定の型(LocatorResolver・ContainerGeometry・TapTargetGeometry 等)は
│   │                              # StepExecutor を参照しない(DS-2)
│   ├── FTRemote/                  # SSH ディスパッチ・ランナー登録簿・dispatch.lock・占有(docs/remote-runner/)。
│   │                              # 利用側は fleetest CLI だけ = 受け手のシナリオ実行バイナリにはリンクしない
│   ├── FTServices/                # compose.yaml の解釈・検査(ComposePolicy)・実行計画(ServicePlanner)・ビルドの指紋
│   │                              # (RR-17)。利用側は fleetest CLI と fleetest-mcp だけ =
│   │                              # Yams ごと、受け手のシナリオ実行バイナリにはリンクしない(PackageLinkageTests)
│   ├── FTDSL / FTDSLMacros/       # Swift DSL とマクロ(DS-10)。
│   │                              # コマンド本体・FTRuntime・下書き生成(ScenarioDraftCodeGen)
│   ├── FTScenarioRunner/          # fleetest-scenarios-<project> の CLI 実装
│   ├── FTFoundationModels/                   # FoundationModels: プロファイル, @Generable 型, Tools
│   ├── FTBridgeClient/            # iOS ブリッジ HTTP クライアント + SimulatorCatalog / BridgeProvisioner
│   ├── FTAndroid/                 # AndroidDriver + AndroidBridge / AndroidDeviceCatalog / ProfileWorkerFactory
│   └── fleetest-mcp/               # MCP サーバ(stdio、自前実装)
├── Runner/                        # iOS ブリッジ本体
│   ├── FleetestRunner.xcodeproj/   #   project.xcproj(Xcode 27.2 の JSON プロジェクト形式)がソース。ソースはフォルダ同期
│   ├── FleetestRunnerApp/          #   空のホストアプリ(UIテストの器)
│   └── FleetestRunnerUITests/      #   HTTP サーバ内蔵の常駐 UI テスト(DS-4.1〜DS-4.2)
├── AndroidRunner/                 # Android ブリッジ本体(DS-4.5。詳細は AndroidRunner/README.md)
│   ├── src/com/example/ftbridge/  #   BridgeInstrumentation / QuietWaiter / SnapshotBuilder 等(Java のみ)
│   ├── build.sh                   #   prebuilt/ftbridge.apk の再ビルド
│   └── prebuilt/ftbridge.apk      #   同梱 prebuilt APK(初回操作時に自動インストール)
├── TestProjects/                      # テストプロジェクト(DS-11)
│   └── SampleApp/
│       ├── profiles/              #   実行プロファイル(apps / machines / runs)
│       ├── scenarios/             #   Swift DSL シナリオ(SPM ターゲットの path)
│       ├── docs/testbases/        #   テスト設計の元資料(仕様・観点)。シナリオの根拠
│       ├── reports/               #   実行レポート出力先(プロジェクト別)
│       └── .fleetest/              #   ロケータの指紋等(プロジェクト別)
├── Scripts/bench.swift            # 計測基盤(DS-9。詳細は docs/performance-tuning/)
├── E2EAppCMP/                     # 自己 E2E の SUT: Compose Multiplatform(→ TestProjects/E2E-CMP)
│   └── docs/ui-contract.md        #   **全 SUT 共通の画面・#id・ラベル契約(唯一の正)**
├── E2EAppIOS/                     # 自己 E2E の SUT: SwiftUI + 一部 UIKit(→ TestProjects/E2E-iOS)
├── E2EAppAndroid/                 # 自己 E2E の SUT: View/XML + 一部 Compose(→ TestProjects/E2E-Android)
├── E2EAppFlutter/                 # 自己 E2E の SUT: Flutter(→ TestProjects/E2E-Flutter)
├── E2EAppRN/                      # 自己 E2E の SUT: React Native(→ TestProjects/E2E-RN)
│                                  #   各 SUT の docs/ui-contract.md には**型語彙と固有の罠だけ**を置く
├── SampleApp/                     # 検証用の小さな SwiftUI デモアプリ(テスト対象)
├── vscode-fleetest/                # VSCode 拡張。UI 入口はここに一本化(旧 fleetest-gui は 2026-07-10 削除)
└── docs/design/                 # 本書
```

---

## DS-5 FM 呼び出し層(FTFoundationModels)設計

### DS-5.1 セッション戦略(4K トークン運用)

- **画像を伴う呼び出し(テキストの可視性検証・screenLooksLike・死活の確かめ)は FM の常駐プロセス
  (`fleetest api fm-serve`)だけが撃つ**。シナリオのプロセスは `LanguageModelSession` を持たず、Unix ソケットで要求を送る
  (`FTCore/FMServe.swift`。理由は MN-81 = 入れ替わる多数のプロセスが各自セッションを作ると、モデルの載せ直しが
  絶えず起き、その瞬間に ANE の `no memory` で FM が死んだ)。常駐プロセスは最後の利用から 1 秒空くたびに小さな画像の転写(実際の生成)を撃って
  モデル(安全判定のモデルを含む)を ANE に載せたままにし、どこからも要求が無いまま 30 分経つと終わる
- 常駐の整合確認は `FTCore/FMServeAlignment.swift`(`api fm-align`)で行う。アラインは転送した不変コピーを保守の親にし、
  全FM枠の保持・旧常駐の安全退役・ソケット所有権の確保・ビルド・新版の身元確認の順で進める。
  ビルド無しの確認なら同一の版・実行パス・buildStampを再利用する。置換は常駐自身が全活動の終了と新規受付の閉鎖を原子的に確定した後だけ行う。
  期限切れ後も残る推論は終了まで待つ。退役制御は推論と独立した版1、推論契約は4。安全退役非対応の旧wire2/3は自動停止しない。
  詳細と更新失敗時の対応は[リモートの版整合](../remote-runner/README.md)
- **1 呼び出し = 1 セッション**。毎回新しい `LanguageModelSession` を作り(常駐プロセスでは暖めておいた予備を使い)、
  会話履歴は持ち回さない。渡すのは instructions(役割定義、~200 トークン)+
  その場で必要な入力(壊れたロケータ・失敗ステップの差分・現在画面の圧縮スナップショット等)のみ
- 応答は必ず `@Generable` 型。自由文を返させないことで応答トークンも節約。

### DS-5.2 主要な @Generable 型

`LocatorRepairSuggestion`(壊れたロケータの代替案を FM に提案させる型)は 2026-09-15 に撤去した
(自己修復は指紋照合のみになり FM を呼ばないため。DS-10「ロケータの指紋」・MN-22)。
残る `@Generable` 型はスクリーンショットの画面検証(`ScreenVerdict`)等、FM を呼ぶ他の機能のもの。

### DS-5.3 実装(Sources/FTFoundationModels/ の9ファイル)

| 実装 | 役割 |
|---|---|
| `ReplayAssist.swift`(`FMReplayDelegate`) | シナリオのプロセスの FM フック: スクリーンショットの画面検証(`ScreenVerdict`。**マルチモーダル**)を常駐プロセスへ頼み、結果を記録する。ロケータ自己修復のフック(`LocatorRepairSuggestion`)は 2026-09-15 に撤去(DS-10・MN-22) |
| `OcclusionVerifier.swift` | アサーションがツリー通過した直後の、遮蔽による誤った緑の排除(マルチモーダル。要素 frame にクロップし、転写を常駐プロセスへ頼む) |
| `FMServeServer.swift` | FM の常駐プロセス(`fleetest api fm-serve`)の本体。画像を伴う実呼び出し・載せたままにする暖機・無操作での終了。通信と起動は `FTCore/FMServe.swift` |
| `PreloadSlot.swift` | 常駐プロセスの予備のセッション 1 つ分の規則(同じ instructions なら作り直さない・使ったら捨てる) |
| `FMDoctor.swift` | FM 可用性判定。`check()` は同期・可否を保証しない / `checkLive()` は実際に1回推論する(DS-1.1 の罠) |
| `TestbaseDrafter.swift` | テスト設計資料 → シナリオ下書き(DS-17)。FM 不可用時は決定的パーサへ落ちる |
| `FMLivenessProbe.swift` | FM の死活プローブ(§リモート「FM の「死活」は回数とは別の軸」)。実呼び出しは常駐プロセスへ頼む。**FMCallAdmission を通さない** |
| `FMLoadGenerator.swift` | `fleetest doctor --fm-load` の負荷測定。**FMCallAdmission を通さない**(測っている対象が門になるため) |

- 生成を伴う FM 呼び出し(`ReplayAssist` / `OcclusionVerifier` / `TestbaseDrafter`)は
  `FMCallAdmission.enter()` を通す(DS-1.1。常駐プロセスへ頼む2つも、頼む側で通す = 枠の待ちはシナリオの締め切りから
  差し引かれる)。死活プローブ・負荷生成・常駐プロセスの暖機は意図してこの門を通らない。
- **`LanguageModelSession` を作ってよいのは `FMServeServer` / `TestbaseDrafter` / `FMLoadGenerator` だけ**
  (`FMServeTests.testOnlyTheFMProcessAndAuthoringToolsCreateSessions` が集合を等号で固定)。
  出力の実例・運用知見は DS-8.6。

---

## DS-6 CLI UX

```
fleetest --version                         # <git の短い revision> (protocol <版>)。ビルドの特定に使う
fleetest doctor                            # FM 可用性・Xcode・シミュレータ・adb の事前チェック
fleetest bridge up|down|status [--platform ios|android] [--device ...] [--serial ...]
                                           # ブリッジ(iOS: 常駐 XCUITest / Android: 常駐 instrumentation)の管理
fleetest run [--project P] [--profile 名] [--scenario id...] \
    [--set キー=値] [--report-dir ...] [--port 8123 --port 8124] [--skip-build]
                                           # Swift シナリオの決定的実行(プロファイル実行はDS-11)
fleetest draft-scenario [--project P] [--testbase 資料.md] [--no-fm] [--dry-run]
                                           # テスト設計資料からシナリオ下書きを生成(DS-17)
fleetest project create|list|sync          # テストプロジェクトの作成・一覧・Package.swift 再整合(DS-11)
fleetest profile list                      # 実行プロファイルの一覧と現在マシンでの解決チェック(DS-11)
fleetest install <パッケージパス>           # .app / .apk のインストール
fleetest launch|terminate <bundle-id>      # アプリの起動・終了
fleetest snapshot [--json] | tap | type | swipe | press | screenshot
                                           # 手動駆動プリミティブ(圧縮スナップショット・操作。DS-4.4)
```

実行結果はシナリオ実行毎に `TestProjects/<name>/reports/scenario-*.md`(DS-10)へ自動出力される。
集約・分析は別レイヤの `fleetest results list/summary/flaky/trend/devices/slow/insights/log`(DS-14)で行う。

- **`bridge up` が起動するのは xcuitest ブリッジ(iOS)/デバイス内サーバ(Android)のみ**(in-app ブリッジを
  起動する経路は無い)。プロセスは常駐し、停止は `bridge down` か `devices down` を要する
- **`run --profile` は終了時にブリッジを停止しない**(常駐を残すのが仕様。次の run が版一致なら再利用する。
  利用者向けのコマンドは docs/user-docs/reference/tools/cli_ja.md)
- **手動駆動プリミティブの宛先解決(ポート探索・serial の自動採用・版ズレの拒否 `--allow-version-skew`)は
  MCP(ft_*)と同じ `FTBridgeClient.BridgeTargetResolution` / `FTAndroid.AndroidTargetResolution` を通す**
  (判定は1箇所・文言は呼び手ごと)。ref の撮り直し照合・snapshot のキャッシュ回避・入力の読み返しといった
  MCP 側の探索防御は CLI へ持ち込まない(1手ずつ確認する用途なので、2つ目の実装を作らない)
- **`fleetest --version` と `fleetest api version` は用途が違う**: 前者は人間向け(revision + protocol 版の
  1行)、後者は従来どおりプロトコル版だけを JSON で返す機械可読な口(`ToolVersion.describe()` /
  `fleetestProtocolVersion`)

VSCode 拡張は `fleetest api ...` 系サブコマンドを経由して呼び出す(DS-11.4 参照)。MCP サーバは
`fleetest api` を経由せず FTCore / FTBridgeClient / FTAndroid を直接リンクする —— 共有できるのは
これらのモジュールに置いた純粋ロジックだけで、`Sources/fleetest/` の型は MCP から見えない。
**CLI と MCP で同じ判定を持たせたいときは FTCore 側へ置く**(`Sources/fleetest/` に書くと
MCP には届かず、同じ処理の2つ目の実装が育つ)。

---

## DS-9 検証方法(E2E)

0. **同梱 SUT + 対になるテストプロジェクト**が fleetest 自身の機能別 E2E。DSL のコマンド面
   (セレクタ記法・type・tap(holdSeconds:)/swipe・scrollTo・暗黙待ちと timeout・ifCanSelect/select・
   relaunch・ios{}/android{})を 1 機能 1 シナリオで網羅する。
   ネットワーク依存ゼロ・状態は起動ごとにルート正規化する設計で、フリートのロケール差や
   バックエンド死活に左右されない。`Scripts/e2e.sh` が全 SUT を鮮度判定つきで回す。

   **SUT は UI フレームワークごとに5つ**ある。同じ画面・同じ `#id`・同じラベルを5通りの
   実装で作ってあり、`AppDriver` から上(セレクタ解決・スナップショット圧縮)がフレームワークに
   依存しないことを実証する土台になっている:

   | SUT | 実装 | プロジェクト | 対象 OS | 契約 |
   |---|---|---|---|---|
   | `E2EAppCMP/` | Compose Multiplatform | `TestProjects/E2E-CMP` | ios + android | **`E2EAppCMP/docs/ui-contract.md` が唯一の正** |
   | `E2EAppIOS/` | SwiftUI + 一部 UIKit | `TestProjects/E2E-iOS` | ios | 差分のみ `E2EAppIOS/docs/ui-contract.md` |
   | `E2EAppAndroid/` | View/XML + 一部 Compose | `TestProjects/E2E-Android` | android | 差分のみ `E2EAppAndroid/docs/ui-contract.md` |
   | `E2EAppFlutter/` | Flutter | `TestProjects/E2E-Flutter` | ios + android | 差分のみ `E2EAppFlutter/docs/ui-contract.md` |
   | `E2EAppRN/` | React Native | `TestProjects/E2E-RN` | ios + android | 差分のみ `E2EAppRN/docs/ui-contract.md` |

   **`#id` とラベルは5 SUT で完全に同一、違うのは「型」と「id を露出させる作法」だけ**という設計。
   実測で採取した型の食い違い(いずれも同じ `#id` を指す):

   | 要素 | CMP(iOS) | CMP(Android) | SwiftUI/UIKit | View/XML | Flutter(iOS) | Flutter(Android) | RN(iOS) | RN(Android) |
   |---|---|---|---|---|---|---|---|---|
   | ボタン | `button` | `button` | `button` | `button` | `button` | `button` | `button` | `button` |
   | スイッチ | `switch` | `switch` | `switch` | `switch` | `switch` | `switch` | `switch` | `switch` |
   | テキスト | `staticText` | `staticText` | `staticText` | `staticText` | `staticText` | `staticText` | `staticText` | `staticText` |
   | パスワード欄 | `textView` | `secureTextField` | `secureTextField` | `secureTextField` | `textField` | `textField` | `secureTextField` | `secureTextField` |
   | チェックボックス | `button` | `checkBox` | `button` | `checkBox` | `switch` | `checkBox` | `other` | `checkBox` |
   | リスト行 | `button` | `clickable` | `clickable`(UITableView) | `clickable` | `button` | `button` | `button`(TaggedButton) | `button`(TaggedButton) |

   ボタン・スイッチ・テキストが揃っているのは 2026-07-26 の役割正規化の結果(それ以前は
   CMP(Android)のボタン/スイッチが `cell`[現 `clickable` の旧名]、Flutter(Android)の
   テキストが `other` だった)。**チェックボックスとリスト行は揃わない** — iOS 側の a11y が
   役割を出さないため(下記「型は役割に正規化する」)。**RN はパスワード欄・リスト行が
   ネイティブ SUT(SwiftUI/View)と同型で揃う**(RCTUITextField/ReactEditText がそれぞれ
   `UITextField`/`EditText` 派生のため。詳細は `E2EAppRN/docs/ui-contract.md`)

   **入力欄は「モード間で揃える」ところまでが担保**で、OS 間では揃わない(2026-08-06 実測)。
   iOS の自前描画フレームワーク(Compose / Flutter)の入力欄は UIKit の `UITextField` ではないので、
   in-app ブリッジのクラス判定を素通りして `other` に落ちていた —— **in-app だけ `other`・
   xcuitest は `textView`** という食い違いで、MCP で探索した型がシナリオで通らなかった。
   判定を**テキスト入力 trait(`1<<18`)**に足し、`UITextInput` 準拠で分けることで
   XCUITest の `elementType` と一致させた(`InAppSnapshot.elementType`):

   | | 要素クラス | traits | UITextInput | in-app / xcuitest とも |
   |---|---|---|---|---|
   | Compose | `AccessibilityElement` | `1<<47｜1<<18` | 非準拠 | `textView` |
   | Flutter | `TextInputSemanticsObject` | `1<<37｜1<<18` | 準拠 | `textField` |

   上位ビットはフレームワーク固有なので見ない。**マスクの有無は iOS のこの2系統では型に出ない**
   (Compose も Flutter も secure にならない)ので、跨 OS で入力欄を指すときは `#id` を使う。
   UIKit/SwiftUI は従来どおりクラス判定が先に効き `textField` / `secureTextField` / `textView` に分かれる。
   **React Native の入力欄はこのクラス判定がそのまま効く**(`RCTUITextField` が `UITextField` 派生・
   Android の `ReactEditText` が `EditText` 派生のため、trait 分岐を新設する必要が無かった。
   2026-08-08 実測)。既存経路のみで `textField` / `secureTextField` / `textView`
   (multiline は Android のみ `textField` のまま。詳細は `E2EAppRN/docs/ui-contract.md`)

   **Android は「見切れた要素の型が変わらない」ことも担保**(2026-08-06)。Compose の役割は
   同一矩形の無名子ノード(役割マーカー)で表現されるが、**見切れると親とマーカー子は独立に
   クリップされる**ため、矩形の完全一致を条件にしていると引き上げに失敗し、
   **同じ Composable が可視状態によって `button` と `clickable` を行き来していた**。実測3形:

   | 見切れ方 | 親 | マーカー子 |
   |---|---|---|
   | 右端(`#tag_04`) | `(987,1972)-(1080,2119)` | `(987,1972)-(1038,2119)`(子が狭い) |
   | 下端(`#btn_scroll_top`) | `(42,378)-(278,441)` | `(42,378)-(278,504)`(**子のほうが大きい**) |
   | 上端(`#row_07`) | `(42,441)-(1038,559)` | `(42,504)-(1038,559)`(原点が違う) |

   「子は親に内包される」も「原点は動かない」も成り立たない。**成り立つのは辺の共有**
   (切れていない側は必ず一致する = 3形とも3辺一致・角で切れれば2辺)なので、条件は
   **2辺以上の一致 + 面積が3倍以内**(`SnapshotBuilder.looksLikeRoleMarker`)。
   装飾(行の中のアイコン)は0〜1辺しか一致しない —— ここを緩めすぎると**リスト行が `image` になる**

   id 露出の作法もフレームワークごとに違う: Compose は `testTagsAsResourceId`(Android のみ・
   ダイアログには再適用が必要)、View 系は `android:id`(**実行時に resource-id を作れないため
   動的リストは `res/values/ids.xml` に静的宣言**)、SwiftUI は `.accessibilityIdentifier`
   (**UIAlertController の title/message には効かない**)、Flutter は `Semantics(identifier:)`
   (**`ensureSemantics()` 必須・`MergeSemantics` で畳む必要あり・Slider に畳むと iOS で
   a11y ツリーが丸ごと空になる**)、React Native は `testID`(iOS は `accessibilityIdentifier`・
   Android は 0.65 以降 `resource-id` にマップ。Modal 内にも届く)。詳細は各 SUT の `docs/ui-contract.md`。
1. `SampleApp`(ログイン画面 + ホーム画面 + 設定画面の 3 画面 SwiftUI アプリ、
   accessibility identifier 付き)をリポジトリに同梱
2. M1: `fleetest bridge up` → `curl localhost:8123/snapshot` で圧縮ツリーが返る
3. M3: SampleApp の identifier を 1 つ改名 → `fleetest run --set heal=true` で修復・成功。
   意図的にログインを失敗させるビルド → 結果 JSON に失敗した section/command/failureKind が
   事実として残る(FM による `appBug` 等の分類は 2026-09-15 に撤去 → MN-21)
4. 性能の検証・回帰比較は `Scripts/bench.swift` の計測基盤で行う。壁時計中央値・
   シナリオ/ステップ内訳・成功率・ホスト CPU/GPU/MEM を `summary.md` に出力し、
   変更前後を比較する。手順・指標の読み方は
   [パフォーマンスチューニングガイド](../performance-tuning/README.md)を参照
