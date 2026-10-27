// ResultsFramesCommand.swift
// シナリオの録画(mp4)からフレームを切り出し、録画時刻とそのとき走っていたステップを添えた
// コンタクトシート(PNG 1 枚)を書く(fleetest results frames)。ffmpeg 不要(AVFoundation)。
// どの時刻を切るかの計画は FTCore.RecordingFramePlan の1箇所。ここは IO と描画だけ。

import AVFoundation
import ArgumentParser
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import FTCore

struct ResultsFramesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "frames",
        abstract: "Cut frames out of a scenario's recording into one labelled PNG contact sheet")

    @Argument(help: "The runID to look up, or \"latest\"")
    var runID: String

    @Option(help: "Scenario ID (Class.method)")
    var scenario: String

    @Option(help: "Test project name (defaults to the only one in TestProjects/, or the default project)")
    var project: String?

    @Option(help: "Device name, when the scenario was recorded on several devices")
    var device: String?

    @Option(help: "Step-number range, e.g. 60-72 or 67 (default: the first failed step)")
    var steps: String?

    @Option(name: .customLong("seconds-before"), help: "Seconds before the failed step to start from (default \(Int(RecordingFramePlan.defaultSecondsBefore)))")
    var secondsBefore: Double?

    @Option(help: "Seconds between frames")
    var every: Double = RecordingFramePlan.defaultEvery

    @Option(help: "Output PNG path (default: inside the run's result folder)")
    var out: String?

    @Flag(help: "Print {file, frames:[{seconds, step, command}]} as one line of JSON")
    var json = false

    func validate() throws {
        if steps != nil && secondsBefore != nil {
            throw ValidationError("--steps and --seconds-before cannot be combined")
        }
        if let steps, RecordingFramePlan.parseStepRange(steps) == nil {
            throw ValidationError("--steps must be <from>-<to> or a single number (got \(steps.debugDescription))")
        }
        if every <= 0 { throw ValidationError("--every must be greater than 0") }
        if let secondsBefore, secondsBefore < 0 { throw ValidationError("--seconds-before must not be negative") }
    }

    /// タイル 1 枚の描画上限(px)。1 枚の PNG の幅・高さとメモリを抑える(最大 RecordingFramePlan.maxFrames 枚)
    private static let tileMaxWidth = 180
    private static let tileMaxHeight = 390
    private static let labelHeight = 30
    private static let columns = 10

    func run() async throws {
        do {
            try await execute()
        } catch let error as ResultsLogError {
            ConsoleOut.err(error.message); throw ExitCode(1)
        } catch let error as RecordingFramePlanError {
            ConsoleOut.err(error.message); throw ExitCode(1)
        }
    }

    private func execute() async throws {
        let testProject = try ScenarioHost.project(named: project)
        let resultsDir = RunResultsStore.resultsDir(projectRoot: testProject.rootURL)
        let (_, runDir) = try ResultsLogReport.resolveRun(
            resultsDir: resultsDir, projectName: testProject.name, requestedRunID: runID)

        let indexURL = runDir.appendingPathComponent(RecordingIndexIO.directoryName)
            .appendingPathComponent(RecordingIndexIO.indexFileName)
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(RecordingIndex.self, from: data) else {
            throw RecordingFramePlanError(message: "this run has no recordings (recordings/index.json is missing)")
        }
        let recordings = index.recordings.filter { $0.scenarioID == scenario }
        guard !recordings.isEmpty else {
            throw RecordingFramePlanError(message: "no recording for scenario: \(scenario)")
        }
        let records = RunResultsStore.records(runDir: runDir).filter { $0.scenarioID == scenario }
        func record(for entry: RecordingIndexEntry) -> ScenarioRunRecord? {
            records.last { $0.worker == entry.worker }
        }

        let candidates = recordings.map {
            RecordingFramePlan.Candidate(worker: $0.worker, failed: record(for: $0)?.passed == false)
        }
        let chosen = recordings[try RecordingFramePlan.selectCandidate(candidates, device: device)]
        guard let timeline = record(for: chosen)?.timeline else {
            throw RecordingFramePlanError(message: "the scenario result has no timeline for \(chosen.worker)")
        }
        let planSteps: [RecordingFramePlan.Step] = timeline.compactMap { entry in
            guard let atText = entry.at, let end = ISO8601Millis.date(from: atText) else { return nil }
            let duration = Double(entry.durationMs ?? 0) / 1000
            return RecordingFramePlan.Step(index: entry.index, command: entry.command,
                                           start: end.addingTimeInterval(-duration), end: end,
                                           failed: entry.status == "failed")
        }
        let options = RecordingFramePlan.Options(
            steps: steps.flatMap(RecordingFramePlan.parseStepRange),
            secondsBefore: secondsBefore ?? RecordingFramePlan.defaultSecondsBefore, every: every)
        let frames = try RecordingFramePlan.plan(steps: planSteps, segments: chosen.segments, options: options)

        let videoURL = runDir.appendingPathComponent(chosen.file)
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw RecordingFramePlanError(message: "recording file is missing: \(videoURL.path)")
        }
        let images = await Self.extract(from: videoURL, frames: frames)

        let outURL: URL
        if let out {
            outURL = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        } else {
            let name = RecordingIndexIO.sanitizedFileName(for: "\(scenario)-\(chosen.worker)")
            outURL = runDir.appendingPathComponent("frames").appendingPathComponent("\(name).png")
        }
        try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard let sheet = Self.contactSheet(frames: frames, images: images),
              let destination = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw RecordingFramePlanError(message: "failed to create the contact sheet")
        }
        CGImageDestinationAddImage(destination, sheet, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RecordingFramePlanError(message: "failed to write: \(outURL.path)")
        }

        if json {
            struct Out: Encodable {
                struct Frame: Encodable { let seconds: Double?; let step: Int?; let command: String? }
                let file: String
                let frames: [Frame]
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let payload = Out(file: outURL.path, frames: frames.map {
                .init(seconds: $0.clipSeconds, step: $0.stepIndex, command: $0.command)
            })
            ConsoleOut.out(String(decoding: try encoder.encode(payload), as: UTF8.self))
        } else {
            ConsoleOut.out(outURL.path)
        }
    }

    /// 切り出せなかったフレーム(区間外・デコード失敗)は nil。ゼロ許容で指定位置の絵そのものを取る
    private static func extract(from url: URL, frames: [RecordingFramePlan.Frame]) async -> [CGImage?] {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: tileMaxWidth * 2, height: tileMaxHeight * 2)
        var result: [CGImage?] = []
        for frame in frames {
            guard let seconds = frame.clipSeconds else { result.append(nil); continue }
            let time = CMTime(seconds: seconds, preferredTimescale: 1000)
            result.append(try? await generator.image(at: time).image)
        }
        return result
    }

    private static func contactSheet(frames: [RecordingFramePlan.Frame], images: [CGImage?]) -> CGImage? {
        let cols = min(columns, max(frames.count, 1))
        let rows = (frames.count + cols - 1) / cols
        let cellW = tileMaxWidth + 4
        let cellH = tileMaxHeight + labelHeight + 4
        guard let ctx = CGContext(
            data: nil, width: cols * cellW, height: rows * cellH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: cols * cellW, height: rows * cellH))

        for (i, frame) in frames.enumerated() {
            let originX = (i % cols) * cellW + 2
            // CGContext は下原点。上の行から並べる
            let originY = (rows - 1 - i / cols) * cellH + 2
            let labelRect = CGRect(x: originX, y: originY, width: tileMaxWidth, height: labelHeight)
            let imageArea = CGRect(x: originX, y: originY + labelHeight, width: tileMaxWidth, height: tileMaxHeight)
            if let image = images[i] {
                let scale = min(imageArea.width / CGFloat(image.width), imageArea.height / CGFloat(image.height))
                let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
                ctx.draw(image, in: CGRect(x: imageArea.minX, y: imageArea.maxY - h, width: w, height: h))
            } else {
                ctx.setFillColor(CGColor(gray: 0.25, alpha: 1))
                ctx.fill(imageArea)
                drawText("no recording", in: imageArea.insetBy(dx: 4, dy: imageArea.height / 2 - 8), ctx: ctx)
            }
            let time = frame.clipSeconds.map { String(format: "%.1fs", $0) } ?? "-"
            let step = frame.stepIndex.map { "#\($0) \(frame.command ?? "")" } ?? ""
            drawText("\(time)", in: CGRect(x: labelRect.minX, y: labelRect.minY + 14, width: labelRect.width, height: 14), ctx: ctx)
            drawText(step, in: CGRect(x: labelRect.minX, y: labelRect.minY, width: labelRect.width, height: 14), ctx: ctx)
        }
        return ctx.makeImage()
    }

    private static func drawText(_ text: String, in rect: CGRect, ctx: CGContext) {
        let font = CTFontCreateWithName("Menlo" as CFString, 11, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.textPosition = CGPoint(x: rect.minX, y: rect.minY + 2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
