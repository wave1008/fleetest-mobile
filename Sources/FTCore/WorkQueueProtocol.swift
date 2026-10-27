// マシンをまたぐ run の親子の間でシナリオを1本ずつ配る口(`--work-queue`。RR-8.1)。
// 子の stdout へ要求を1行、親から子の stdin へ返事を1行。どちらも `{"ftWork":{...}}` の1行 JSON。
// ssh -tt を通る(端末の行規律に載る)ので、1行は短く保つ(シナリオ ID 1つ)・改行を含めない。

import Foundation

public enum WorkQueueProtocol {
    /// 子 → 親(stdout)。`lane` = `RunWorker.logicalName`
    public struct Want: Codable, Equatable, Sendable {
        public let op: String
        public let req: Int
        public let lane: String
        public let platform: String

        public init(req: Int, lane: String, platform: String) {
            self.op = "want"
            self.req = req
            self.lane = lane
            self.platform = platform
        }
    }

    /// 親 → 子(stdin)。`id` が無く `none == true` = もう無い
    public struct Reply: Codable, Equatable, Sendable {
        public let req: Int
        public let id: String?
        public let none: Bool?

        public init(req: Int, id: String) {
            self.req = req
            self.id = id
            self.none = nil
        }

        public init(req: Int, none: Bool) {
            self.req = req
            self.id = nil
            self.none = none ? true : nil
        }

        /// 配るシナリオ ID。「もう無い」・壊れた返事は nil
        public var scenarioID: String? { id }
    }

    private struct Envelope<Body: Codable>: Codable { let ftWork: Body }

    /// 行の先頭の印。`isWorkLine` の判定と、中継(表示・NDJSON から抜く / 透過する)が共有する
    public static let linePrefix = "{\"ftWork\""

    public static func isWorkLine(_ line: String) -> Bool { line.hasPrefix(linePrefix) }

    public static func encode(_ want: Want) -> String { encodeBody(want) }
    public static func encode(_ reply: Reply) -> String { encodeBody(reply) }

    private static func encodeBody<Body: Codable>(_ body: Body) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Envelope(ftWork: body)),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    public static func decodeWant(_ line: String) -> Want? {
        guard isWorkLine(line),
              let want = decodeBody(Want.self, line), want.op == "want" else { return nil }
        return want
    }

    /// `want` の行・他の JSON は nil(req が無い返事は返事として読まない)
    public static func decodeReply(_ line: String) -> Reply? {
        guard isWorkLine(line), let reply = decodeBody(Reply.self, line),
              reply.id != nil || reply.none == true else { return nil }
        return reply
    }

    private static func decodeBody<Body: Codable>(_ type: Body.Type, _ line: String) -> Body? {
        guard let data = line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(Envelope<Body>.self, from: data))?.ftWork
    }
}
