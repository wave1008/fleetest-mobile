// tap(sel, linkText:) の本体。位置の決め方は LinkTextLocator(木 → OCR)。
// 位置が決まったら座標タップの既存経路(executeDirectCoordinateTap)で撃つ
// = in-app が要素の無い点を XCUITest へ回す等の振り分けをそのまま通る

import Foundation

extension StepExecutor {

    func executeTapLinkText(_ linkText: String, element: ElementInfo, snapshot: SnapshotResponse,
                            step: FlowStep, notes: String?, phase: inout PhaseAccumulator) async throws -> StepOutcome {
        var point = LinkTextLocator.treePoint(linkText: linkText, element: element, in: snapshot.elements)
        var ocrLines: [String] = []
        var ocrAttempts = 0
        // OCR へ渡した絵のうちアプリの領域が一色だった枚数(失敗文に事実として添える。読めないのが絵のせいか読みのせいかを分ける)
        var blankShots = 0
        // 読み手が戻るのを待った時間(待った回だけ文言に添える)
        var readerWait: Duration?
        if point == nil {
            // コンパイルを待つ(待った分は DeadlineExclusion が締め切りから差し引く。テキストの可視性検証の OCR と同じ使い方)
            _ = await RegionText.awaitModelCompile(mode: .on)
            let clock = ContinuousClock()
            let stepStart = clock.now
            var roundStart = clock.now
            if let failure = try await ocrRound(linkText, element: element, snapshot: snapshot, phase: &phase,
                                                point: &point, lines: &ocrLines, attempts: &ocrAttempts, blanks: &blankShots) {
                return failure
            }
            // **読み手がその瞬間に失敗していたなら、戻るのを待って読み直す**(読みは操作ではないので撃ち直しても二重にならない。
            // 文字は画面にあるので人なら押せる)。高負荷・FM が死ぬ前の ANE で数分のうちに読めたり読めなかったりした(OI-17)。
            // 上限はステップの外枠の中にもう1周(確かめ + 撮影 + OCR)が収まる間 = `SlowSnapshotBudget` と同じ見積もり。
            // 外枠の無い呼び手(MCP)は待たない
            if point == nil, ocrLines.isEmpty, ocrAttempts > 0, blankShots < LinkTextLocator.ocrShotAttempts,
               commandTimeoutMs != nil, !(await RegionText.readerIsAlive()) {
                let waitStart = clock.now
                var roundMs = Self.ms(clock.now - roundStart)
                while SlowSnapshotBudget.mayRetake(stepElapsedMs: Self.ms(clock.now - stepStart), lastSnapshotMs: roundMs,
                                                   commandTimeoutMs: commandTimeoutMs) {
                    roundStart = clock.now
                    try? await Task.sleep(for: LinkTextLocator.ocrReshotInterval)
                    guard await RegionText.readerIsAlive() else { roundMs = Self.ms(clock.now - roundStart); continue }
                    blankShots = 0
                    if let failure = try await ocrRound(linkText, element: element, snapshot: snapshot, phase: &phase,
                                                        point: &point, lines: &ocrLines, attempts: &ocrAttempts,
                                                        blanks: &blankShots) {
                        return failure
                    }
                    roundMs = Self.ms(clock.now - roundStart)
                    if point != nil || !ocrLines.isEmpty { break }
                }
                readerWait = clock.now - waitStart
            }
        }
        // 何も読めなかったのが読み手の故障か(描かれた絵が1枚でもあったときだけ確かめる。RegionText.readerIsAlive)
        let readerDead = point == nil && ocrLines.isEmpty && ocrAttempts > 0
            && blankShots < LinkTextLocator.ocrShotAttempts
            ? !(await RegionText.readerIsAlive()) : false
        let waitedFact = readerWait.map {
            "waited \(FTSeconds.format((Double(Self.ms($0)) / 100).rounded() / 10))s for the OCR reader to recover"
        }
        guard let point else {
            let read = (ocrLines.isEmpty ? "OCR read no text in the element"
                : "OCR read: " + ocrLines.map { "\"\($0)\"" }.joined(separator: ", "))
                + (blankShots > 0 ? "; the app area of \(blankShots) of the screenshots given to OCR was a single colour"
                    + " (nothing drawn yet, or the capture failed)" : "")
                + (readerDead ? "; \(Self.ocrDeadFact), so this does not show that the link text is missing" : "")
                + (waitedFact.map { "; \($0)" } ?? "")
            return StepOutcome(status: failed(.notFound,
                "cannot find the link text \"\(linkText)\" inside \(TapTargetGeometry.describe(element)):"
                    + " no descendant in the tree has that label, and the text was not found in the element's pixels"
                    + " (\(read); \(ocrAttempts) OCR pass\(ocrAttempts == 1 ? "" : "es"))"))
        }
        // **OCR で決めた点は1つのノードの中の点**。in-app の座標タップは「点を含むノードを activate」するので、
        // 段落ノードの activate(= 押した位置と無関係なリンク)に化ける。inapp-boost モードでは本物のタッチ(XCUITest)で撃つ。
        // 木の子孫で決めた点はそのノード自身なので従来の経路でよい
        if point.source == .ocr, let td = typeDriver {
            let clock = ContinuousClock()
            let start = clock.now
            try await td.tap(x: point.x, y: point.y)
            phase.actionMs += Self.ms(clock.now - start)
            return StepOutcome(status: .passed,
                               driverFallback: Self.joinNotes(notes,
                                   "link text \"\(linkText)\" located by ocr"
                                       + " at (\(Int(point.x.rounded())), \(Int(point.y.rounded())))",
                                   "sent via XCUITest (a point inside one node)", waitedFact))
        }
        let tapped = try await executeDirectCoordinateTap(step: step, x: point.x, y: point.y, phase: &phase)
        return StepOutcome(status: tapped.status,
                           driverFallback: Self.joinNotes(notes,
                               "link text \"\(linkText)\" located by \(point.source.rawValue)"
                                   + " at (\(Int(point.x.rounded())), \(Int(point.y.rounded())))",
                               tapped.driverFallback, waitedFact))
    }

    /// OCR の1周: 最大 `ocrShotAttempts` 回撮って読む。位置が決まるか、文字が読めたら(= その絵にリンクの語が無い)止める。
    /// 戻り値は OCR が固まったときの失敗(それ以外は nil)
    private func ocrRound(_ linkText: String, element: ElementInfo, snapshot: SnapshotResponse,
                          phase: inout PhaseAccumulator, point: inout LinkTextLocator.Point?, lines: inout [String],
                          attempts: inout Int, blanks: inout Int) async throws -> StepOutcome? {
        let clock = ContinuousClock()
        for attempt in 1...LinkTextLocator.ocrShotAttempts {
            if attempt > 1 { try? await Task.sleep(for: LinkTextLocator.ocrReshotInterval) }
            let start = clock.now
            let png = try await driver.screenshot()
            phase.snapshotMs += Self.ms(clock.now - start)
            // 落ちたときの証跡は OCR が見た絵(StepOutcome.evidenceImage。失敗時の絵は判定の後に撮るので別物)
            classifierScreenshotThisStep = png
            if BlankFrameDetector.isUnjudgeable(pngData: png) { blanks += 1 }
            let frame = element.frame, screen = snapshot.screen
            let outcome = await TaskBudget.run(LinkTextLocator.ocrBudget) {
                await RegionText.locateLink(linkText: linkText, pngData: png, frame: frame, screen: screen)
            }
            guard case .value(let located) = outcome else {
                return StepOutcome(status: failed(.timeout,
                    "cannot find the link text \"\(linkText)\" inside \(TapTargetGeometry.describe(element)):"
                        + " OCR did not finish within \(LinkTextLocator.ocrBudget) (the text recognizer is stuck)"))
            }
            attempts += located?.attempts ?? 0
            if let located {
                lines = located.lines
                if let p = located.point { point = .init(x: p.x, y: p.y, source: .ocr); return nil }
            }
            // 文字が読めたのに見つからない = その絵にリンクの文字列が無い(撮り直しても変わらない)
            if !lines.isEmpty { return nil }
        }
        return nil
    }
}
