// run の最後の合否の行。

import Foundation

public enum RunTotalsLine {
    /// --work-queue の子が供給で止まり1本も配られなかった回の行。残りは他のマシンが回すので失敗の数には入らないが、
    /// 「All 0 passed」と言わない。**通常の run は未着手が failed に入るのでここへ来ない**
    public static func noScenarioRan(ranCount: Int, workQueue: Bool, abortReason: String?) -> String? {
        guard ranCount == 0, workQueue, abortReason != nil else { return nil }
        return "⚠️ This machine ran no scenario: the run stopped before one was handed out."
            + " The work queue stays with the other machines"
    }
}
