# 開発環境とリポジトリ構成

| 種別 | 範囲 | 読む場面 | 扱わないこと |
|---|---|---|---|
| 手順 | 本体を改造するためのビルド手順・リポジトリの構成・全体の構造 | クローン直後・どこに何があるかを探すとき | 利用者の導入(→ [user-docs/quick-start_ja.md](user-docs/quick-start_ja.md))・設計の詳細(→ [design/](design/README.md))・検証の規律(→ CLAUDE.md「ビルド・検証」・[verification/](verification/README.md)) |

fleetest 本体を改造する保守者向けの、最初の一歩と地図。設計の判断はここに書かず design/ に置く。

## ビルド

```bash
swift build                    # 全プロダクト(fleetest・fleetest-mcp・配信ヘルパー等)
swift run fleetest doctor      # FM・Xcode・Simulator・adb の事前診断。詰まったら随時
```

- VSCode 拡張: `cd vscode-fleetest && npm install && npm run install-local`(反映は Reload Window)。
  Node.js は Homebrew の `node@26` に固定する(`Scripts/install.sh` の `NODE_FORMULA` が定義元)。拡張の開発は
  [vscode-fleetest/README.md](../vscode-fleetest/README.md)
- Android の常駐ブリッジ APK: `bash AndroidRunner/build.sh`(adb が PATH に無ければ `ANDROID_HOME` を設定)
- macOS ベータでは Xcode を同じベータへ揃えてフルリビルドする(FoundationModels の ABI 不整合で全バイナリが dyld で落ちる)
- `TestProjects/` を手で持ち込んだら `swift run fleetest project sync`(Package.swift のマーカー区間を再生成)
- `swift run` は毎回 SwiftPM の確認で約1.6秒上乗せされる。連続実行は `.build/debug/fleetest` を直接呼ぶ
- テスト・E2E の回し方と範囲は CLAUDE.md「ビルド・検証」

## 全体の構造

```
fleetest CLI / MCP ──(サブプロセス)──▶ fleetest-scenarios-<project>(シナリオを発見・実行)
      │                                        │  FTDSL / FTFoundationModels / FTCore
      ├─ HTTP ──▶ iOS: in-app ブリッジ(InAppBridge/)+ XCUITest ブリッジ(Runner/)
      └─ adb forward ──▶ Android: 常駐ブリッジ(AndroidRunner/)
```

- プラットフォーム境界は `AppDriver` プロトコルだけ。FM 呼び出しと再生器は iOS / Android で共通
- iOS のモード(`inapp` / `xcuitest`)とブリッジの関係は design/

## リポジトリ構成

```
Sources/
  fleetest/               CLI(swift-argument-parser)
  fleetest-mcp/           MCP サーバー(stdio / JSON-RPC)
  fleetest-simstream/     iOS Simulator 画面の配信(変化駆動で JPEG)
  fleetest-androidstream/ Android 画面の配信(iOS 版とフレームプロトコル互換)
  fleetest-devicepoll/    実機の画面配信(定間隔スクリーンショット)
  fleetest-services/      compose.yaml のサービス操作の中継
  FTDSL/                  Swift DSL(コマンド・セレクタ式・発見・レポート・ロケータの指紋)
  FTDSLMacros/            @TestClass / @Test マクロ(swift-syntax はここに閉じる)
  FTScenarioRunner/       fleetest-scenarios-<project> の CLI(list / run・NDJSON)
  FTCore/                 ステップモデル・AppDriver・StepExecutor・プロジェクト/プロファイル(FM 非依存)
  FTCoreSimShim/          CoreSimulator の私有 API を叩くシム(使えなければ simctl へ)
  FTFoundationModels/     FM 呼び出し(テキストの可視性検証・screenLooksLike・下書き)
  FTBridgeClient/         iOS ブリッジの HTTP クライアントと供給
  FTAndroid/              Android ドライバ
  FTEmulatorGrpc/         Android Emulator の gRPC 制御(失敗時は adb へ)
  FTRemote/               リモート実行の純粋ロジック
  FTServices/             compose.yaml のサービス宣言
  FTTestSupport/          テスト専用(共有資源ロック・実アプリ固定コーパス)
InAppBridge/   iOS の in-app ブリッジ(アプリに注入する dylib)
Runner/        iOS の XCUITest ブリッジ
AndroidRunner/ Android の常駐ブリッジ
E2EApp*/ E2EXApp*/ E2EYApp*/   fleetest 自身の E2E の SUT(CLAUDE.md「fleetest 自身の E2E」)
TestProjects/  テストプロジェクト(SUT のシナリオを含む。ユーザー資産)
SampleApp/     検証用 SwiftUI デモアプリ
Bench/         MCP のベンチマーク
Scripts/       導入・更新・E2E・リリースのスクリプト
vscode-fleetest/  VSCode 拡張
docs/          保守者向け文書(索引は docs/README.md)と利用者向け文書(docs/user-docs/)
```
