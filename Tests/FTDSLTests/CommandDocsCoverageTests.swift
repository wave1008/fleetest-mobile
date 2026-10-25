import XCTest
import FTCore

/// 索引(`DSLCommandIndex.all`)の全コマンドが、docs/commands.md(正典)と user-docs のリファレンス(英・日)の
/// **両方**に載っていることを守る。DSL の説明は2箇所に持つので、コマンドを足して片方だけ書くと黙って欠ける。
/// 名前はバッククォートの中から拾い、docs の3つの書き方を展開する:
/// 末尾の差し替え `flickCenterToTop/Bottom` / 接尾辞 `thisContains(Not)` / メンバー呼び出し `element.memoTextAs(key)`。
final class CommandDocsCoverageTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func read(_ rel: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(rel), encoding: .utf8)
    }

    /// user-docs/reference 配下の .md を言語ごとに連結する
    private static func userDocsReference(japanese: Bool) throws -> String {
        let dir = repoRoot.appendingPathComponent("docs/user-docs/reference")
        let urls = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "md" } ?? []
        return try urls.filter { $0.lastPathComponent.hasSuffix("_ja.md") == japanese }
            .map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    /// バッククォートの中に書かれたコマンド名の集合(3つの書き方を展開する)
    static func documentedNames(in text: String) -> Set<String> {
        var names = Set<String>()
        let spans = text.matches(of: /`([^`\n]+)`/).map { String($0.1) }
        for span in spans {
            for m in span.matches(of: /([A-Za-z_][A-Za-z0-9_.]*)((?:\/[A-Z][A-Za-z0-9]*)*)(?:\(([A-Z][A-Za-z]*)\))?/) {
                let word = String(m.1)
                var bases = [word]
                if let dot = word.lastIndex(of: ".") { bases.append(String(word[word.index(after: dot)...])) }
                // 末尾の差し替え: 先頭の名前の大文字の切れ目より後ろを各候補で置き換える
                let alts = m.2.split(separator: "/").map(String.init)
                for base in bases {
                    names.insert(base)
                    for alt in alts {
                        for i in base.indices where base[i].isUppercase {
                            names.insert(String(base[..<i]) + alt)
                        }
                    }
                    if let suffix = m.3 { names.insert(base + suffix) }
                }
            }
        }
        return names
    }

    private func missing(from text: String) -> [String] {
        let documented = Self.documentedNames(in: text)
        return DSLCommandIndex.all.map(\.name)
            .filter { !DSLCommandIndex.internalNames.contains($0) && !documented.contains($0) }
    }

    func testEveryCommandIsInCommandsMd() throws {
        XCTAssertEqual(missing(from: try Self.read("docs/commands.md")), [],
                       "docs/commands.md に載っていないコマンド(索引に足したら commands.md と user-docs の両方へ書く)")
    }

    func testEveryCommandIsInUserDocsReference() throws {
        XCTAssertEqual(missing(from: try Self.userDocsReference(japanese: false)), [],
                       "docs/user-docs/reference(英)に載っていないコマンド")
        XCTAssertEqual(missing(from: try Self.userDocsReference(japanese: true)), [],
                       "docs/user-docs/reference(日)に載っていないコマンド")
    }

    /// 走査が索引と文書に届いていること(空の索引・空の文書で素通りする形を落とす)
    func testScanReachesIndexAndDocs() throws {
        XCTAssertGreaterThan(DSLCommandIndex.all.count, 100)
        XCTAssertGreaterThan(Self.documentedNames(in: try Self.read("docs/commands.md")).count, 100)
        XCTAssertGreaterThan(Self.documentedNames(in: try Self.userDocsReference(japanese: true)).count, 100)
    }

    func testDocumentedNamesExpandsTheThreeForms() {
        let names = Self.documentedNames(in: """
            | `flickCenterToTop/Bottom(scrollFrame:)` | `flickLeftToRight/RightToLeft()` | `thisContains(Not)` |
            `element.memoTextAs(key)` / `TestLog.directoryForLog` / `tap("#a")`
            """)
        for n in ["flickCenterToTop", "flickCenterToBottom", "flickLeftToRight", "flickRightToLeft",
                  "thisContains", "thisContainsNot", "memoTextAs", "TestLog.directoryForLog", "tap"] {
            XCTAssertTrue(names.contains(n), n)
        }
        // バッククォートの外の名前は数えない
        XCTAssertFalse(Self.documentedNames(in: "swipeUp は `tap` と違う").contains("swipeUp"))
    }
}
