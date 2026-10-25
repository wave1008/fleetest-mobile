# 環境

[in English](environments.md)

## 対応環境

### 利用者が用意してインストールするもの

| 対象 | 要件 |
|---|---|
| マシンと OS | Apple silicon の Mac、macOS 26+ |
| Xcode | Xcode 27.2+(<https://apps.apple.com/jp/app/xcode/id497799835>) |
| Homebrew | Homebrew(<https://brew.sh/ja/>) |
| VSCode | VSCode(<https://code.visualstudio.com/docs/setup/mac>) |
| Android SDK | Android SDK(adb・Command-line Tools)(Android をテストする場合)(<https://developer.android.com/studio/install?hl=ja>)。Emulator を作るには Java が要ります(Android Studio 同梱の Java か JDK。どちらも無いと `--auto-device` が失敗します) |
| AIアシスタント | MCP に対応したもの。動作確認済みは Claude Code・Codex。他(Cline・Cursor・Copilot 等)は [Claude Code 以外の AIアシスタント](../reference/tools/other_agents_ja.md) |

管理者権限が要るのは Xcode のライセンス同意と Homebrew の導入だけです(AIアシスタントは代行しません)。

### 自動でインストールされるもの

- Node.js
- VSCode 拡張(fleetest mobile)
- iOS Simulator のランタイムと Simulator
- Android のシステムイメージと Emulator

### オプション：Foundation Models (FM)

FM は macOS 26+ で使えます(システム設定 → Apple Intelligence と Siri)。**画像を渡す機能(`screenLooksLike`・テキストの可視性検証の FM 段)だけは macOS 27+** です(システム設定 → Siri)。

FM を使う機能は experimental です(OS の更新で挙動が変わることがあります)。

## サポートする UI フレームワーク

| フレームワーク | 対象 OS |
|---|---|
| SwiftUI / UIKit | iOS |
| Compose Multiplatform | iOS, Android |
| Flutter | iOS, Android |
| React Native | iOS, Android |
| View/XML | Android |

<br>

次へ: [クイックスタート](../quick-start_ja.md)

### Link
- [index](../index_ja.md)
