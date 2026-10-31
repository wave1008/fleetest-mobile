# 再生ケース

`Scripts/replay.py` が撃つ、所見の再現手順。規律は [testing.md「修正の関門」](../../docs/verification/testing.md)。

- 1ファイル = 1所見。`forms` には**所見の手順**と、**同じ故障・前提で経路だけ違う形**(MCP / DSL・ref あり / なし など)を並べる
- 答え合わせは**応答の文言ではなく SUT の表示**(echo)で書く。`expect` は最後の `ft_snapshot` に在るべき文字列、`reject` は在ってはいけない文字列
- 対応する直しを外すと赤になることを、ケースを足すときに1回確かめる(緑の周回だけでは効いているか分からない)。**赤の理由まで読む**(手前の手で落ちた赤・面が出る前に判定した赤は、直しの効き目を示さない)

| 欄 | 意味 |
|---|---|
| `id` | 所見の ID(例 `la-F6`) |
| `finding` | 所見の一行 |
| `platform` | `ios` / `android`(`--udid` / `--serial` で選ばれる) |
| `setup` | 最初に1回撃つ `[ツール, 引数]` の列 |
| `reset` | 周の前に毎回撃つ列 |
| `resetSeconds` | reset の後の間(秒。既定 0.3) |
| `rounds` | 形ごとの周回(既定 10) |
| `redConfirmed` | true = 直しを外した版で赤を確かめた。無ければ緑の行に警告が出る |
| `redNote` | 赤を確かめられない理由と、確かめるのに要る条件 |
| `forms[].name` | 形の名前 |
| `forms[].steps` | `[ツール, 引数]` の列。引数の値 `$ref:<id>` は直近の `ft_snapshot` の木の ref に置き換わる |
| `forms[].settleSeconds` | 答え合わせまでの間(秒。既定 1) |
| `forms[].allowErrors` | true = 手の失敗を食い違いに数えない(断るのが正しい手) |
| `forms[].replyReject` | 最後の手の応答に在ってはいけない文字列 |
| `forms[].replyExpect` | 最後の手の応答に在るべき文字列。**SUT の表示で判定できない形(撃った手が警告を出すべきか)だけに使う**。覆いの下の操作は SUT の画面が変わらないので、応答が唯一の観測 |
| `forms[].replyOnly` | true = 応答だけで判定し、最後の `ft_snapshot` を撃たない(アプリを落とした後の形) |
| `suite` | `baseline` = 回をまたいで比べる固定の課題(`--suite baseline --record <ndjson>`)。**中身を変えない**(変えると前の回と比べられない) |

手順の `$wait`(`seconds`)は画面の動きが終わるのを待つ。`$killApp`(`bundleId`・`seconds`)は故障の注入で、宛先の1台のアプリだけを OS の側から止める。
`$adb`(`args`・`seconds`)は宛先の1台へ adb を直接撃つ故障の注入(Android だけ。ロック・消灯・シェード)、`$adbLater`(`after`・`args`)は
`after` 秒後に adb を撃つが待たずに次の手へ進む(探索の最中に前面を奪う形)。`$` の手は `reset` にも書ける。
