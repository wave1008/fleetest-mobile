// 他の AppDriver を包んで hideKeyboard を中身へ渡す型は、hideKeyboardIfShown も中身へ渡す(渡さないと既定実装 =
// 「送った」の true に落ち、Android で何も送らなかった hideKeyboard を MCP が「送った」と言い下書きに残す)。
// ソースを走査して「中身への hideKeyboard の転送がある型(ファイル)は hideKeyboardIfShown も持つ」ことを固定する。

import XCTest

final class HideKeyboardIfShownForwardingTests: XCTestCase {
    func testEveryWrapperThatForwardsHideKeyboardAlsoForwardsTheReportingForm() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        // 中身の名前に縛らない(`<何か>.hideKeyboard()` = 他の AppDriver への転送)。`client.` は HTTP のブリッジクライアント
        // (AppDriver ではない = 包む型ではない)。hideKeyboard を自分で宣言する型(ファイル)だけが包む側
        let forwarding = try NSRegularExpression(pattern: #"[\w$)\]](?<!client)\.hideKeyboard\(\)"#)
        let implementsHideKeyboard = try NSRegularExpression(pattern: #"func\s+hideKeyboard\s*\(\s*\)"#)
        // 宣言を見る(呼び出しの文字列やコメントでは通さない)
        let declaration = try NSRegularExpression(pattern: #"func\s+hideKeyboardIfShown\s*\("#)
        var checked: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        for file in files {
            let code = Self.strippingComments(try String(contentsOf: file, encoding: .utf8))
            let range = NSRange(code.startIndex..., in: code)
            guard implementsHideKeyboard.firstMatch(in: code, range: range) != nil,
                  forwarding.firstMatch(in: code, range: range) != nil else { continue }
            checked.append(file.lastPathComponent)
            XCTAssertNotNil(declaration.firstMatch(in: code, range: range),
                            "\(file.lastPathComponent) は hideKeyboard を中身へ渡すのに hideKeyboardIfShown を渡していない")
        }
        // 走査が包む型に届いていること(0 件の素通しを防ぐ。ActionCountingDriver は hideKeyboard を hideKeyboardIfShown へ寄せたので数に入らない)
        XCTAssertGreaterThanOrEqual(checked.count, 5, "\(checked)")
    }

    /// 行コメント(`//` 以降)と `/* */` を落とす(文字列リテラル中の `//` は気にしない = 走査が落ちる側に倒れるだけ)
    static func strippingComments(_ code: String) -> String {
        let noBlocks = code.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        return noBlocks.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
            .joined(separator: "\n")
    }
}
