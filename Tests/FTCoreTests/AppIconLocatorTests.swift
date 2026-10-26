import XCTest
@testable import FTCore

/// AppIconLocator(tapAppIcon の純粋ロジック)の境界を固定する。ドライバを必要としない層なので、
/// ここで落とせない誤りは E2E まで見つからない。
final class AppIconLocatorTests: XCTestCase {

    private func element(_ ref: Int, label: String?) -> ElementInfo {
        ElementInfo(ref: ref, type: "Icon", identifier: nil, label: label, value: nil,
                   placeholder: nil, enabled: true,
                   frame: FTRect(x: 0, y: 0, width: 60, height: 60), depth: 0)
    }

    private func snapshot(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil,
                         screen: FTRect(x: 0, y: 0, width: 400, height: 800),
                         elements: elements, truncatedCount: 0)
    }

    // MARK: - appLibraryKeyboardFrame

    /// キーボードの申告が無い木(xcuitest モードの /systemui/snapshot)では、木に載るキーボードの窓の上端から下をキーボードとする。
    /// 画面の外へ下がった窓は出ていない。申告があればそれを使う
    func testAppLibraryKeyboardComesFromTheTreeWhenNotReported() {
        let screen = FTRect(x: 0, y: 0, width: 402, height: 874)
        func window(_ id: String, y: Double, h: Double) -> ElementInfo {
            ElementInfo(ref: 9, type: "other", identifier: id, label: nil, value: nil, placeholder: nil, enabled: true,
                        frame: FTRect(x: 0, y: y, width: 402, height: h), depth: 1)
        }
        let up = SnapshotResponse(sessionBundleID: nil, screen: screen,
                                  elements: [window("inputView", y: 545, h: 329), window("SystemInputAssistantView", y: 545, h: 45)],
                                  truncatedCount: 0)
        XCTAssertEqual(AppIconLocator.appLibraryKeyboardFrame(in: up)?.y, 545)
        let down = SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [window("inputView", y: 874, h: 329)],
                                    truncatedCount: 0)
        XCTAssertNil(AppIconLocator.appLibraryKeyboardFrame(in: down))
        let reported = SnapshotResponse(sessionBundleID: nil, screen: screen, elements: [], truncatedCount: 0,
                                        keyboardShown: true, keyboardFrame: FTRect(x: 0, y: 500, width: 402, height: 374))
        XCTAssertEqual(AppIconLocator.appLibraryKeyboardFrame(in: reported)?.y, 500)
    }

    // MARK: - appLibrarySearchField

    /// App ライブラリの検索欄は識別子で拾う(実測の木: searchField id=dewey-search-field ph="アプリライブラリ")
    func testAppLibrarySearchFieldIsFoundByIdentifier() {
        let field = ElementInfo(ref: 7, type: "searchField", identifier: "dewey-search-field", label: nil, value: nil,
                                placeholder: "アプリライブラリ", enabled: true,
                                frame: FTRect(x: 26, y: 90, width: 350, height: 48), depth: 0)
        XCTAssertEqual(AppIconLocator.appLibrarySearchField(in: snapshot([element(1, label: "Other"), field]))?.ref, 7)
        XCTAssertNil(AppIconLocator.appLibrarySearchField(in: snapshot([element(1, label: "アプリライブラリ")])),
                     "ラベル・プレースホルダ(言語で変わる)では拾わない")
    }

    /// 実測の名前順一覧(402x874・検索バー 0..162・キーボード 545..874)
    private func libraryList(keyboard: Bool) -> SnapshotResponse {
        func row(_ ref: Int, _ y: Double) -> ElementInfo {
            ElementInfo(ref: ref, type: "clickable", identifier: nil, label: "App\(ref)", value: nil, placeholder: nil,
                        enabled: true, frame: FTRect(x: 0, y: y, width: 402, height: 72), depth: 2)
        }
        let bar = ElementInfo(ref: 1, type: "other", identifier: "dewey-search-bar", label: nil, value: nil, placeholder: nil,
                              enabled: true, frame: FTRect(x: 0, y: 0, width: 402, height: 162), depth: 1)
        return SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                                elements: [bar, row(2, 90), row(3, 450), row(4, 522), row(5, 900)], truncatedCount: 0,
                                keyboardFrame: keyboard ? FTRect(x: 0, y: 545, width: 402, height: 329) : nil)
    }

    func testLibraryRowIsTappableOnlyBetweenTheSearchBarAndTheKeyboard() {
        let list = libraryList(keyboard: true)
        let rows = Dictionary(uniqueKeysWithValues: list.elements.map { ($0.ref, $0) })
        XCTAssertFalse(AppIconLocator.isTappableInAppLibraryList(rows[2]!, in: list), "検索バーの下に潜った行")
        XCTAssertTrue(AppIconLocator.isTappableInAppLibraryList(rows[3]!, in: list), "バーとキーボードの間")
        XCTAssertFalse(AppIconLocator.isTappableInAppLibraryList(rows[4]!, in: list), "中心 558 がキーボード(545〜)の下")
        XCTAssertFalse(AppIconLocator.isTappableInAppLibraryList(rows[5]!, in: list), "画面の外")
        XCTAssertTrue(AppIconLocator.isTappableInAppLibraryList(rows[4]!, in: libraryList(keyboard: false)),
                      "キーボードが無ければ画面の下端まで押せる")
    }

    func testLibraryDragMovesWithinTheVisibleBand() {
        let path = AppIconLocator.appLibraryListDragPath(in: libraryList(keyboard: true))
        XCTAssertEqual(path?.fromY ?? 0, 162 + 383 * 0.8, accuracy: 0.01)
        XCTAssertEqual(path?.toY ?? 0, 162 + 383 * 0.2, accuracy: 0.01)
        XCTAssertEqual(path?.fromX, 201)
    }

    // MARK: - findIcon

    func testFindIconMatchesExactLabel() {
        let snap = snapshot([element(1, label: "Settings"), element(2, label: "Maps")])
        XCTAssertEqual(AppIconLocator.findIcon("Maps", in: snap)?.ref, 2)
    }

    func testFindIconReturnsNilWhenNoLabelMatches() {
        let snap = snapshot([element(1, label: "Settings")])
        XCTAssertNil(AppIconLocator.findIcon("Maps", in: snap))
    }

    /// label なし(nil)の要素は決してマッチしない(部分一致・大小無視をしない完全一致の確認を兼ねる)
    func testFindIconDoesNotMatchNilOrSubstringLabels() {
        let snap = snapshot([element(1, label: nil), element(2, label: "My Settings App")])
        XCTAssertNil(AppIconLocator.findIcon("Settings", in: snap))
    }

    /// 複数一致時は最初の1件(Shirates の「最初に見つかった方」と同じ)
    func testFindIconReturnsFirstMatchOnDuplicateLabels() {
        let snap = snapshot([element(1, label: "Clock"), element(2, label: "Clock")])
        XCTAssertEqual(AppIconLocator.findIcon("Clock", in: snap)?.ref, 1)
    }

    // MARK: - signature

    /// ラベル集合が同じなら ref の割り当てが違っても同じ署名(並び替えに依存しないことの確認)
    func testSignatureIsOrderIndependent() {
        let a = snapshot([element(1, label: "Maps"), element(2, label: "Clock")])
        let b = snapshot([element(5, label: "Clock"), element(9, label: "Maps")])
        XCTAssertEqual(AppIconLocator.signature(of: a), AppIconLocator.signature(of: b))
    }

    func testSignatureChangesWhenLabelSetChanges() {
        let a = snapshot([element(1, label: "Maps")])
        let b = snapshot([element(1, label: "Clock")])
        XCTAssertNotEqual(AppIconLocator.signature(of: a), AppIconLocator.signature(of: b))
    }

    // MARK: - isCentreOnScreen

    private func icon(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> ElementInfo {
        ElementInfo(ref: 1, type: "Icon", identifier: nil, label: "FT E2E iOS", value: nil,
                    placeholder: nil, enabled: true, frame: FTRect(x: x, y: y, width: w, height: h), depth: 0)
    }

    private func duoScreen(_ elements: [ElementInfo], width: Double = 466, height: Double = 678) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.apple.springboard",
                         screen: FTRect(x: 0, y: 0, width: width, height: height),
                         elements: elements, truncatedCount: 0)
    }

    /// iPhone Duo(Xcode 27.2 RC)の実測: 外側の画面 466x678 の木に、内側の場面の枠 [52, -75, 87x83] で載った
    /// (中心 (95, -33) = 画面の上の外)。正しい状態は (103, 52, 83x87)
    func testDuoIconReportedAboveTheScreenIsOffScreen() {
        XCTAssertFalse(AppIconLocator.isCentreOnScreen(icon(52, -75, 87, 83), in: duoScreen([])))
        XCTAssertTrue(AppIconLocator.isCentreOnScreen(icon(103, 52, 83, 87), in: duoScreen([])))
    }

    /// 枠が縁にかかっていても中心が中なら撃ってよい(縁は exact に外 = isPointOnScreen の規律)
    func testCentreDecidesNotTheWholeFrame() {
        XCTAssertTrue(AppIconLocator.isCentreOnScreen(icon(-20, 600, 60, 60), in: duoScreen([])))
        XCTAssertFalse(AppIconLocator.isCentreOnScreen(icon(436, 0, 60, 60), in: duoScreen([])))
        XCTAssertFalse(AppIconLocator.isCentreOnScreen(icon(0, 648, 60, 60), in: duoScreen([])))
    }

    /// 画面が分からない木(0x0)は「外れている」と読まない
    func testUnknownScreenCountsAsOnScreen() {
        XCTAssertTrue(AppIconLocator.isCentreOnScreen(icon(52, -75, 87, 83), in: duoScreen([], width: 0, height: 0)))
    }

    // MARK: - treeMatchesShownDisplay

    /// iPhone Duo(Xcode 27.2 RC)の実測: 外側 466x678 を表示中に、木の画面が 951x669(内側の横向き)で来る
    func testDuoTreeWithInnerDisplaySizeDoesNotMatchTheOuterDisplay() {
        let inner = FTRect(x: 0, y: 0, width: 951, height: 669)
        XCTAssertFalse(AppIconLocator.treeMatchesShownDisplay(screen: inner, shownWidth: 466, shownHeight: 678))
        let outer = FTRect(x: 0, y: 0, width: 466, height: 678)
        XCTAssertTrue(AppIconLocator.treeMatchesShownDisplay(screen: outer, shownWidth: 466, shownHeight: 678))
    }

    /// 横向きでも SpringBoard の木は縦のままなので、幅と高さの入れ替わりは一致。寸法が分からなければ一致
    func testRotatedAndUnknownSizesCountAsMatching() {
        let portrait = FTRect(x: 0, y: 0, width: 402, height: 874)
        XCTAssertTrue(AppIconLocator.treeMatchesShownDisplay(screen: portrait, shownWidth: 874, shownHeight: 402))
        XCTAssertTrue(AppIconLocator.treeMatchesShownDisplay(screen: portrait, shownWidth: 0, shownHeight: 0))
        XCTAssertTrue(AppIconLocator.treeMatchesShownDisplay(screen: FTRect(x: 0, y: 0, width: 0, height: 0),
                                                              shownWidth: 466, shownHeight: 678))
        // 画素→pt の割り算の端数(1398/3 = 466.0・2034/3 = 678.0 だが一般には端数が出る)は 1pt 未満なら同じ
        XCTAssertTrue(AppIconLocator.treeMatchesShownDisplay(screen: portrait, shownWidth: 402.4, shownHeight: 873.7))
    }

    // MARK: - shouldStopSearch

    func testStopsAfterTwoConsecutiveUnchangedScreens() {
        XCTAssertFalse(AppIconLocator.shouldStopSearch(consecutiveUnchanged: 1, attempts: 1, maxAttempts: 8))
        XCTAssertTrue(AppIconLocator.shouldStopSearch(consecutiveUnchanged: 2, attempts: 2, maxAttempts: 8))
    }

    func testStopsAtMaxAttemptsEvenIfStillChanging() {
        XCTAssertTrue(AppIconLocator.shouldStopSearch(consecutiveUnchanged: 0, attempts: 8, maxAttempts: 8))
        XCTAssertFalse(AppIconLocator.shouldStopSearch(consecutiveUnchanged: 0, attempts: 7, maxAttempts: 8))
    }

    // MARK: - 名前の無い行・カテゴリのフォルダ(実測 10/25 -06 の木)

    private func el(_ ref: Int, _ type: String, id: String? = nil, label: String? = nil, value: String? = nil,
                    _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> ElementInfo {
        ElementInfo(ref: ref, type: type, identifier: id, label: label, value: value, placeholder: nil, enabled: true,
                    frame: FTRect(x: x, y: y, width: w, height: h), depth: 2)
    }

    private func tree(_ elements: [ElementInfo]) -> SnapshotResponse {
        SnapshotResponse(sessionBundleID: nil, screen: FTRect(x: 0, y: 0, width: 402, height: 874),
                         elements: elements, truncatedCount: 0)
    }

    private var searchBar: ElementInfo { el(1, "other", id: "dewey-search-bar", 0, 0, 402, 162) }

    func testUnnamedRowIsDetectedOnlyInsideTheVisibleList() {
        let named = el(2, "icon", id: "FT E2E", label: "FT E2E", 24, 316, 52, 52)
        let unnamed = el(3, "icon", 24, 460, 52, 52)
        XCTAssertTrue(AppIconLocator.appLibraryListHasUnnamedRow(in: tree([searchBar, named, unnamed])))
        XCTAssertFalse(AppIconLocator.appLibraryListHasUnnamedRow(in: tree([searchBar, named])))
        XCTAssertFalse(AppIconLocator.appLibraryListHasUnnamedRow(in: tree([searchBar, el(4, "icon", 24, 900, 52, 52)])),
                       "画面の外の行は数えない")
        XCTAssertFalse(AppIconLocator.appLibraryListHasUnnamedRow(in: tree([searchBar, el(5, "icon", 24, 50, 52, 52)])),
                       "検索バーの下に潜った行は数えない")
        XCTAssertFalse(AppIconLocator.appLibraryListHasUnnamedRow(in: tree([searchBar, el(6, "clickable", 0, 450, 402, 72)])),
                       "アイコン以外の名前の無い要素は数えない")
    }

    func testCancelButtonIsTheButtonInsideTheSearchBar() {
        let cancel = el(9, "button", label: "キャンセル", 296, 97, 80, 33)
        let other = el(8, "button", label: "x", 296, 500, 80, 33)
        XCTAssertEqual(AppIconLocator.appLibrarySearchCancelButton(in: tree([other, searchBar, cancel]))?.ref, 9)
        XCTAssertNil(AppIconLocator.appLibrarySearchCancelButton(in: tree([other, cancel])), "検索バーが無ければ探さない")
    }

    func testFolderButtonsShareTheCategoryPodIdentifier() {
        let elements = [
            el(1, "icon", id: "Other", label: "Other", 24, 168, 168, 191),
            el(2, "icon", id: "SampleApp", label: "SampleApp", 112, 180, 68, 68),
            el(3, "icon", id: "Other", label: "Otherフォルダ", value: "17個のアプリ", 112, 256, 68, 68),
            el(4, "icon", id: " System", label: " System", 209, 168, 168, 191),
            el(5, "icon", id: " System", label: " Systemフォルダ", value: "19個のアプリ", 297, 256, 68, 68),
            el(6, "icon", id: "カレンダー", label: "カレンダー", value: "10月25日", 36, 400, 68, 68),
        ]
        XCTAssertEqual(AppIconLocator.appLibraryFolderButtonIDs(in: tree(elements)), ["Other", " System"],
                       "value を持っていても枠と識別子を共有しないアイコン(カレンダー)はフォルダではない")
    }

    func testFolderDismissPointIsAboveTheTopIcon() {
        let folder = tree([el(1, "icon", id: "A", label: "A", 10, 269, 103, 90), el(2, "staticText", label: "7:06", 54, 21, 38, 21)])
        let point = AppIconLocator.appLibraryFolderDismissPoint(in: folder)
        XCTAssertEqual(point?.x, 201)
        XCTAssertEqual(point?.y ?? 0, 134.5, accuracy: 0.01)
        XCTAssertNil(AppIconLocator.appLibraryFolderDismissPoint(in: tree([el(1, "icon", label: "A", 0, 0, 60, 60)])))
    }
}
