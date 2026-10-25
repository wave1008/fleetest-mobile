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

以下は初期の adb 直叩きの版の知見で、今の Android は常駐ブリッジだけで動く(DS-8.7.1・DS-4.5)。

- **adb 直叩きで十分**: `uiautomator dump`(ツリー)+ `input tap/text/swipe` + `screencap` で
  AppDriver を完全実装できた。UIAutomator2 サーバや Appium は不要(依存ゼロ方針を維持)
- **CLI プロセスは短命**: iOS はランナー常駐だが Android ドライバは CLI 内に住むため、
  ref→座標対応表を一時ファイルに永続化して手動駆動コマンドをまたげるようにした
- 既知の制限: `adb input text` は ASCII 中心(日本語はIME経由が必要)。実機は `--serial` 指定

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
  顕在化する潜在バグで、inapp-boost モードの suspend 誤ルーティング(PT-8)が引き金だった。
- **inapp-boost モードの in-app suspend**: system-UI シナリオと in-app シナリオを混在実行すると、背面の
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
- **MCP(`ft_*`)の iOS の構成**(経緯: 2026-08-04 に「実行プロファイルのモードに追従する」= inapp-boost モードも
  使う形にしたが、利用者の決定で取り消した。in-app を主にした合成 `HybridFallbackDriver` は今はライブ操作だけが使う)
  - **繋いだブリッジの版を照合し、ズレは既定で拒否する**(`MCPServer+Driver.swift` の
    `enforceVersion` / `bridgeVersionSkew`。2026-08-06 導入・2026-08-09 に警告から拒否へ反転)。
    profile 無しの iOS 経路は `ExploreDriverResolver` が**生きているポートへ素で繋ぐ**だけで
    provision を通らないため、`bridgeProtocolVersion` を上げても旧ランナーが使われ続ける
    (実害: ランナー側の修正2件が `bridge down && bridge up` まで反映されなかった)。
    MCP の出力はシナリオへ書く文字列の供給源なので、古いブリッジの注記から誤ったセレクタが
    書き込まれるほうが「セッションが止まる」より高くつく("Refusing to operate…" を throw)。
    押し通すには `allowVersionSkew: true` で、その場合は**毎回の応答に警告が付き続ける**
    (1度言って黙らない)。版を返さない旧ブリッジ(nil)は判定できないので黙る。
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
---
