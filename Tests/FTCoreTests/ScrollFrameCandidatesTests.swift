import XCTest
@testable import FTCore

/// `scrollFrame:` 候補の列挙。**デバイスを必要としない層**なので、ここで落とせない誤りは
/// エージェントに嘘を返す形(= 存在しない容器を勧める・分からないのに「無い」と言う)で表に出る。
final class ScrollFrameCandidatesTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 400, height: 800)

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: screen,
                         elements: elements, truncatedCount: 0)
    }

    private func element(_ ref: Int, type: String = "other", id: String? = nil,
                         label: String? = nil, frame: FTRect, scrollable: Bool? = nil,
                         depth: Int = 1) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: nil,
                    placeholder: nil, enabled: true, frame: frame, depth: depth,
                    scrollable: scrollable)
    }

    // MARK: - candidates

    func testDeclaredScrollableIsACandidateWithItsIdSelector() {
        let snap = snapshot([
            element(1, id: "list_rows", frame: FTRect(x: 0, y: 100, width: 400, height: 500),
                    scrollable: true),
            element(2, id: "header", frame: FTRect(x: 0, y: 0, width: 400, height: 100)),
        ])
        let found = ScrollFrameCandidates.candidates(in: snap)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.selector, "#list_rows")
        XCTAssertEqual(found.first?.ref, 1)
    }

    /// 申告できないブリッジ(Compose/Flutter の in-app)は全要素が nil。
    /// **「候補なし」ではなく「分からない」**なので、黙る側に倒れていることを固定する
    func testBridgeThatCannotDeclareScrollableYieldsNothingAndNoNote() {
        let snap = snapshot([
            element(1, id: "list_rows", frame: FTRect(x: 0, y: 100, width: 400, height: 500)),
            element(2, id: "row_1", frame: FTRect(x: 0, y: 110, width: 400, height: 40), depth: 2),
        ])
        XCTAssertTrue(ScrollFrameCandidates.candidates(in: snap).isEmpty)
        XCTAssertNil(ScrollFrameCandidates.note(snap))
    }

    /// Flutter の Android: id は同じ枠の包み(other)にあり、送る scrollView には無い。包みの id で指せる
    /// (`scrollFrame:` は指した要素の枠で容器を決める)ので、「id が無い・ref を渡せ」と言わない
    func testAnIdOnTheSameFrameWrapperNamesTheScrollableThatHasNone() {
        let carousel = FTRect(x: 0, y: 620, width: 400, height: 80)
        let snap = snapshot([
            element(1, id: "list_rows", frame: FTRect(x: 0, y: 100, width: 400, height: 500)),
            element(2, type: "scrollView", frame: FTRect(x: 0, y: 100, width: 400, height: 500), scrollable: true),
            element(3, id: "carousel_tags", frame: carousel),
            element(4, type: "scrollView", frame: carousel, scrollable: true),
        ])
        let found = ScrollFrameCandidates.candidates(in: snap)
        XCTAssertEqual(found.map(\.selector), ["#list_rows", "#carousel_tags"])
        XCTAssertEqual(StepExecutor.directionMatchedScrollFrameCandidate(in: snap, vertical: false), "#carousel_tags")
        XCTAssertFalse(ScrollFrameCandidates.note(snap)?.contains("no id") ?? true, ScrollFrameCandidates.note(snap) ?? "-")
    }

    /// 送る本体どうしの統合が先: 同じ枠の包みに id があっても、スクロールする子に名前があればそちら
    func testTheScrollingChildsOwnNameWinsOverTheWrapper() {
        let frame = FTRect(x: 0, y: 100, width: 400, height: 500)
        let snap = snapshot([
            element(1, id: "WebView", frame: frame),
            element(2, type: "scrollView", frame: frame, scrollable: true),
            element(3, type: "collectionView", id: "StartPageCollectionView", frame: frame, scrollable: true),
            element(4, type: "scrollView", frame: FTRect(x: 0, y: 620, width: 400, height: 80), scrollable: true),
        ])
        XCTAssertEqual(ScrollFrameCandidates.candidates(in: snap).first?.selector, "#StartPageCollectionView")
    }

    /// 同じ id の包みが2つ並ぶときは、借りた名前にも添字と枠を付ける(どちらを指すか分からない並びにしない)
    func testBorrowedDuplicateNamesKeepTheirIndex() throws {
        let a = FTRect(x: 0, y: 100, width: 400, height: 60), b = FTRect(x: 0, y: 400, width: 400, height: 60)
        let snap = snapshot([
            element(1, id: "cards", frame: a), element(2, type: "scrollView", frame: a, scrollable: true),
            element(3, id: "cards", frame: b), element(4, type: "scrollView", frame: b, scrollable: true),
        ])
        let note = try XCTUnwrap(ScrollFrameCandidates.note(snap))
        XCTAssertTrue(note.contains("#cards[0]") && note.contains("#cards[1]"), note)
    }

    func testOffscreenContainerIsNotACandidate() {
        let snap = snapshot([
            element(1, id: "drawer", frame: FTRect(x: -400, y: 0, width: 400, height: 800),
                    scrollable: true),
        ])
        XCTAssertTrue(ScrollFrameCandidates.candidates(in: snap).isEmpty)
    }

    /// Android は容器と中身の両方が isScrollable を立てることがある。
    /// 同じ矩形は1つに畳み、**名指しできる方**を残す
    func testNestedSameFrameCollapsesKeepingTheNameableOne() {
        let frame = FTRect(x: 0, y: 100, width: 400, height: 500)
        let snap = snapshot([
            element(1, frame: frame, scrollable: true),
            element(2, id: "list_rows", frame: frame, scrollable: true, depth: 2),
        ])
        let found = ScrollFrameCandidates.candidates(in: snap)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.selector, "#list_rows")
    }

    func testLabelIsUsedWhenThereIsNoIdButNotWhenItIsTooLong() {
        let frame = FTRect(x: 0, y: 100, width: 400, height: 200)
        // 実際に FTSelector で往復する**素の**形(2026-08-15。旧実装は `"…"` で囲んでいたが、
        // FTSelector の記法は引用符を特別扱いしないため、その形は要素の実ラベルに一致しなかった)
        XCTAssertEqual(ScrollFrameCandidates.selector(
            for: element(1, label: "Recent items", frame: frame, scrollable: true)),
                       "Recent items")
        // 切り詰めると別のセレクタになるので、長いラベルは名指しできない扱い
        let long = String(repeating: "a", count: ScrollFrameCandidates.maxLabelLength + 1)
        XCTAssertNil(ScrollFrameCandidates.selector(
            for: element(2, label: long, frame: frame, scrollable: true)))
        // ラベルに引用符を含んでいても、FTSelector の記法としては何の意味も持たないので
        // エスケープ不要でそのまま書ける(旧実装は誤って弾いていた)
        XCTAssertEqual(ScrollFrameCandidates.selector(
            for: element(3, label: "say \"hi\"", frame: frame, scrollable: true)),
                       "say \"hi\"")
        // **記法として読まれる先頭文字は `=` で逃がす**(SelectorNaming.needsEscaping と同じ判定)
        XCTAssertEqual(ScrollFrameCandidates.selector(
            for: element(4, label: "#hashtag", frame: frame, scrollable: true)),
                       "=#hashtag")
    }

    // MARK: - note

    func testNoteStaysSilentForASingleScrollArea() {
        let snap = snapshot([
            element(1, id: "list_rows", frame: FTRect(x: 0, y: 100, width: 400, height: 500),
                    scrollable: true),
        ])
        XCTAssertNil(ScrollFrameCandidates.note(snap))
    }

    func testNoteListsBothAreasAndNamesTheOneWithoutAnId() {
        let snap = snapshot([
            element(1, id: "chips", frame: FTRect(x: 0, y: 60, width: 400, height: 60),
                    scrollable: true),
            element(2, frame: FTRect(x: 0, y: 120, width: 400, height: 500), scrollable: true),
        ])
        let text = ScrollFrameCandidates.note(snap) ?? ""
        XCTAssertTrue(text.contains("2 scroll areas"), text)
        XCTAssertTrue(text.contains("#chips"), text)
        XCTAssertTrue(text.contains("(0,120 400x500 — no id)"), text)
        XCTAssertTrue(text.contains("scrollFrame:"), text)
        XCTAssertTrue(text.hasSuffix("\n"), text)
    }

    /// **1つも名指しできない画面では scrollFrame を勧めない**(2026-08-08。in-app が版57で
    /// Compose の素の容器を出すようになった —— testTag の無い容器ばかりの画面で
    /// 「scrollFrame: を渡せ」と言っても渡せる書き方が無い。ft_drag で領域内を掴む案内に切り替える)
    func testNoteAdvisesDragWhenNoCandidateCanBeNamed() {
        let snap = snapshot([
            element(1, frame: FTRect(x: 0, y: 60, width: 400, height: 60), scrollable: true),
            element(2, frame: FTRect(x: 0, y: 120, width: 400, height: 500), scrollable: true),
        ])
        let text = ScrollFrameCandidates.note(snap) ?? ""
        XCTAssertTrue(text.contains("2 scroll areas"), text)
        XCTAssertTrue(text.contains("ft_drag"), text)
        XCTAssertFalse(text.contains("Pass scrollFrame:"), text)
    }

    /// **id が無い/重複する容器が混じる画面だけ** ref の逃げ道を添える(2026-08-10。
    /// MCPServer.scrollTo が整数を frame へ解決する)。id で足りる画面では出さない
    func testNoteMentionsTheRefEscapeHatchOnlyWhenACandidateCannotBeNamedBySelector() {
        let namedOnly = snapshot([
            element(1, id: "chips", frame: FTRect(x: 0, y: 60, width: 400, height: 60),
                    scrollable: true),
            element(2, id: "list_rows", frame: FTRect(x: 0, y: 120, width: 400, height: 500),
                    scrollable: true),
        ])
        XCTAssertFalse((ScrollFrameCandidates.note(namedOnly) ?? "").contains("by its ref"))

        let mixed = snapshot([
            element(1, id: "chips", frame: FTRect(x: 0, y: 60, width: 400, height: 60),
                    scrollable: true),
            element(2, frame: FTRect(x: 0, y: 120, width: 400, height: 500), scrollable: true),
        ])
        XCTAssertTrue((ScrollFrameCandidates.note(mixed) ?? "").contains("by its ref"))

        let unnamedOnly = snapshot([
            element(1, frame: FTRect(x: 0, y: 60, width: 400, height: 60), scrollable: true),
            element(2, frame: FTRect(x: 0, y: 120, width: 400, height: 500), scrollable: true),
        ])
        XCTAssertTrue((ScrollFrameCandidates.note(unnamedOnly) ?? "").contains("pass its ref instead"))
    }

    /// **同名 id が並ぶ画面では添字と矩形と軸まで出す**。実測(2026-08-07・Google マップ Android):
    /// `#recycler_view / #search_list_layout / #recycler_view / #recycler_view` と並べていたので、
    /// 「どれか1つを渡せ」と言いながら渡せる書き方が無かった。
    /// 添字は**木の全要素の中の順番**(スクロールしない同名要素も番号を消費する)
    func testAmbiguousIdsAreListedWithIndexRectAndAxis() {
        let snap = snapshot([
            // 横チップ行(preorder 先頭 = 添字なしなら黙ってこれが選ばれていた)
            element(1, id: "recycler_view", frame: FTRect(x: 0, y: 300, width: 400, height: 126),
                    scrollable: true),
            element(2, id: "search_list_layout",
                    frame: FTRect(x: 0, y: 430, width: 380, height: 60), scrollable: true),
            // スクロールしない同名要素。**候補ではないが添字は消費する**
            element(3, id: "recycler_view", frame: FTRect(x: 0, y: 740, width: 400, height: 20)),
            element(4, id: "recycler_view", frame: FTRect(x: 0, y: 490, width: 200, height: 290),
                    scrollable: true),
        ])
        let text = ScrollFrameCandidates.note(snap) ?? ""
        XCTAssertTrue(text.contains("#recycler_view[0] (0,300 400x126) wide"), text)
        XCTAssertTrue(text.contains("#recycler_view[2] (0,490 200x290) tall"), text)
        // 一意なものは今までどおり名前だけ(読みやすさを落とさない)
        XCTAssertTrue(text.contains("/ #search_list_layout /"), text)
    }

    func testNoteCapsTheListing() {
        let snap = snapshot((1...6).map {
            element($0, id: "area_\($0)",
                    frame: FTRect(x: 0, y: Double($0) * 100, width: 400, height: 90),
                    scrollable: true)
        })
        let text = ScrollFrameCandidates.note(snap) ?? ""
        XCTAssertTrue(text.contains("6 scroll areas"), text)
        XCTAssertTrue(text.contains("(+2 more)"), text)
        XCTAssertFalse(text.contains("#area_5"), text)
    }

    // MARK: - selector(matching:)

    func testSelectorMatchingPicksTheOverlappingDeclaredContainer() {
        let snap = snapshot([
            element(1, id: "chips", frame: FTRect(x: 0, y: 60, width: 400, height: 60),
                    scrollable: true),
            element(2, id: "list_rows", frame: FTRect(x: 0, y: 120, width: 400, height: 500),
                    scrollable: true),
        ])
        // 推測した容器は縁が数 pt ずれる(clippingContainer は木から採るので厳密一致しない)
        let inferred = FTRect(x: 0, y: 124, width: 400, height: 492)
        XCTAssertEqual(ScrollFrameCandidates.selector(matching: inferred, in: snap), "#list_rows")
    }

    /// 重なりが浅い相手を名乗ると**別の領域を指す scrollFrame** を勧めることになる。
    /// IoU 閾値未満は nil(呼び出し側は総称の文言に留まる)
    func testSelectorMatchingRefusesAWeakOverlap() {
        let snap = snapshot([
            element(1, id: "list_rows", frame: FTRect(x: 0, y: 0, width: 400, height: 800),
                    scrollable: true),
        ])
        let inferred = FTRect(x: 0, y: 600, width: 400, height: 200)
        XCTAssertNil(ScrollFrameCandidates.selector(matching: inferred, in: snap))
    }

    func testSelectorMatchingIgnoresContainersThatCannotBeNamed() {
        let snap = snapshot([
            element(1, frame: FTRect(x: 0, y: 100, width: 400, height: 500), scrollable: true),
        ])
        XCTAssertNil(ScrollFrameCandidates.selector(
            matching: FTRect(x: 0, y: 100, width: 400, height: 500), in: snap))
    }

    // MARK: - キーボードの部品

    /// 実機 SE3(Flutter の入力画面): 予測変換バーの scrollView / collectionView が「画面のスクロール領域」として
    /// 勧められていた。キーボードが出ている木では候補にしない・キーボードが画面の外なら従来どおり
    func testKeyboardAssistantScrollersAreNotCandidates() {
        let page = element(1, type: "scrollView", id: "page", frame: FTRect(x: 0, y: 60, width: 400, height: 300),
                           scrollable: true, depth: 2)
        let list = element(2, type: "scrollView", id: "list", frame: FTRect(x: 0, y: 360, width: 400, height: 80),
                           scrollable: true, depth: 2)
        // 実機と同じく inputView(申告と交差する chrome)と、申告の直上に接する予測変換バーの兄弟
        let inputView = element(6, id: "inputView", frame: FTRect(x: 0, y: 532, width: 400, height: 268), depth: 4)
        let assistant = element(3, id: "SystemInputAssistantView", frame: FTRect(x: 0, y: 532, width: 400, height: 44),
                                depth: 4)
        let bar = element(4, type: "scrollView", frame: FTRect(x: 0, y: 532, width: 400, height: 44),
                          scrollable: true, depth: 8)
        let suggestions = element(5, type: "collectionView", frame: FTRect(x: 0, y: 532, width: 400, height: 54),
                                  scrollable: true, depth: 12)
        func snap(keyboardY: Double) -> SnapshotResponse {
            var s = snapshot([page, list, inputView, assistant, bar, suggestions])
            s.keyboardFrame = FTRect(x: 0, y: keyboardY, width: 400, height: 224)
            return s
        }
        XCTAssertEqual(ScrollFrameCandidates.candidates(in: snap(keyboardY: 576)).map(\.ref), [1, 2])
        XCTAssertNil(ScrollFrameCandidates.note(snap(keyboardY: 576))?.range(of: "SystemInputAssistantView"))
        XCTAssertEqual(ScrollFrameCandidates.candidates(in: snap(keyboardY: 900)).map(\.ref), [1, 2, 4, 5],
                       "画面の外の申告はキーボード無し = 除外しない")
    }
}
