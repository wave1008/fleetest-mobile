/// ホスト側のキーボードの待ち(type の後)。
/// **ブリッジのソース集合(BridgeDTO.swift)へ置かない**: 変えるとブリッジの版上げが要る。
public enum KeyboardWait {
    /// type の後にソフトキーボードが木に出るまで待つ上限(秒)。
    /// 根拠: 実測(M2Ultra と M1Ultra・エミュレータ 8 台並列で E2EX-CMP android を各 10 周、
    /// ImeTracker の onRequestShow→onShown、計 140 件)で中央値 0.20 秒・最大 0.89 秒。
    /// iOS(XCUITest)は画面の外の申告から上がりきるまで実測 0.6〜0.9 秒(E2EY-Flutter の反転チャット)で、同じ上限に収まる。
    /// 尽きたら待ちをやめて従来どおり解決して撃つ(悪化はしない)・注記 keyboard-not-shown-after-type。
    /// `FocusWait.waitSeconds` と同じ値だが文脈が別なので流用しない(片方を変えても他方が黙って変わらない)
    public static let appearSeconds: Double = 1.5
    /// 撮り直しの間隔(秒)。根拠: 表示の中央値 0.2 秒の間に 1〜2 回見る
    public static let pollSeconds: Double = 0.15

    /// 隠れたキーボードは nil ではなく画面外(y が画面の下端以上)の矩形で申告されることがある。
    /// `StepExecutor.keyboardOnScreen` はここへ転送する(同じ判定を2つ持たない)
    public static func onScreen(_ frame: FTRect?, screen: FTRect) -> Bool {
        guard let frame, frame.height > 0 else { return false }
        return frame.y < screen.y + screen.height
    }

    /// そのスナップショットでキーボードが出ているか。**矩形の申告があればそれだけで決める**
    /// (`keyboardShown` は iOS の XCUITest が画面の外の `.keyboard` ノードでも true にする)。
    /// 矩形が無いときだけ `keyboardShown`(Android は dumpsys の算出で矩形を持たない回がある)。
    /// `keyboardFrame != nil || keyboardShown == true` と書かない —— 隠れた・最小化したキーボードを「出ている」と読む
    public static func isShown(_ snapshot: SnapshotResponse) -> Bool {
        shownState(snapshot) == true
    }

    /// `isShown` の3値版。nil = 分からない(矩形も `keyboardShown` も無い)。**nil を非表示と読まない**
    /// 呼び手(`keyboardIsNotShown` の検証)が使う
    public static func shownState(_ snapshot: SnapshotResponse) -> Bool? {
        if let frame = snapshot.keyboardFrame { return onScreen(frame, screen: snapshot.screen) }
        return snapshot.keyboardShown
    }

    /// type の後にキーボードの出現を待つか(純粋関数)。
    /// **Android**: type が焦点を要求して書き込むとすぐ返り、IME の表示を待たないので、次の解決の木には
    /// まだ無く後から出てダイアログが動く。
    /// **iOS は「画面の外の矩形」で申告されたときだけ** —— XCUITest の /type はキーボードが出る前に返り、
    /// 0.6〜0.9 秒は画面の下(y=891・画面 874)に申告したまま、その後に上がって入力バーを動かす(実測 E2EY-Flutter の
    /// 反転チャット: 打った直後の木の下端の送信ボタンを押し、上がってきたキーボードに当たって送信が飲まれた)。
    /// 申告が無い(nil)iOS は、**この端末で打った後にキーボードが出なかったと既に観測していなければ**待つ(`keyboardKnownAbsent`)。
    /// XCUITest は上がる途中の最初の読みに `.keyboard` を載せず、欄も上がる前の位置のまま返す(SwiftUI で実測: 打った直後の
    /// 木で別の欄を解決し、上がってきたキーボードの上の「入力クリア」を押した)。ハードウェアキーボード等でそもそも出ない端末は
    /// 上限まで待った1回で `keyboardKnownAbsent` を立てて以後は待たない(毎回上限まで待たない)。
    /// **打つ前に出ていても iOS は画面の外の読みを待つ**: XCUITest は打った直後の木でキーボードの枠が画面の外(y=918・画面 874)になり、
    /// 欄も閉じた位置で返す(SwiftUI で実測 4/4・1 秒後に戻る。その木の ref で打って別の欄へ入った)。Android は打つ前に出ていれば待たない(隠れ待ちの領分)。
    /// 既に次の木に出ている・改行で終わる(Enter で閉じうる)ときは待たない
    public static func shouldAwaitAppearance(isAndroid: Bool, before: FTRect?, after: FTRect?,
                                      screen: FTRect, typedNewline: Bool,
                                      keyboardKnownAbsent: Bool) -> Bool {
        guard !typedNewline, !onScreen(after, screen: screen) else { return false }
        if onScreen(before, screen: screen) { return !isAndroid && !keyboardKnownAbsent }
        return isAndroid || after != nil || !keyboardKnownAbsent
    }

    /// `keyboardKnownAbsent` の次の値(純粋関数)。**待ちの枝の外でも更新する**: 待ちの枝に入らない回(すぐ出た)で戻さないと、
    /// 一度立てた不在が残り続け、上がる途中の読みを待たなくなる。
    /// **打つ前に出ていたキーボードは不在の証拠にならない**(アプリが入力の完了で閉じた = コード欄。この端末に出ないのではない)。
    /// `waitExhausted` = 上限まで待っても出なかった
    public static func knownAbsent(current: Bool, before: FTRect?, after: FTRect?, screen: FTRect,
                                   waitExhausted: Bool) -> Bool {
        if onScreen(before, screen: screen) || onScreen(after, screen: screen) { return false }
        return current || waitExhausted
    }
}
