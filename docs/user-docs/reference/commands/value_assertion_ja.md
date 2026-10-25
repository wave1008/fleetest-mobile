# 値の検証(valueIs, valueContains, …)

[in English](value_assertion.md)

要素のラベルではなく**値**(入力欄の内容など)を検証します。構成は
[テキストの検証](./text_assertion_ja.md)と同じです。

**対象は常に「直前に掴んだ要素」で、これらのコマンドにセレクタは渡しません。**
まず `select`(または `exist` / `tap` など)で要素を掴み、そのうえで検証します。

```swift
select("#email").valueIs("test@example.com")              // 戻り値へチェーン
select("#email"); lastElement.valueIs("test@example.com") // lastElement を明示
select("#email"); valueIs("test@example.com")              // 暗黙(直前に掴んだ要素)
```

引数は、肯定形が `(期待値, requireVisible:, strict:, waitSeconds:)`、否定形と空判定が `(期待値, strict:, waitSeconds:)` です(`valueMatchesDateFormat` は `strict:` を取りません。下の表のとおり)。セレクタを渡す形はありません。

## 関数

| 肯定 | 否定 | 判定 |
|---|---|---|
| `select(selector).valueIs(expected, requireVisible:, strict:, waitSeconds:)` | `valueIsNot(expected, strict:, waitSeconds:)` | 完全一致 |
| `valueContains(expected, requireVisible:, strict:, waitSeconds:)` | `valueContainsNot(expected, strict:, waitSeconds:)` | 部分一致 |
| `valueStartsWith(expected, requireVisible:, strict:, waitSeconds:)` | `valueStartsWithNot(expected, strict:, waitSeconds:)` | 前方一致 |
| `valueEndsWith(expected, requireVisible:, strict:, waitSeconds:)` | `valueEndsWithNot(expected, strict:, waitSeconds:)` | 後方一致 |
| `valueMatches(pattern, requireVisible:, strict:, waitSeconds:)` | `valueMatchesNot(pattern, strict:, waitSeconds:)` | 正規表現(部分一致。全体一致は `^…$`) |
| `valueMatchesDateFormat(format, requireVisible:, waitSeconds:)` | — | `DateFormatter` の書式文字列 |
| `valueIsNotEmpty(strict:, waitSeconds:)` | `valueIsEmpty(strict:, waitSeconds:)` | 空でない / 空 |

比較規則はテキストの検証と同じ「見た目が完全に一致していれば同じ」です(`strict:` で無効化可能)。
詳細は[テキストの検証](./text_assertion_ja.md)を参照してください。

## 例

```swift
select("#email").valueIs("test@example.com")
select("#email").valueContains("@example.com")
```

## 注意点

- 入力欄の内容は `value*` で見てください。空欄は `valueIsEmpty` で判定できます(全 UI フレームワークで空欄の value は空)。
  入力欄の `text` は Compose Multiplatform(iOS)・Flutter(iOS)・React Native で placeholder の文字列を返すので、入力欄に
  `textIsEmpty` / `textIs` を当てないでください。
- 否定系と空判定は可視性を見ません。また、これらのコマンドに `scroll:` はありません
  — テキストの検証と同じ規則です。
- チェーンした検証は、まず掴んだ時点の値で判定し、それで満たしていなければデバイスをポーリングします。
  詳細は[テキストの検証](./text_assertion_ja.md)を参照してください。

### Link
- [index](../../index_ja.md)
