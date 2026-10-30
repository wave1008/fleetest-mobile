// 受け手パッケージの `.claude/settings.json` の Bash 許可リストを補修する
// (fleetest api ensure-settings)。install.sh が**毎回**呼ぶ。
//
// なぜ独立したコマンドが要るか: 許可リストは `fleetest init` でしか書かれず、更新は
// `--skip-project`(init を回さない)で走るため、**許可エントリを増やしても既存の受け手には
// 一生届かなかった**。エントリの実装は ProjectScaffold.writeClaudeSettings ただ1つに保つ。

import ArgumentParser
import Foundation
import FTCore

struct ApiEnsureSettingsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ensure-settings",
        abstract: "Top up the fleetest-related Bash permissions in the consumer package .claude/settings.json (idempotent)")

    @Option(help: "Root of the consumer package (where TestProjects/ lives; defaults to the current directory)")
    var workDir: String?

    @Option(help: "Location of the fleetest-mobile clone (used for the absolute paths of the allowed commands)")
    var toolRoot: String?

    /// 書く前に断る: 存在しない --work-dir はフォルダごと作って書いてしまい、空/相対の --tool-root は
    /// `Bash(/.build/debug/fleetest:*)` のような別物の許可を書く
    static func validate(workDir: String?, toolRoot: String?) throws {
        if let workDir {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: workDir, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ValidationError("--work-dir is not an existing directory: \(workDir)")
            }
        }
        if let toolRoot, !toolRoot.hasPrefix("/") {
            throw ValidationError("--tool-root must be an absolute path (the fleetest-mobile clone), got: \"\(toolRoot)\"")
        }
    }

    func run() async throws {
        try Self.validate(workDir: workDir, toolRoot: toolRoot)
        let root = URL(fileURLWithPath: workDir ?? FileManager.default.currentDirectoryPath)
        let settingsURL = root.appendingPathComponent(".claude/settings.json")
        let added = try ProjectScaffold.writeClaudeSettings(packageRoot: root, toolRoot: toolRoot)
        // 画面に出るのは呼び出し元(install.sh)の1行だけなので短く。中身は settings.json にある。
        // 解析できない settings.json は writeClaudeSettings が飛ばして [] を返す = 「最新」と区別できないので、ここで見分ける
        if added.isEmpty, FileManager.default.fileExists(atPath: settingsURL.path),
           !((try? JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL))) is [String: Any]) {
            ConsoleOut.out(".claude/settings.json was not updated (it is not a JSON object; fix it and run this again)")
        } else if added.isEmpty {
            ConsoleOut.out(".claude/settings.json is up to date (nothing added)")
        } else {
            ConsoleOut.out("Added \(added.count) entr\(added.count == 1 ? "y" : "ies") (.claude/settings.json)")
        }
    }
}
