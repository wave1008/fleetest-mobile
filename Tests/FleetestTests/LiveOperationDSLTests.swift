import XCTest
@testable import fleetest
import FTCore

/// ライブ操作の操作記録の右列(actionResult.dsl)= 撃ったコマンドと同じ操作の Swift DSL の1行。
/// 純粋関数 `LiveOperationDSL.line(for:platform:snapshot:screen:)` を直接当てる(デバイス不要)。
final class LiveOperationDSLTests: XCTestCase {

    private let screen = FTRect(x: 0, y: 0, width: 400, height: 800)
    private let coordinateNote = "  // coordinates — replace with a selector before keeping this;"
        + " a layout change makes it hit something else"

    private func element(_ ref: Int, id: String?, depth: Int = 1) -> ElementInfo {
        ElementInfo(ref: ref, type: "button", identifier: id, label: nil, value: nil, placeholder: nil,
                    enabled: true, frame: FTRect(x: 100, y: 200, width: 40, height: 20), depth: depth)
    }

    /// ref 1 = `#login`(安定したセレクタが書ける)
    private var namedTree: SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app", screen: screen,
                         elements: [element(1, id: "login")], truncatedCount: 0)
    }

    /// ref 1 = id もラベルも無い唯一の要素(書けるセレクタが無い → 要素中心の座標になる)
    private var anonymousTree: SnapshotResponse {
        SnapshotResponse(sessionBundleID: "com.example.app", screen: screen,
                         elements: [element(1, id: nil)], truncatedCount: 0)
    }

    private func dsl(_ raw: [String: Any], platform: String = "ios", tree: SnapshotResponse? = nil) -> String? {
        let cmd = raw["cmd"] as? String ?? ""
        return LiveOperationDSL.line(
            for: ApiLiveServeCommand(cmd: cmd, raw: raw), platform: platform,
            snapshot: tree ?? namedTree, screen: screen)
    }

    // MARK: tap / press / doubleTap / type

    func testTapByRefWritesTheSelectorWhenOneExists() {
        XCTAssertEqual(dsl(["cmd": "tap", "ref": 1]), "tap(\"#login\")")
    }

    func testTapByRefFallsBackToTheElementCentreWithTheCoordinateNote() {
        XCTAssertEqual(dsl(["cmd": "tap", "ref": 1], tree: anonymousTree), "tap(x: 120, y: 210)" + coordinateNote)
    }

    func testTapByRefThatIsNotInTheTreeIsNil() {
        XCTAssertNil(dsl(["cmd": "tap", "ref": 99]))
        XCTAssertNil(LiveOperationDSL.line(for: ApiLiveServeCommand(cmd: "tap", raw: ["cmd": "tap", "ref": 1]),
                                           platform: "ios", snapshot: nil, screen: nil))
    }

    func testTapByCoordinateRoundsToOneDecimalAndCarriesTheNote() {
        XCTAssertEqual(dsl(["cmd": "tap", "x": 12.34, "y": 56.78]), "tap(x: 12.3, y: 56.8)" + coordinateNote)
    }

    /// 画面のクリックは座標で届く(拡張は ref を送らない)。押した点に書けるセレクタの要素があればその行
    /// (`#login` の枠は (100, 200, 40, 20))。枠の外は座標の行のまま
    func testCoordinateTapOnANamedElementBecomesItsSelector() {
        XCTAssertEqual(dsl(["cmd": "tap", "x": 110, "y": 205]), "tap(\"#login\")")
        XCTAssertEqual(dsl(["cmd": "press", "x": 110, "y": 205, "duration": 1.5]), "tap(\"#login\", holdSeconds: 1.5)")
        XCTAssertEqual(dsl(["cmd": "doubleTap", "x": 110, "y": 205]), "doubleTap(\"#login\")")
        XCTAssertEqual(dsl(["cmd": "tap", "x": 300, "y": 600]), "tap(x: 300, y: 600)" + coordinateNote)
        // 書けるセレクタが無い要素の上も座標の行
        XCTAssertEqual(dsl(["cmd": "tap", "x": 110, "y": 205], tree: anonymousTree), "tap(x: 110, y: 205)" + coordinateNote)
    }

    func testPressIsATapWithHoldSeconds() {
        XCTAssertEqual(dsl(["cmd": "press", "x": 1, "y": 2, "duration": 1.5]),
                       "tap(x: 1, y: 2, holdSeconds: 1.5)" + coordinateNote)
    }

    func testPressKeepsMaxGestureSecondsForLongHolds() {
        XCTAssertEqual(dsl(["cmd": "press", "x": 1, "y": 2, "duration": 12, "maxGestureSeconds": 20]),
                       "tap(x: 1, y: 2, holdSeconds: 12, maxGestureSeconds: 20)" + coordinateNote)
    }

    func testDoubleTap() {
        XCTAssertEqual(dsl(["cmd": "doubleTap", "ref": 1]), "doubleTap(\"#login\")")
        XCTAssertEqual(dsl(["cmd": "doubleTap", "ref": 1], tree: anonymousTree),
                       "doubleTap(x: 120, y: 210)" + coordinateNote)
        XCTAssertEqual(dsl(["cmd": "doubleTap", "x": 1, "y": 2]), "doubleTap(x: 1, y: 2)" + coordinateNote)
        XCTAssertNil(dsl(["cmd": "doubleTap", "ref": 99]))
    }

    func testTypeHasNoLocatorUnlessTheRefHasASelector() {
        XCTAssertEqual(dsl(["cmd": "type", "text": "hello"]), "type(\"hello\")")
        XCTAssertEqual(dsl(["cmd": "type", "text": "hello", "ref": 1]), "type(\"#login\", \"hello\")")
        XCTAssertEqual(dsl(["cmd": "type", "text": "hello", "ref": 1], tree: anonymousTree), "type(\"hello\")")
    }

    // MARK: drag(押してからの静止が長押し判定時間に届くか)

    func testDragBelowTheLongPressThresholdIsSwipePointToPoint() {
        XCTAssertEqual(
            dsl(["cmd": "drag", "fromX": 10, "fromY": 400, "toX": 10, "toY": 100, "press": 0.05, "duration": 0.55]),
            "swipePointToPoint(startX: 10, startY: 400, endX: 10, endY: 100, durationSeconds: 0.55)" + coordinateNote)
    }

    func testDragThresholdBoundaryOnIOS() {
        let below = ["cmd": "drag", "fromX": 100, "fromY": 400, "toX": 300, "toY": 200,
                     "press": LiveOperationDSL.iosLongPressSeconds - 0.01, "duration": 0.3] as [String: Any]
        let atThreshold = ["cmd": "drag", "fromX": 100, "fromY": 400, "toX": 300, "toY": 200,
                           "press": LiveOperationDSL.iosLongPressSeconds, "duration": 0.3] as [String: Any]
        XCTAssertTrue(dsl(below)?.hasPrefix("swipePointToPoint(") == true)
        XCTAssertEqual(dsl(atThreshold),
                       "gesture { FTFinger(x: 0.25, y: 0.5).hold(seconds: 0.5).move(x: 0.75, y: 0.25, durationSeconds: 0.3) }")
    }

    func testDragThresholdBoundaryOnAndroidIsTheShorterOne() {
        XCTAssertEqual(LiveOperationDSL.longPressThresholdSeconds(platform: "android"), 0.4)
        XCTAssertEqual(LiveOperationDSL.longPressThresholdSeconds(platform: "ios"), 0.5)
        func drag(press: Double) -> String? {
            dsl(["cmd": "drag", "fromX": 100, "fromY": 400, "toX": 300, "toY": 200, "press": press, "duration": 0.3],
                platform: "android")
        }
        XCTAssertTrue(drag(press: 0.39)?.hasPrefix("swipePointToPoint(") == true)
        XCTAssertTrue(drag(press: 0.4)?.hasPrefix("gesture {") == true)
        // iOS では 0.4 秒はまだ届かない(同じ入力でプラットフォームの差が出る)
        XCTAssertTrue(dsl(["cmd": "drag", "fromX": 100, "fromY": 400, "toX": 300, "toY": 200,
                           "press": 0.4, "duration": 0.3], platform: "ios")?.hasPrefix("swipePointToPoint(") == true)
    }

    /// 静止 + 移動が既定の上限(10 秒)を超える drag は、その秒数を maxGestureSeconds に書く(書かないと貼った先で断られる)
    func testLongDragOverTheDefaultCapCarriesMaxGestureSeconds() {
        let long = dsl(["cmd": "drag", "fromX": 100, "fromY": 400, "toX": 300, "toY": 200, "press": 3.0, "duration": 7.5])
        XCTAssertTrue(long?.hasPrefix("gesture(maxGestureSeconds: 11) {") == true, long ?? "nil")
        let short = dsl(["cmd": "drag", "fromX": 100, "fromY": 400, "toX": 300, "toY": 200, "press": 3.0, "duration": 7.0])
        XCTAssertTrue(short?.hasPrefix("gesture {") == true, short ?? "nil")
    }

    func testLongDragWithoutAScreenSizeIsNil() {
        XCTAssertNil(LiveOperationDSL.line(
            for: ApiLiveServeCommand(cmd: "drag", raw: ["cmd": "drag", "fromX": 1, "fromY": 2, "toX": 3, "toY": 4,
                                                        "press": 1.0, "duration": 0.3]),
            platform: "ios", snapshot: nil, screen: nil))
    }

    // MARK: gesture(軌跡)

    func testGestureTraceBecomesHoldAndMoveRatios() {
        let points: [[String: Any]] = [["x": 100, "y": 400, "t": 0], ["x": 100, "y": 400, "t": 0.5],
                                       ["x": 300, "y": 200, "t": 1.0]]
        XCTAssertEqual(
            dsl(["cmd": "gesture", "fingers": [["points": points]]]),
            "gesture { FTFinger(x: 0.25, y: 0.5).hold(seconds: 0.5).move(x: 0.75, y: 0.25, durationSeconds: 0.5) }")
        XCTAssertEqual(
            dsl(["cmd": "gesture", "fingers": [["points": points]], "maxGestureSeconds": 12]),
            "gesture(maxGestureSeconds: 12) { FTFinger(x: 0.25, y: 0.5).hold(seconds: 0.5).move(x: 0.75, y: 0.25, durationSeconds: 0.5) }")
    }

    // MARK: pinch / ナビゲーション / fold / 観測

    func testPinch() {
        XCTAssertEqual(dsl(["cmd": "pinch", "scale": 2.0]), "pinchOut()")
        XCTAssertEqual(dsl(["cmd": "pinch", "scale": 0.5]), "pinchIn()")
        XCTAssertEqual(dsl(["cmd": "pinch", "scale": 3.0, "duration": 0.8]), "pinchOut(scale: 3, durationSeconds: 0.8)")
        XCTAssertEqual(dsl(["cmd": "pinch", "scale": 0.25, "duration": 0.5]), "pinchIn(scale: 0.25)")
        XCTAssertEqual(dsl(["cmd": "pinch", "scale": 2.0, "ref": 1]), "pinchOut(\"#login\")")
        XCTAssertNil(dsl(["cmd": "pinch", "scale": 2.0, "ref": 99]), "名指しした対象を全画面のピンチに化けさせない")
    }

    func testNavigationAndFold() {
        XCTAssertEqual(dsl(["cmd": "home"]), "home()")
        XCTAssertEqual(dsl(["cmd": "appSwitcher"]), "appSwitcher()")
        XCTAssertEqual(dsl(["cmd": "back"]), "back()")
        XCTAssertEqual(dsl(["cmd": "fold", "state": "fold"]), "fold()")
        XCTAssertEqual(dsl(["cmd": "fold", "state": "unfold"]), "unfold()")
        XCTAssertNil(dsl(["cmd": "fold", "state": "half"]))
    }

    func testObservationOnlyCommandsAreNil() {
        XCTAssertNil(dsl(["cmd": "refresh"]))
        XCTAssertNil(dsl(["cmd": "frame"]))
    }

    // MARK: serve が受けるコマンド種別の全数

    /// 変換を書き忘れたコマンド種別を落とす。`perform` の `case "…":` の全数(+ handle が先に捌く refresh / frame)が
    /// 「行を持つ表」か「行を持たないと決めた表」のどちらかに載っていること。コマンドを足したらどちらかへ入れる
    /// (行を持たせるなら `LiveOperationDSL.step(for:)` に写像を足し、`minimalRaw` に最小の入力を足す)
    private static let commandsWithoutALine: Set<String> = [
        "refresh", "frame",                                  // 観測だけ
        "launch", "activate", "install",                     // ScenarioCodeGen に対応する行が無い
        "clearAppData",                                      // 対象のアプリが撃つときに決まる
    ]

    private static var minimalRaw: [String: [String: Any]] { [
        "tap": ["ref": 1],
        "type": ["text": "hello"],
        "clear": [:],
        "hideKeyboard": [:],
        "swipe": ["direction": "up"],
        "drag": ["fromX": 1, "fromY": 2, "toX": 3, "toY": 4],
        "doubleTap": ["ref": 1],
        "pinch": ["scale": 2.0],
        "press": ["x": 1, "y": 2, "duration": 1.0],
        "gesture": ["fingers": [["points": [["x": 1, "y": 2, "t": 0], ["x": 5, "y": 6, "t": 0.5]]]]],
        "back": [:],
        "home": [:],
        "appSwitcher": [:],
        "terminate": [:],
        "fold": ["state": "fold"],
    ] }

    private func performCases() throws -> Set<String> {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/fleetest/ApiLiveCommand.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(code.range(of: "private func perform(command: ApiLiveServeCommand"))
        let end = try XCTUnwrap(code.range(of: "throw ServeCommandError.invalidArguments(\"unknown cmd: ",
                                           range: start.upperBound..<code.endIndex))
        let body = String(code[start.upperBound..<end.lowerBound])
        let regex = try NSRegularExpression(pattern: "^        case \"([A-Za-z]+)\":", options: [.anchorsMatchLines])
        let range = NSRange(body.startIndex..., in: body)
        return Set(regex.matches(in: body, range: range).compactMap { match in
            Range(match.range(at: 1), in: body).map { String(body[$0]) }
        })
    }

    func testEveryServeCommandKindEitherHasALineOrIsListedAsHavingNone() throws {
        let known = try performCases().union(["refresh", "frame"])
        XCTAssertGreaterThan(known.count, 15, "走査が perform の case を拾えていない")
        let withLine = Set(Self.minimalRaw.keys)
        XCTAssertEqual(known, withLine.union(Self.commandsWithoutALine),
                       "コマンド種別の全数と、行を持つ表・持たない表の和が食い違う。"
                       + "コマンドを足したなら LiveOperationDSL に写像を足して minimalRaw に載せる(行が無いなら commandsWithoutALine へ)")
        XCTAssertTrue(withLine.isDisjoint(with: Self.commandsWithoutALine))
        for (cmd, fields) in Self.minimalRaw {
            var raw = fields
            raw["cmd"] = cmd
            XCTAssertNotNil(dsl(raw), "\(cmd) が DSL の行を返さない")
        }
        for cmd in Self.commandsWithoutALine {
            XCTAssertNil(dsl(["cmd": cmd]), "\(cmd) は行を持たないはず")
        }
    }
}
