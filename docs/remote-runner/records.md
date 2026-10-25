# リモート実行: 未検証事項・作業計画・初期の実装メモ(RR-9・10・12)

| 種別 | 範囲 | 読む場面 | 扱わないこと |
|---|---|---|---|
| 記録 | 実装前の未検証事項・作業計画・Phase 1 の実装メモと、実装状況の経緯 | 設計の経緯や、初期に踏んだ罠を確かめるとき | 現在の設計(→ このフォルダの他のファイル) |

現在の仕様ではない。日付はその時点のもの。

## 実装状況の経緯

2026-07-30 の検討結果の文書化。**Phase 1(`run --runner` / `api run --runner` と GUI の
ホスト登録・実行先選択)は実装済み(RR-12)。RR-14 の導入コマンド一式(`preflight.sh --runner` /
`remote setup` / 汎用転送 `remote exec`)も実装済み(2026-08-16)。**RR-13 は段1〜段4が実装済み**
(段5 の残りは健全性 watchdog の分界だけ。ブリッジ watchdog は 2026-09-25 に分界済み)、**RR-16 の運用コマンド(16.1〜16.5)と RR-18 の共有
(FIFO 待機列・占有の配布・1マシン1 run)も実装済み**。
**別マシン(M1Ultra)への導入とシナリオ1本の実走まで実機で確認済み(2026-08-16。RR-14 末尾に実測と罠)**。
**利用者向けの手順書は [remote-runner-setup.md](../remote-runner-setup.md)**(この文書は設計の記録)。
**SSH 越しの実 E2E は localhost で実施済み(2026-07-31。RR-9 実験①)** — 到達経路が確定し、
`asuser` は撤去した(root 必須で実用不可)。実2台での検証は未実施。
**セキュリティ前提と信頼モデルは RR-15** — 実装前に必ず読むこと。

## RR-9 未検証事項(実装前に潰す)

### 実験①の結果(2026-07-31 localhost E2E で実測・確定)

| 項目 | 結果 |
|---|---|
| **`launchctl asuser` で Aqua へ注入できるか** | ❌ **不成立**。`Could not switch to audit session: Operation not permitted` — **asuser は root を要求する**。sudo/NOPASSWD を作らない方針(RR-5)なので**実用不可 → 撤去**(ユーザー決定) |
| **SSH の Background セッションで直に実行** | ✅ **成立**。シミュレータ起動・アプリインストール・**XCUITest ブリッジ・in-app ブリッジ・シナリオ実行**まで通った(これが唯一の経路になった) |
| ディスパッチの体験(転送→実行→中継→回収) | ✅ 成立。JUnit・Markdown レポートともローカルへ回収できた |
| **初回/2回目以降の所要**(Phase 1 ゲート) | 初回 **95秒**(リモートビルド+ブリッジ供給込み)/ 2回目 **10.8秒**(ブリッジ温存・増分ビルド)。コールドは初回だけで、実用に耐える |
| キャンセル伝播(`-tt`) | ✅ 実証。`-tt` ありはローカルの ssh を kill するとリモートのプロセスも消え、**`-tt` なしは残る**(対照実験) |
| `api run --runner` の NDJSON 中継(拡張経路) | ✅ 成立。stdout は全行が妥当な NDJSON・リモートの診断は stderr へ(`-tt` による合流を中継側で振り分け。RR-12) |
| `--remote-timeout` の実発火 | ✅ 実証。期限で打ち切られ、**リモートのプロセスも残らない**(SIGTERM→SIGKILL が届く) |

**設計への影響**: RR-5 が前提にしていた「Background セッションでは iOS シミュレータが動かない」は
**この構成では誤りだった**。**コンソールに誰かがログインしている(Aqua セッションが存在する)限り、
SSH 側のプロセスからでもユーザーの launchd ドメインのサービス(CoreSimulator 等)に到達できる**。
したがって:

- **`--remote-session` を撤去**(選択肢が1つなのでオプション自体を持たない)
- **RR-16.3 のログイン状態チェック(console user)が唯一の実効的な前提**になる。
  「Aqua セッションが**存在する**こと」が要件で、「ディスパッチされたプロセスが Aqua の**中にいる**こと」は不要
- Phase 2 の session agent は**当面不要**(asuser 不成立時の代替として計画していたが、直接実行で足りる)

### 未実施の実験

**実験4回に束ねてある**(項目ごとに別実験を組まない。1回の実験で複数項目が同時に判明する):

| 実験 | 一度に判明する項目 | 手順 |
|---|---|---|
| **① localhost 素振り**(要 sshd 有効化)**= 実施済み。上の結果表を参照** | 到達経路の成否 / ディスパッチの体験成立(転送→実行→回収)/ 遠隔での flake 診断コスト | localhost へ SSH して run を1本通し、成果物回収と、失敗時にレポートだけで切り分けられるかを見る |
| **② 画面ロックしたまま run 1本** | FM のロック中挙動 / **XCUITest・シミュレータ・録画のロック中可否**(RR-5 の2モード共通の前提) | ロック状態で run を通し、あわせて `doctor --fm-only` を反復(availability は嘘をつくので実呼び出し)。不可なら「ロック無効」をランナー要件に戻す(FileVault は維持できる) |
| **③ `fdesetup authrestart` 1回** | 対象機(Apple silicon・当該 macOS)で使えるか | 実行して、再起動後にボリュームが解錠され loginwindow まで来ることを確認 |
| **④ Android の SSH 実行 = 実施済み(2026-07-31)** | ヘッドレス起動 / gRPC 制御 / シナリオ実行 | **RR-6 に結果を記載**。`-no-window` は元から既定だったため「ヘッドレス化の可否」ではなく「SSH セッションから動くか」を実測した |

## RR-10 作業計画

各 Phase の末尾が判断ゲート。**Phase 0 で需要または体験が成立しなければ中止**(以降を作らない)。

**進行の実際(2026-07-31)**: ユーザー判断により **Phase 0 を実施しないまま Phase 1 を
実装済み**(RR-12)。**RR-9 の実験①は 2026-07-31 に実施済み**で、到達経路は確定した
(asuser 撤去・SSH セッションで直接実行)。残る未実施は実験②〜④(画面ロック中の挙動・
`fdesetup authrestart`・Android `-no-window`)。

### Phase 0: 素振り・検証(実装なし)

- 手動 SSH で隣の Mac へ run を投げる(転送→install.sh→run→回収を手作業)
- RR-9 の実験4回を実施(①が最優先 — 到達経路を決める。**①は実施済み**)
- **ゲート**: 対話的分散・共有の需要が実在するか/ジョブ粒度の体験が成立するかをユーザーが判断

### Phase 1: `fleetest run --runner <mac>`(単一リモート・ジョブ粒度)

- 適合チェック(RR-7)・rsync 転送・リモート実行・出力ストリームバック(RR-3 の用途分け)・
  成果物回収(JUnit の `report:` パス書き換え含む)
- Aqua への到達は Phase 0 で成立を確認した経路を使う(**確定: SSH セッションで直接実行**)
- 純粋ロジック(適合判定・転送対象の算出・回収パス書き換え)は切り出して単体テスト。
  SSH 越しの結合は E2E に残す
- 新スクリプト/サブコマンドを足したら Bash 許可リストにも足す(承認3方向の②)
- **ゲート**: 実デバイスの run 1本が手元 CLI から見えて成果物が開けること。
  加えて**2回目以降のディスパッチ所要(転送+増分ビルド)を計測**し、体験成立の
  判断材料にする(コールドビルド数分は初回のみか、を確認)

### Phase 2: session agent 常設化 + 運用ドキュメント

- LaunchAgent 版 session agent(受けて spawn して中継するだけ+**ジョブ直列化**[RR-5])
- **control(Background)→ execution(Aqua)の受け渡し IPC をここで決める**
  (候補: スプールディレクトリ監視 vs localhost ソケット。設計判断として記録する)
- ランナー機セットアップ手順の文書化(RR-14 のモード A/B・LaunchAgent・RR-15 の
  セキュリティ注意)。ci.md のランナー前提と整合させる
- **ゲート**: 再起動後(モード A は解錠+ログインの後・モード B はゼロタッチで)、
  人手なしで受付可能に戻ること。同時ディスパッチ2本が直列化されること

### Phase 3: マルチマシン分散

- `RunOrchestrator` worker のマシン跨ぎ拡張・results DB マージ・JUnit 集約
- ToolchainFingerprint によるフリート適合チェック(不適合機は除外して警告)
- **ゲート**: 2台分散で壁時計が短縮され、失敗レポートが手元から辿れること

### Phase 4(任意): Android ヘッドレスレーン

- RR-6 の採用条件2つが実測で成立した場合のみ。ディスパッチの振り分け(対象 OS・FM 使用)を追加

## RR-12 Phase 1 実装メモ(2026-07-31)

`fleetest run --runner <user@host>`(`--profile` 必須。`--port`/`--report-dir`/`--failed`/
`--skip-build` は併用不可)・`--remote-dir`(既定: ローカルルートと同じ絶対パス)・
(`--remote-session` は asuser 撤去に伴い廃止)。純粋ロジックは
`Sources/FTRemote/RemoteDispatch.swift`(単体テスト対象)、プロセス起動は
`Sources/fleetest/RemoteRunDispatcher.swift` に集約。

設計文書からの意図的な逸脱:

- ~~リモートは clone 構成前提~~ → **撤回(2026-07-31)。RR-3 どおりの外部構成に戻した**。
  clone 構成のままだと**ローカルインストール済みマシンと干渉する**(実害3件: rsync
  `--delete` が相手の `Scenarios`/`profiles` を消す・レポート回収が相手のローカル実行分まで
  引き込む・クローンと `.build` の共用で SPM ビルドロック競合と results 混在)。
  現在は**リモートに専用ベースディレクトリ1つ**(`--remote-dir`。既定 `~/fleetest-runner`)を
  置き、その配下で完結させる:

  ```
  <base>/          ← --remote-dir(既定 ~/fleetest-runner。チルダは $HOME で解決)
  ├── tool/        ← TOOL_ROOT(ランナー専用クローン)。バイナリは tool/.build/debug/fleetest
  └── work/        ← WORK_DIR(受け手パッケージ。TestProjects・results・.build)
  ```

  実行は `cd <base>/users/<issuer>/work && <base>/foundation-tester/.build/debug/fleetest …`。`packageRoot()`(cwd から
  Package.swift を探す)が work を、`RepoRoot.find()`(実行バイナリの位置)が tool を
  独立に解決するため、**既存の外部構成の仕組みでそのまま成立する**(新しい解決規則を
  作っていない)。マシン自身の `~/foundation-tester` や `TestProjects/` には一切触れない
- アプリバイナリは転送しない(rsync 対象はシナリオ・プロファイルのみ。dispatch 開始時に
  注記を1行出す)。appPath はリモート側で有効なパスであることが前提
- results DB の**マージ**(ローカルの集計に混ぜる)は行わない(Phase 3 の課題)。**録画と run ログ
  (`results/` 配下)は run のたびにローカルの `TestProjects/<name>/results/` へ rsync で回収する**
  (**`--delete` は付けない** — ローカルで別に走った run の results を巻き添えで消さない。
  差分転送なので再ディスパッチは安い)。回収しないと LPT(投入順・フリート割り当て)が
  リモートで走ったシナリオを永久に「実績なし」として扱う。
  拡張連携(`fleetest api run` の NDJSON 中継)は RR-12 末尾のとおり後日実装
- **レポート回収はディスパッチ単位に隔離**(2026-07-31)。run に
  `--report-dir <base>/users/<issuer>/work/.fleetest/dispatch/<stamp>/reports` を内部で渡し、
  **そのディレクトリだけを回収して、回収後にリモートから削除**する
  (リモートの `reports/` を丸ごと引くのをやめた。相手の無関係な実行分・録画を
  引き込まないため。ユーザーの `--report-dir` 併用は引き続き不可 = 内部で使うため)

**localhost E2E で見つかり修正した実装上の罠(2026-07-31。いずれも単体テストでは出ない)**:

- **クローンのディレクトリ名は `foundation-tester` 固定**(`<base>/tool` にしていた)。SPM は
  パス依存のパッケージ名を**ディレクトリ名から導出**するため、受け手 Package.swift の
  `package: "foundation-tester"` と一致せず `unknown package` でマニフェストが壊れた
- **非対話 ssh の PATH は `/usr/bin:/bin:/usr/sbin:/sbin` だけ**で Homebrew が入らない。
  `node` 等が見えず落ちるため、リモートコマンドの先頭で
  `export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"` を明示する
- **ランナーの WORK_DIR には受け手パッケージ(Package.swift)が必要**。`install.sh --skip-project`
  は Package.swift 自体を作らないため、`remote setup` は**プロジェクト名を渡して**導入する
  必要がある。さらに**ディスパッチの rsync が先に `TestProjects/<name>/` を作ると
  install.sh のプロジェクト作成がスキップされる**(ディレクトリ存在で判定するため)ので、
  導入はディスパッチより前に済ませる
- `remote clean` の `devices down` も同じ経路で実行する(リモートの fleetest を直接叩く)
- **`ssh -tt` はリモートの stderr を stdout に合流させる**(擬似 TTY は1本の流れ)。
  `api run --runner` の stdout は NDJSON 専用の契約なので、**中継側で行を振り分ける**
  (JSON 行 = stdout / それ以外 = stderr。`RemoteRelay.isMachineReadableLine`)。
  入れないとリモートの人間向け診断が NDJSON に混入する(2026-07-31 実測・修正済み)

適合チェックは git revision + `ToolchainFingerprint`(`compose` をローカル/リモート両方が
共有し、合成規則の drift を防ぐ)の2項目。`ProtocolVersion` は独立して照合しない —
CLI 中継(`fleetest run` の起動)のみが対象で、rev 一致(= 同一 upstream コミット)に
包含されるため

`fleetest api run --runner` を実装(拡張連携用の NDJSON 中継。人間向け進行は stderr・NDJSON は
stdout を行単位でリモート→ローカルへパス書き換えして中継)。`--interactive`(`--debug`)/
`--breakpoint`/`--dry-run` 等の stdin 制御・ローカル専用系は併用不可。`ProtocolVersion` は
不変(NDJSON の形を変えていない)。

GUI(vscode-fleetest)は単一ホスト設定ではなく**複数ホスト登録+実行先選択**にした:
`fleetest.remote.hosts`(name/host/dir/session の配列。name は実行先セレクタの一意キー)と
`fleetest.remote.target`(空 = ローカル、非空 = hosts の name に一致するディスパッチ先)。
target が hosts に無い/host 未設定を指す場合は**黙ってローカル実行にフォールバックせず run を
中止する**(fleetest の resolveRemoteTarget。Fleetest.swift / ApiRunCommand.swift)。同一リモートへの同時ディスパッチはまだ
直列化していない(Phase 2 の課題のまま)。

> **2026-08-17 に実行先セレクタは廃止**(RR-13 の実装で確定した点を参照)。`fleetest.remote.target`
> という設定キーはもう無く、ディスパッチ先は**実行プロファイルの devices が持つ `machine`**
> (デバイスごとに直接指定)で決まる。登録簿は LocalConfig へ移り、`fleetest.remote.hosts` も
> 設定キーとしては存在しない(設定タブは `fleetest api remote-machines` を読み書きする)。
> `fleetest.remote.*` 形の設定キーは無い。
