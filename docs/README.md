# 保守者向けドキュメントの索引

| 種別 | 範囲 | 読む場面 | 扱わないこと |
|---|---|---|---|
| 索引・規約 | docs/ 直下の保守者向け文書の一覧と、その書き方 | 文書を探すとき・文書を足す/直すとき | 利用者向けの文書(→ [user-docs/index_ja.md](user-docs/index_ja.md))・作業の規則(→ CLAUDE.md) |

保守者向けの文書を、読む場面ごとに引けるように並べる。後半の「書き方」は、人と AI の両方が同じ形で
読めるようにするための規約。

## 索引

種別の意味: **正典** = 現在の仕様(食い違ったらこちらが正しい)/ **手順** = 作業の進め方と判定の規律 /
**台帳** = 状態を持つ項目の一覧 / **記録** = 経緯・実測・事故(現在の仕様ではない)。

### 設計と仕様

| 文書 | 種別 | 読む場面 |
|---|---|---|
| [design.md](design.md) | 正典 | アーキテクチャ・ブリッジ・DSL・セレクタ・プロファイル・モニターの設計を変える前 |
| [commands.md](commands.md) | 正典 | DSL コマンドの引数・挙動を確かめる/変えるとき(読者は利用者。user-docs と併せて直す) |
| [results-json.md](results-json.md) | 正典 | 結果 JSON のスキーマを読む/変えるとき(唯一の定義元) |
| [framework-differences.md](framework-differences.md) | 正典 | UI フレームワークで挙動が割れる変更を入れるとき(表に1行足す) |
| [shirates-parity.md](shirates-parity.md) | 正典 | コマンドを足す・改名する・持たないと決めるとき |

### 作業の手順

| 文書 | 種別 | 読む場面 |
|---|---|---|
| [development.md](development.md) | 手順 | クローン直後のビルド・どこに何があるかを探すとき |
| [verification.md](verification.md) | 手順 | E2E・flake・性能の判定に迷うとき・全滅時の切り分け |
| [performance-tuning.md](performance-tuning.md) | 手順 | 速さに手を入れる前(不採用の施策と再検討の条件を先に読む) |
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
| [maintainer-notes.md](maintainer-notes.md) | 記録 | CLAUDE.md の規則を緩めたく/消したくなったとき・同じ型の設計判断をするとき |
| [remote-runner.md](remote-runner.md) | 記録 | リモート実行(SSH ディスパッチ・監視・ロックと待機列・占有)の設計を変える前 |
| [sandbox-seatbelt.md](sandbox-seatbelt.md) | 記録 | シナリオのサンドボックスに許可を足す/調べるとき |
| [response-measurement.md](response-measurement.md) | 記録 | レスポンス計測の設計を変えるとき |
| [poc-fm-occlusion-guard.md](poc-fm-occlusion-guard.md) | 記録 | テキストの可視性検証(FM)の判定の根拠を確かめるとき |
| [driver-improvements-verification.md](driver-improvements-verification.md) | 記録 | ドライバ改良の効果の実測を確かめるとき |

## 書き方

### ファイルの冒頭

H1 の直後に次の表を置き、その下に1〜2文の導入を書く(このファイルの冒頭が見本)。

| 種別 | 範囲 | 読む場面 | 扱わないこと |
|---|---|---|---|

- **種別**は索引と同じ4つから選ぶ。正典と記録を1ファイルに混ぜない
- **扱わないこと**には参照先を書く(読み手が別のファイルへ移れるように)

### 大きさ

- 1ファイル約1,500行以下(AI が1回で読めて、他のファイルを読む余地が残る大きさ)。超えたら領域で分割する
- 1,000行を超えるファイルは、冒頭の導入の下に節の一覧(ID と見出し)を置く

### 節の ID

- 参照される節の見出しは `## <接頭辞>-<番号> <意味の読める見出し>` と書く(例: `## MN-0 残ったシステムアラートの消し方`)
- 参照は ID で書き、人のために短い名前を添える: `MN-0(アラートの消し方)`。リンクにするときはファイルまで
  (`[MN-0](maintainer-notes.md)`)とし、見出しのアンカーは使わない(見出しを直すと切れる)
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
| `VF` | verification |
| `FD` | framework-differences |
| `SB` | sandbox-seatbelt |
| `RM` | response-measurement |
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
