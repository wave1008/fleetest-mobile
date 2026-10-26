// AppIconLocator.swift
// tapAppIcon(Shirates 準拠)専用の純粋ロジック。ホーム画面/ドロワー/ページ送り探索の
// 「一致判定」「変化検知」「打ち切り判定」だけを切り出す(実機なしで単体テストできる部分)。
// ドライバ呼び出し(home/snapshot/drag/tap)は FTDSL/CommandsAppControl.swift の tapAppIcon 実装が持つ。

/// アイコン探索の純粋ロジック。
public enum AppIconLocator {
    /// スナップショットから appIconName に一致する要素を探す(label 完全一致。Shirates も完全一致)。
    /// 複数一致時は snapshot の並び順で最初の1件
    public static func findIcon(_ name: String, in snapshot: SnapshotResponse) -> ElementInfo? {
        snapshot.elements.first { $0.label == name }
    }

    /// iOS の App ライブラリの検索欄(SpringBoard の識別子。表示言語に依らない)。ホームのページに置かれていないアプリは
    /// App ライブラリにしか居ない(実測: -06 のホーム1ページに「FT E2E iOS」が無く「Other」フォルダの中だけ)。
    /// ページ送りは右端の App ライブラリで止まるので、送り切った木にこれがあれば検索で探せる
    public static let appLibrarySearchFieldID = "dewey-search-field"

    public static func appLibrarySearchField(in snapshot: SnapshotResponse) -> ElementInfo? {
        snapshot.elements.first { $0.identifier == appLibrarySearchFieldID }
    }

    /// App ライブラリの検索バー(一覧の行はこの下に潜って隠れる)
    static let appLibrarySearchBarID = "dewey-search-bar"

    /// 一覧の行を押してよい帯: 検索バーの下端 〜 キーボードの上端(出ていなければ画面の下端)
    static func appLibraryListBand(in snapshot: SnapshotResponse) -> (top: Double, bottom: Double) {
        let bar = snapshot.elements.first { $0.identifier == appLibrarySearchBarID }?.frame
        let top = bar.map { $0.y + $0.height } ?? snapshot.screen.y
        var bottom = snapshot.screen.y + snapshot.screen.height
        if KeyboardWait.isShown(snapshot), let keyboard = snapshot.keyboardFrame { bottom = min(bottom, keyboard.y) }
        return (top, bottom)
    }

    /// 名前順一覧の行を押せるか: 中心が画面内で、検索バーの下・キーボードの上(覆われた行を押すとキーボードに当たる)
    public static func isTappableInAppLibraryList(_ row: ElementInfo, in snapshot: SnapshotResponse) -> Bool {
        let point = centre(of: row)
        let band = appLibraryListBand(in: snapshot)
        return TapTargetGeometry.isPointOnScreen(x: point.x, y: point.y, screen: snapshot.screen)
            && point.y > band.top && point.y < band.bottom
    }

    /// 一覧を下へ送る(指は上へ)ドラッグ: 押してよい帯の 80% → 20%(帯の 60% ぶん動かす)。帯が潰れていれば nil
    public static func appLibraryListDragPath(in snapshot: SnapshotResponse)
        -> (fromX: Double, fromY: Double, toX: Double, toY: Double)? {
        let band = appLibraryListBand(in: snapshot)
        let span = band.bottom - band.top
        guard span > 0 else { return nil }
        let x = snapshot.screen.x + snapshot.screen.width / 2
        return (x, band.top + span * 0.8, x, band.top + span * 0.2)
    }

    /// 名前順一覧に名前の無い行があるか。**SpringBoard はアプリの名前を欠いたまま行を描くことがある**(実測:
    /// 行もアイコンもラベル・id が空のまま、一覧を送って戻しても空。同じアプリはカテゴリのフォルダの中では名前付きで並ぶ)
    public static func appLibraryListHasUnnamedRow(in snapshot: SnapshotResponse) -> Bool {
        let band = appLibraryListBand(in: snapshot)
        return snapshot.elements.contains { element in
            guard element.type == "icon", (element.label ?? "").isEmpty, (element.identifier ?? "").isEmpty else { return false }
            let point = centre(of: element)
            return point.y > band.top && TapTargetGeometry.isPointOnScreen(x: point.x, y: point.y, screen: snapshot.screen)
        }
    }

    /// 検索中の App ライブラリの取り消しボタン(検索バーの中のボタン。文言は表示言語で変わるので型と位置で取る)
    public static func appLibrarySearchCancelButton(in snapshot: SnapshotResponse) -> ElementInfo? {
        guard let bar = snapshot.elements.first(where: { $0.identifier == appLibrarySearchBarID })?.frame else { return nil }
        return snapshot.elements.first { element in
            guard element.type == "button" else { return false }
            let point = centre(of: element)
            return point.x >= bar.x && point.x <= bar.x + bar.width && point.y >= bar.y && point.y <= bar.y + bar.height
        }
    }

    /// App ライブラリの検索が開いているか(取り消しボタンは検索中の検索バーの中にだけ出る)。前の操作が開いたまま残すと、
    /// ホームを2回押しても閉じない(OI-30)
    public static func isAppLibrarySearchOpen(_ snapshot: SnapshotResponse) -> Bool {
        appLibrarySearchCancelButton(in: snapshot) != nil
    }

    /// App ライブラリのカテゴリのフォルダを開くボタンの識別子(上から順)。カテゴリの枠(大きいアイコン)と同じ識別子を持ち
    /// value(「17個のアプリ」等)を持つ小さいアイコン。名前は表示言語で変わるので識別子の共有で取る
    public static func appLibraryFolderButtonIDs(in snapshot: SnapshotResponse) -> [String] {
        let icons = snapshot.elements.filter { $0.type == "icon" }
        let buttons = icons.filter { button in
            guard let id = button.identifier, !id.isEmpty, !(button.value ?? "").isEmpty else { return false }
            return icons.contains { pod in
                pod.identifier == id && pod.frame.width > button.frame.width && pod.frame.height > button.frame.height
            }
        }
        var seen = Set<String>()
        return buttons.sorted { ($0.frame.y, $0.frame.x) < ($1.frame.y, $1.frame.x) }
            .compactMap { $0.identifier }.filter { seen.insert($0).inserted }
    }

    /// 開いたカテゴリのフォルダを閉じる点: 一番上のアイコンより上の背景の中ほど(閉じるボタンは無い。外を押すと閉じる)。
    /// アイコンが無い・一番上のアイコンが画面の上端に付いていれば nil
    public static func appLibraryFolderDismissPoint(in snapshot: SnapshotResponse) -> (x: Double, y: Double)? {
        guard let top = snapshot.elements.filter({ $0.type == "icon" }).map({ $0.frame.y }).min(),
              top > snapshot.screen.y else { return nil }
        return (snapshot.screen.x + snapshot.screen.width / 2, snapshot.screen.y + (top - snapshot.screen.y) / 2)
    }

    public static func centre(of icon: ElementInfo) -> (x: Double, y: Double) {
        (icon.frame.x + icon.frame.width / 2, icon.frame.y + icon.frame.height / 2)
    }

    /// アイコンの中心がその木の画面の中にあるか。**SpringBoard の木が表示中の画面と違う場面の枠を載せることがある**
    /// (iPhone Duo の Simulator・Xcode 27.2 RC: 内側の画面の場面の枠が外側の画面の木に混ざり、中心が y < 0 になる。
    /// docs/open-issues.md)。撃っても画面の外へ空振りするだけなので、呼び手は読み直して、直らなければ撃たずに失敗する。
    /// 判定は `TapTargetGeometry.isPointOnScreen`(MCP・ライブ操作の画面内判定と同じ。画面が分からなければ true)
    public static func isCentreOnScreen(_ icon: ElementInfo, in snapshot: SnapshotResponse) -> Bool {
        let point = centre(of: icon)
        return TapTargetGeometry.isPointOnScreen(x: point.x, y: point.y, screen: snapshot.screen)
    }

    /// ホーム画面の木の画面が、表示中の画面の大きさ(pt)と合っているか。**内蔵画面が2枚の機種で、木が表示していない側の画面の
    /// 寸法で来ることがある**(iPhone Duo の Simulator・Xcode 27.2 RC: 外側 466x678 を表示中に木は 951x669 = 内側の横向き。
    /// その木にはアイコンが載らない・載っても外側の画面に当たらない)。向きは問わない(横向きのアプリでも SpringBoard の木は
    /// 縦のまま = 幅と高さの入れ替わりは一致とみなす)。1pt 未満の差は丸め
    public static func treeMatchesShownDisplay(screen: FTRect, shownWidth: Double, shownHeight: Double) -> Bool {
        guard screen.width > 0, screen.height > 0, shownWidth > 0, shownHeight > 0 else { return true }
        func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1 }
        return (same(screen.width, shownWidth) && same(screen.height, shownHeight))
            || (same(screen.width, shownHeight) && same(screen.height, shownWidth))
    }

    /// ドロワー/ページ送り探索で「画面が変わったか」を見るための署名。ラベル集合が同じなら
    /// 同じ画面とみなす(要素の並び順・ref 番号のブレを無視するため sort してから連結)
    public static func signature(of snapshot: SnapshotResponse) -> String {
        snapshot.elements.compactMap { $0.label }.sorted().joined(separator: "\u{1}")
    }

    /// ドロワー/ページ送りの打ち切り判定: 2回連続で画面が変わらなければ端に着いたとみなす
    /// (StepExecutor の scrollTo と同じ規律)。上限回数に達したときも打ち切る
    public static func shouldStopSearch(consecutiveUnchanged: Int, attempts: Int, maxAttempts: Int) -> Bool {
        consecutiveUnchanged >= 2 || attempts >= maxAttempts
    }
}
