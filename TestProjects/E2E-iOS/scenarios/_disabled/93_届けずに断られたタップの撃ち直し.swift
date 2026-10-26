// **陽性対照(緑 + 注記 system-alert-retried が正解)**。緑の run ではまず通らない経路を強制的に通す台なので、
// 通常実行に載せる `scenarios/` 直下には置かない。
//
// 守っているもの: ステップ開始の確認(/systemalert)の**後**、撃つ直前に出た権限アラートに遮られたタップは、
// XCUITest ランナーが**届けずに断る**(422 + reason `system-alert-blocked`)ので、登録(iosAlertHandler)があれば
// 閉じてから撃ち直す(`StepExecutor.executeActionRetryingUndelivered`)。
// 規律は「届いたか分からない操作は撃ち直さない・届いていないと確定している操作は撃ち直してよい」(CLAUDE.md)。
//
// 形: `#btn_photos_then_unlock` が `#btn_late_target` を 4 秒止め、1.5 秒後に写真の権限アラートを出す。
// `tap("#btn_late_target")` は開始の確認ではアラートを見ず(まだ出ていない)、有効になるのを待つ間に覆われ、
// 有効になった瞬間に撃って遮られる —— 自然には 100〜300ms の窓でしか起きない競合を毎回起こす。
// **待ちの中で閉じるのはアプリ内の割り込み(irregularHandler)だけ**なので、システムアラートは撃つまで残る。
//
// 期待する結果: 緑。注記 `system-alert-retried`、`#txt_late_target` が `late=tapped`(撃ち直しが届いた)、
// 写真の結果が `photos=denied`(登録のボタンで閉じた)。
// **赤(system-ui-covered / 422)なら撃ち直しが効いていない。緑でも注記が無ければこの経路を通っていない**
// (アラートが開始の確認より前に出た = SUT の秒数の並びが崩れた)。
//
// 回し方: Scripts/e2e-negative.sh --project E2E-iOS --file 93_届けずに断られたタップの撃ち直し.swift

import FTDSL

@TestClass(platform: "ios")
class 届けずに断られたタップの撃ち直し {

    @Test("撃つ直前に出た登録済みのアラートは閉じてから撃ち直す")
    func S0010() {
        scenario {
            scene(1, "有効になるのを待つ間に権限アラートが出る") {
                condition {
                    iosAlertHandler(alert: "*写真ライブラリ*", button: "許可しない")
                    clearAppData()
                    launchApp()
                    tap("#nav_diagnostics", scroll: .down)
                }.action {
                    tap("#btn_photos_then_unlock", scroll: .down)
                    tap("#btn_late_target", waitSeconds: 10, scroll: .down)
                }.expectation {
                    select("#txt_late_target").textIs("late=tapped")
                    select("#txt_photos_result").textIs("photos=denied")
                }
            }
        }
    }
}
