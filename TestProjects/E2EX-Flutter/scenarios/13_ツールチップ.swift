// 13_ツールチップ.swift
// 確かめる癖: TooltipBox(長押しで Popup = 別ウィンドウに出る・アンカーはアイコンだけ)。

import FTDSL

@TestClass
class ツールチップを出せること {

    // Flutter の Tooltip は指を離した後も showDuration(この SUT は 2 秒)だけ出ている = 両 OS で確かめられる
    @Test("アイコンを押している間にツールチップを確かめる")
    func S0010() {
        scenario {
            scene(1, "開く") {
                condition {
                    launchApp()
                    tap("#nav_tooltip", scroll: .down)
                }.expectation {
                    select("#txt_tooltip_state").textIs("tooltip=hidden")
                }
            }
            scene(2, "押している間は出ている") {
                action {
                    // 押している間にブロックの検証が収まる長さ(負荷の下で exist が 3.3 秒かかり、3 秒では指が先に離れた)
                    hold("#btn_tooltip_anchor", holdSeconds: 6) {
                        exist("これはツールチップです")
                        select("#txt_tooltip_state").textIs("tooltip=shown")
                    }
                }
            }
        }
    }

    @Test("アンカーをラベル(contentDescription)で長押し")
    func S0020() {
        scenario {
            scene(1, "ラベルで長押し") {
                condition {
                    launchApp()
                    tap("#nav_tooltip", scroll: .down)
                }.action {
                    tap("情報", holdSeconds: 1.0)
                }.expectation {
                    exist("これはツールチップです")
                }
            }
        }
    }
}
