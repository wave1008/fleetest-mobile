// `fleetest api run --debug` の stdin → ランナー制御チャネルの中継。
// ランナーの制御チャネル(ScenarioRunControl)は ScenarioHost.run が起動直後に渡すので、それより前に届いた行は貯めて、
// 繋がった時点で順序どおりに流す(貯めずに捨てると、先に送られた continue が失われて pause-on-start のまま止まる)。
// stdin の EOF は「detach」として伝える: 以後だれも再開を送れないので、停止中のランナーを待たせ続けない。

import Foundation
import FTCore

final class DebugStdinRelay: @unchecked Sendable {
    // 不変条件: control の有無・pending・closed は lock の下でだけ触る。貯めた行の流し込みも lock の下で行う
    // (流している途中に届いた行が追い越して順序が入れ替わらないように)
    private let lock = NSLock()
    private var control: ScenarioRunControl?
    private var pending: [String] = []
    private var closed = false

    func receive(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        if let control { control.sendLine(line) } else { pending.append(line) }
    }

    func inputClosed() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        control?.detach()
    }

    func attach(_ newControl: ScenarioRunControl) {
        lock.lock(); defer { lock.unlock() }
        control = newControl
        for line in pending { newControl.sendLine(line) }
        pending = []
        if closed { newControl.detach() }
    }
}
