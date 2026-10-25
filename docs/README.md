# 保守者向けドキュメントの索引

| 種別 | 範囲 | 読む場面 | 扱わないこと |
|---|---|---|---|
| 索引・規約 | docs/ の保守者向け文書(分割したフォルダを含む)の一覧と、その書き方 | 文書を探すとき・文書を足す/直すとき | 利用者向けの文書(→ [user-docs/index_ja.md](user-docs/index_ja.md))・作業の規則(→ CLAUDE.md) |

保守者向けの文書を、読む場面ごとに引けるように並べる。後半の「書き方」は、人と AI の両方が同じ形で
読めるようにするための規約。

## 索引

種別の意味: **索引** = フォルダの目次 / **正典** = 現在の仕様(食い違ったらこちらが正しい)/ **手順** = 作業の進め方と判定の規律 /
**台帳** = 状態を持つ項目の一覧 / **記録** = 経緯・実測・事故(現在の仕様ではない)。

### 設計と仕様

| 文書 | 種別 | 読む場面 |
|---|---|---|
| [design/README.md](design/README.md) | 索引 | 設計書のどのファイルに何があるかを探すとき(節の一覧) |
| [design/overview.md](design/overview.md) | 正典 | 全体の構成・FM 呼び出し・CLI の方針を変える前 |
| [design/bridge.md](design/bridge.md) | 正典 | ブリッジの挙動・エンドポイントを変える前 |
| [design/webview.md](design/webview.md) | 正典 | WebView / ブラウザの読み取りを変える前 |
| [design/dsl-syntax.md](design/dsl-syntax.md) | 正典 | DSL の記述・語彙・セレクタ・検証・スクロールを変える前 |
| [design/dsl-execution.md](design/dsl-execution.md) | 正典 | 失敗時の情報・実行・自己修復を変える前 |
| [design/profiles.md](design/profiles.md) | 正典 | プロファイル・実行の入口・結果の保存・配布を変える前 |
| [design/monitor.md](design/monitor.md) | 正典 | モニターの配信・回復・表示を変える前 |
| [design/response.md](design/response.md) | 正典 | レスポンス計測の定義・測り方・結果の形を確かめる/変える前 |
| [remote-runner/spec.md](remote-runner/spec.md) | 正典 | リモート実行の用語(host・machine)とセキュリティ前提を確かめる/変えるとき |
| [remote-runner/01-11.md](remote-runner/01-11.md) | 正典 | リモート実行の基本設計(方針・構成・版整合・分散)を変える前 |
| [remote-runner/13.md](remote-runner/13.md) | 正典 | フリート実行・監視の fan-out を変える前 |
| [remote-runner/14-16.md](remote-runner/14-16.md) | 正典 | ランナー機の導入や運用コマンドを変える前 |
| [remote-runner/17.md](remote-runner/17.md) | 正典 | リモート制御・スクリプト・サービスを変える前 |
| [remote-runner/18-22.md](remote-runner/18-22.md) | 正典 | 共有の規律やマシン設定を変える前 |
| [commands.md](commands.md) | 正典 | DSL コマンドの引数・挙動を確かめる/変えるとき(読者は利用者。user-docs と併せて直す) |
| [results-json.md](results-json.md) | 正典 | 結果 JSON のスキーマを読む/変えるとき(唯一の定義元) |
| [framework-differences.md](framework-differences.md) | 正典 | UI フレームワークで挙動が割れる変更を入れるとき(表に1行足す) |
| [shirates-parity.md](shirates-parity.md) | 正典 | コマンドを足す・改名する・持たないと決めるとき |

### 作業の手順

| 文書 | 種別 | 読む場面 |
|---|---|---|
| [verification/README.md](verification/README.md) | 索引 | 検証の罠と規律の節を探すとき |
| [verification/environment.md](verification/environment.md) | 手順 | E2E を回す前・OS や Xcode を上げた後 |
| [verification/judgment.md](verification/judgment.md) | 手順 | flake・性能を判定するとき・A/B を取るとき |
| [verification/detection-and-tests.md](verification/detection-and-tests.md) | 手順 | 検知やテストを足すとき・切り分けるとき |
| [verification/traps.md](verification/traps.md) | 手順 | 画面や操作の不具合を調べるとき |
| [verification/triage.md](verification/triage.md) | 手順 | テストが全滅したとき・実機や録画を検証するとき |
| [performance-tuning/README.md](performance-tuning/README.md) | 索引 | 性能の節を探すとき |
| [performance-tuning/guide.md](performance-tuning/guide.md) | 手順 | 速さに手を入れる前(不採用の施策を先に読む) |
| [performance-tuning/breakdown-1.md](performance-tuning/breakdown-1.md) | 手順 | 特定の操作の所要に手を入れる前(時間の内訳の前半) |
| [performance-tuning/breakdown-2.md](performance-tuning/breakdown-2.md) | 手順 | 特定の操作の所要に手を入れる前(時間の内訳の後半) |
| [development.md](development.md) | 手順 | クローン直後のビルド・どこに何があるかを探すとき |
| [releasing.md](releasing.md) | 手順 | リリースタグを打つとき |
| [sut-framework-upgrade.md](sut-framework-upgrade.md) | 手順 | SUT の Flutter・RN・CMP の版を上げるとき |
| [remote-runner-setup.md](remote-runner-setup.md) | 手順 | ランナー機を用意するとき |
| [ci.md](ci.md) | 手順 | CI で回す構成を案内する/直すとき |
| [mcp-audit-rounds.md](mcp-audit-rounds.md) | 手順 | 実アプリで MCP(`ft_*`)の欠陥を拾う監査を回すとき |

### 台帳

| 文書 | 種別 | 読む場面 |
|---|---|---|
| [open-issues.md](open-issues.md) | 台帳 | 未解決の不具合の候補を探す/足す/直したら消すとき |

### 記録

| 文書 | 種別 | 読む場面 |
|---|---|---|
| [maintainer-notes/README.md](maintainer-notes/README.md) | 索引 | 事故台帳の節を探すとき(全節の一覧) |
| [maintainer-notes/001-004.md](maintainer-notes/001-004.md) | 記録 | 規則を緩めたく/消したくなったとき・同じ型の判断をするとき(MN-1〜4) |
| [maintainer-notes/005-041.md](maintainer-notes/005-041.md) | 記録 | 規則を緩めたく/消したくなったとき・同じ型の判断をするとき(MN-5〜41) |
| [maintainer-notes/042-056.md](maintainer-notes/042-056.md) | 記録 | 規則を緩めたく/消したくなったとき・同じ型の判断をするとき(MN-42〜56) |
| [maintainer-notes/057-073.md](maintainer-notes/057-073.md) | 記録 | 規則を緩めたく/消したくなったとき・同じ型の判断をするとき(MN-57〜73) |
| [maintainer-notes/074-088.md](maintainer-notes/074-088.md) | 記録 | 規則を緩めたく/消したくなったとき・同じ型の判断をするとき(MN-74〜88) |
| [maintainer-notes/089-106.md](maintainer-notes/089-106.md) | 記録 | 規則を緩めたく/消したくなったとき・同じ型の判断をするとき(MN-89〜106) |
| [remote-runner/README.md](remote-runner/README.md) | 索引 | リモート実行の設計の節を探すとき |
| [remote-runner/records.md](remote-runner/records.md) | 記録 | リモート実行の未検証事項・作業計画・初期の罠を確かめるとき |
| [design/history.md](design/history.md) | 記録 | 設計の経緯や過去に踏んだ実装の罠を確かめるとき |
| [performance-tuning/records.md](performance-tuning/records.md) | 記録 | 過去の実測を確かめるとき |
| [verification/resolved.md](verification/resolved.md) | 記録 | 直した不具合と同じ型の症状を調べるとき |
| [sandbox-seatbelt.md](sandbox-seatbelt.md) | 記録 | シナリオのサンドボックスに許可を足す/調べるとき |
| [response-measurement.md](response-measurement.md) | 記録 | レスポンス計測の試作の実測を確かめるとき |
| [poc-fm-occlusion-guard.md](poc-fm-occlusion-guard.md) | 記録 | テキストの可視性検証(FM)の判定の根拠を確かめるとき |

## 書き方

### ファイルの冒頭

H1 の直後に次の表を置き、その下に1〜2文の導入を書く(このファイルの冒頭が見本)。

| 種別 | 範囲 | 読む場面 | 扱わないこと |
|---|---|---|---|

- **種別**は「索引」の冒頭に挙げた5つから選ぶ(「索引」はフォルダの目次だけに使う)。正典と記録を1ファイルに混ぜない
- **扱わないこと**には参照先を書く(読み手が別のファイルへ移れるように)

### 大きさ

- 1ファイル約1,500行以下(AI が1回で読めて、他のファイルを読む余地が残る大きさ)。超えたら領域で分割する
- 1,000行を超えるファイルは、冒頭の導入の下に節の一覧(ID と見出し)を置く

### 節の ID

- 参照される節の見出しは `## <接頭辞>-<番号> <意味の読める見出し>` と書く(例: `## MN-0 残ったシステムアラートの消し方`)
- 参照は ID で書き、人のために短い名前を添える: `MN-0(アラートの消し方)`。リンクにするときはファイルまで
  (`[MN-0](maintainer-notes/README.md)`)とし、見出しのアンカーは使わない(見出しを直すと切れる)
- ID はファイルを分割・移動しても変えない。番号は再利用しない
- 番号 0(`MN-0` 等)は例示用に予約し、定義しない(検査も対象外)
- 文書名の無い `§N` は書かない(どの文書の節か grep で決まらない)

接頭辞(この表が唯一の定義元。`docsIndex.test.mjs` がここを読み、定義の無い ID・重複した定義を落とす):

| 接頭辞 | 文書 |
|---|---|
| `MN` | maintainer-notes |
| `DS` | design |
| `RR` | remote-runner |
| `PT` | performance-tuning |
| `FD` | framework-differences |
| `SB` | sandbox-seatbelt |
| `RM` | response-measurement(試作の記録)と design/response(現行の設計) |
| `OG` | poc-fm-occlusion-guard |
| `OI` | open-issues |

### 正典と記録

- 正典には現在の仕様だけを書く。マイルストーン・廃止した機能の記述・見出しの日付を置かない。
  決定の出所は `決定: ユーザー 2026-10-20` の形で添えてよい
- 記録には日付と、その時点の状態を書く(現在の仕様として読まれないように)
- 同じ事実は1箇所に置き、他の文書からは ID で参照する

### 台帳の項目

各項目に次の2行を置く(人は一覧で見渡せ、AI は grep で拾える)。

```
- 状態: 推測 | 経路確定 | 再現済み | 据え置き(直さないと決めたもの)
- 確認: <コミット>(<日付>)  ← コミットが分からなければ「コミット未記録(<日付>)」。日付も無ければ「日付未記録」
```
