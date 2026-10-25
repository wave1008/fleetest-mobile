# 設計書(目次)

| 種別 | 範囲 | 読む場面 | 扱わないこと |
|---|---|---|---|
| 索引 | 設計書の各ファイルと節の一覧 | 節を探すとき | — |

設計の正典。history.md だけは記録(経緯と実装で得た知見)。

### [overview.md](overview.md) — 設計: 背景・全体構成・FM 呼び出し・CLI

- DS-1 背景と方針
- DS-2 全体アーキテクチャ
- DS-3 リポジトリ構成
- DS-5 FM 呼び出し層(FTFoundationModels)設計
- DS-6 CLI UX
- DS-9 検証方法(E2E)

### [bridge.md](bridge.md) — 設計: アプリ操作ブリッジ

- DS-4 アプリ操作ブリッジ(自作)設計
- DS-16 エミュレータ操作の gRPC 制御

### [webview.md](webview.md) — 設計: WebView とブラウザの中身

- DS-19 木はどこから来るか(WebView / ブラウザの一覧)
- DS-20 ブラウザの中身は DOM から読む
- DS-21 Android の自作アプリの WebView も DOM から読む

### [dsl-syntax.md](dsl-syntax.md) — 設計: Swift DSL の記述と語彙

- DS-10 Swift DSL

### [dsl-execution.md](dsl-execution.md) — 設計: Swift DSL の実行・失敗時の情報・自己修復

- DS-17 テストベースからのシナリオ下書き生成

### [profiles.md](profiles.md) — 設計: テストプロジェクト・プロファイル・結果・配布

- DS-11 テストプロジェクトと実行プロファイル
- DS-13 実行の相乗りガードと launch 事前検査
- DS-14 実行結果のファイルベース DB
- DS-15 外部パッケージ配布と mint 配布の履歴

### [monitor.md](monitor.md) — 設計: デバイスモニター

- DS-12 デバイスモニターの画面配信と自己修復
- DS-18 デバイスモニターの run ボード(フリート横断の実行状況)

### [response.md](response.md) — 設計: レスポンス計測

- RM-1 何を測るか
- RM-5 t1・t2 の測り方
- RM-8 製品化の形

### [history.md](history.md) — 設計の経緯と実装で得た知見

- DS-7 マイルストーン
- DS-8 リスクと対策
- DS-8.5 M2(FM 探索)は廃止済み
- DS-8.6 M3実装で得た知見
- DS-8.7 M4実装で得た知見(Android)
- DS-8.8 並列実行の実装知見
- DS-22 FM ヒールの実装で得た知見と撤去の理由
- DS-23 Swift DSL の実装で得た知見
