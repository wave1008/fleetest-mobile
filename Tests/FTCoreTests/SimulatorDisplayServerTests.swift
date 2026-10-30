import XCTest
@testable import FTCore

final class SimulatorDisplayServerTests: XCTestCase {

    private let blank = RenderCollapseTests.png(shapes: [], statusBar: false)
    /// 上下の帯だけが残る黒い絵(`isUniformBlank` を割る形)
    private let bands = RenderCollapseTests.png(shapes: [FTRect(x: 150, y: 780, width: 100, height: 8)], statusBar: true)
    private let drawn = RenderCollapseTests.png(shapes: [FTRect(x: 20, y: 200, width: 200, height: 80),
                                                         FTRect(x: 20, y: 400, width: 300, height: 120)])

    /// 実時間を偽の時計で進める。`captureCost` は撮影1回の所要
    private func wait(frames: [Data?], captureCost: Double = 0, fired: LockedValue<Bool> = LockedValue(false)) async
        -> (drawn: Bool, captures: [Double], clock: Double) {
        let clock = LockedValue(0.0)
        let captures = LockedValue([Double]())
        let index = LockedValue(0)
        let result = await SimulatorDisplayServer.restartAndWaitForDrawing(
            run: { fired.withLock { $0 = true }; return true },
            capture: { budget in
                captures.withLock { $0.append(budget) }
                clock.withLock { $0 += captureCost }
                return index.withLock { i in
                    defer { i += 1 }
                    return frames[Swift.min(i, frames.count - 1)]
                }
            },
            sleep: { seconds in clock.withLock { $0 += seconds } },
            now: { clock.withLock { $0 } })
        return (result, captures.withLock { $0 }, clock.withLock { $0 })
    }

    func testConstantsArePinned() {
        XCTAssertEqual(SimulatorDisplayServer.drawingWaitSeconds, 30)
        XCTAssertEqual(SimulatorDisplayServer.pollSeconds, 3)
        XCTAssertEqual(SimulatorDisplayServer.command(udid: "U"),
                       ["xcrun", "simctl", "spawn", "U", "launchctl", "kickstart", "-k", "system/com.apple.backboardd"])
    }

    func testBlankFrames() {
        XCTAssertTrue(SimulatorDisplayServer.isBlankFrame(blank))
        XCTAssertTrue(SimulatorDisplayServer.isBlankFrame(bands), "上下の帯だけなら戻っていない")
        XCTAssertFalse(SimulatorDisplayServer.isBlankFrame(drawn))
    }

    func testAFrozenPictureWithContentIsNotFired() async {
        let fired = LockedValue(false)
        let result = await wait(frames: [drawn], fired: fired)
        XCTAssertFalse(result.drawn, "止まった絵は再起動へ回す")
        XCTAssertFalse(fired.withLock { $0 })
    }

    func testAnUnreadableScreenIsNotFired() async {
        let fired = LockedValue(false)
        let result = await wait(frames: [nil], fired: fired)
        XCTAssertFalse(result.drawn)
        XCTAssertFalse(fired.withLock { $0 })
    }

    func testFailedCommandIsNotRecovered() async {
        let frame = blank
        let drawn = await SimulatorDisplayServer.restartAndWaitForDrawing(
            run: { false }, capture: { _ in frame }, sleep: { _ in })
        XCTAssertFalse(drawn)
    }

    func testBandsOnlyFramesDoNotEndTheWait() async {
        let result = await wait(frames: [blank, bands, bands, drawn])
        XCTAssertTrue(result.drawn)
        XCTAssertEqual(result.captures.count, 4)
    }

    func testStillBlankStopsAtTheDeadline() async {
        let result = await wait(frames: [blank])
        XCTAssertFalse(result.drawn)
        XCTAssertLessThanOrEqual(result.clock, SimulatorDisplayServer.drawingWaitSeconds)
    }

    /// 撮影が塞がっても上限は実時間で効く(撮影の予算は残り時間へ絞る)
    func testABlockedCaptureCannotOutliveTheDeadline() async {
        let result = await wait(frames: [blank], captureCost: 10)
        XCTAssertFalse(result.drawn)
        XCTAssertLessThanOrEqual(result.captures.count, 5)
        XCTAssertLessThan(result.captures.last ?? 99, SimulatorDisplayServer.drawingWaitSeconds)
    }
}
