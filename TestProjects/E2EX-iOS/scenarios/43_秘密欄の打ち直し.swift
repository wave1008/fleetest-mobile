// 43_秘密欄の打ち直し.swift
// 確かめる癖: 焦点を取り戻した secure 欄への type(ref) は、本物の打鍵と同じく置き換わる(in-app で追記にならない)。

import FTDSL

@TestClass
class 秘密欄は打ち直すと置き換わること {

    @Test("パスワードを打ち直す")
    func S0010() {
        scenario {
            scene(1, "別の欄を挟んで打ち直す") {
                condition {
                    launchApp()
                    tap("#nav_inputs", scroll: .down)
                }.action {
                    type("#field_password", "abc")
                    type("#field_number", "1")
                    type("#field_password", "de")
                }.expectation {
                    select("#txt_password_echo").textIs("password_len=2")
                }
            }
        }
    }
}
