# fleetest mobile

[English](README.md)

**fleetest mobile** は、Claude Code などの AIアシスタントから使うことを前提にした、iOS / Android アプリの
E2E テストツールです。macOS で動きます。

- **fleet** — 手元とリモートの Mac にまたがる Simulator・Emulator・実機のフリートで並列に実行する
- **fleetest** — ドライバを速さに合わせて調整してあり、1台でも並列でも速い
- **free** — オープンソースで、自分の Mac だけで完結するのでテストの実行は無料

**AI がテストを作り、コードが決定的に再生する。** AIアシスタントが fleetest の MCP サーバーと CLI で
アプリを操作し、Swift DSL のテストコードを書きます。テストコードは LLM なしで実行されるので、速く安定し、
CI に向きます。すべてを手元で動かせるので、クラウドを使えない組織でも選べます。

## 必要環境

- Apple silicon の Mac、macOS 26+
- Xcode 27.2+
- Homebrew
- VSCode
- Android SDK(Android をテストする場合)
- MCP 対応の AIアシスタント(Claude Code・Codex で確認)
- Apple Intelligence(Foundation Models)は任意

詳細: [環境](docs/user-docs/overview/environments_ja.md)

## インストール

テスト用の新しいフォルダを VSCode で開き、AIアシスタントを起動して次のように指示します。

```text
https://github.com/wave1008/foundation-tester をこのフォルダの隣に clone して、
../foundation-tester/.claude/skills/fleetest-setup/SKILL.md の手順でセットアップして。
```

サンプルアプリでの実行までの手順は[クイックスタート](docs/user-docs/quick-start_ja.md)にあります。

## ドキュメント

| やりたいこと | 入口 |
|---|---|
| 自分のアプリで fleetest を使う | [利用者向けドキュメント](docs/user-docs/index_ja.md)([English](docs/user-docs/index.md)) |
| DSL コマンドを調べる | [関数/プロパティ](docs/user-docs/index_ja.md#関数プロパティ)([全コマンドの仕様(日本語)](docs/commands.md)) |
| fleetest 本体を改造する | [CLAUDE.md](CLAUDE.md)(規則)・[docs/README.md](docs/README.md)(保守者向け文書の索引)・[docs/development.md](docs/development.md)(ビルドとリポジトリ構成) |

## 4つのインターフェース

| インターフェース | できること |
|---|---|
| CLI | テストの実行を操作するコマンド([リファレンス](docs/user-docs/reference/tools/cli_ja.md)) |
| VSCode 拡張 | シナリオの実行・デバッグ、デバイスモニター、結果ダッシュボード([リファレンス](docs/user-docs/reference/tools/vscode_extension_ja.md)) |
| MCP サーバー | AIアシスタントがデバイスを操作して、アプリを探索し、テストを書いたり直したりする([リファレンス](docs/user-docs/reference/tools/mcp_server_ja.md)) |
| Swift DSL | テストコードを書くための関数群([リファレンス](docs/user-docs/reference/testclass/testcode_structure_ja.md)) |

## ライセンス

[LICENSE](LICENSE)
