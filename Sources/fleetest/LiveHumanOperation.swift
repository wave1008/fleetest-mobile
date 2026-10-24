// run の実行中にライブ操作(`api live serve`)が受けた人の操作を、`HumanOperationLedger` へ残すための純粋な部分。
// 書き込みは `LiveDeviceLease.recordHumanOperation`、読み手は `ScenarioHost.run` の確定点。

import FTCore
import Foundation

enum LiveHumanOperation {
    /// ref から引いた要素名を label に添えるときの最大文字数。長い文言で台帳・レポートの1行を膨らませない
    static let maxElementNameCharacters = 40

    /// 台帳へ書くか。**run がそのデバイスを使用中(`RunLease.holderPID` が自分以外の生きた pid)のときだけ**。
    /// 普段のライブ操作では台帳を育てない。自分の pid は serve 自身(lease を持つのは run のみ。取り違えの保険)
    static func shouldRecord(runHolderPID: Int32?, ownPID: Int32) -> Bool {
        guard let runHolderPID else { return false }
        return runHolderPID != ownPID
    }

    /// 観測した要素から ref → 表示名(label、無ければ identifier)の表を作る。**value は使わない**
    /// (入力欄の value は人が打った文字列でありうる)
    static func names(from elements: [ElementInfo]) -> [Int: String] {
        var names: [Int: String] = [:]
        for element in elements {
            let raw = [element.label, element.identifier]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            guard let raw else { continue }
            names[element.ref] = String(raw.replacingOccurrences(of: "\n", with: " ")
                .prefix(maxElementNameCharacters))
        }
        return names
    }

    /// 英語の短い事実。**入力した文字列は含めない**(`type` は文字数だけ)。台帳に残さない命令(refresh / frame・未知)は nil。
    /// `elementName` = `names(from:)` で引いた ref の表示名(引けなければ nil = `ref N` のまま)
    static func label(for command: ApiLiveServeCommand, elementName: String?) -> String? {
        func n(_ value: Double) -> String { String(format: "%.0f", value) }
        func seconds(_ value: Double) -> String { FTSeconds.format(value) + "s" }
        func point(_ x: Double, _ y: Double) -> String { "(\(n(x)), \(n(y)))" }
        func target(_ verb: String) -> String {
            if let ref = command.ref {
                return elementName.map { "\(verb) \"\($0)\"" } ?? "\(verb) ref \(ref)"
            }
            if let x = command.x, let y = command.y { return "\(verb) \(point(x, y))" }
            return verb
        }
        func withBundle(_ verb: String) -> String {
            guard let bundle = command.bundle, !bundle.isEmpty else { return verb }
            return "\(verb) \(bundle)"
        }
        switch command.cmd {
        case "tap": return target("tap")
        case "doubleTap": return target("double tap")
        case "press":
            guard let x = command.x, let y = command.y else { return "long press" }
            return "long press \(point(x, y))" + (command.duration.map { " " + seconds($0) } ?? "")
        case "swipe": return command.direction.map { "swipe \($0)" } ?? "swipe"
        case "drag":
            guard let fx = command.fromX, let fy = command.fromY, let tx = command.toX, let ty = command.toY else {
                return "drag"
            }
            return "drag \(point(fx, fy)) → \(point(tx, ty))"
        case "pinch": return "pinch ×" + FTSeconds.format(command.scale ?? 2.0)
        case "gesture":
            let count = command.fingers?.count ?? 0
            return "gesture (\(count) finger\(count == 1 ? "" : "s"))"
        case "type":
            let count = command.text?.count ?? 0
            return "type (\(count) character\(count == 1 ? "" : "s"))"
        case "clear": return target("clear")
        case "hideKeyboard": return "hide keyboard"
        case "home": return "home"
        case "back": return "back"
        case "appSwitcher": return "app switcher"
        case "launch": return withBundle("launch")
        case "activate": return withBundle("activate")
        case "terminate": return "terminate"
        case "clearAppData": return withBundle("clear app data")
        case "fold": return command.state == "unfold" ? "unfold" : "fold"
        case "install":
            guard let path = command.path else { return "install" }
            return "install " + (path as NSString).lastPathComponent
        default: return nil
        }
    }
}
