# テストを作る

[in English](creating_tests.md)

テストは AIアシスタントに作らせます。できあがるのは `TestProjects/project1/scenarios/` 配下の Swift ファイル(シナリオ)です。サンプルアプリ(SUT Store)で順に試せます。

## 1. 基本ルートのテストを作る

最初の1本に向いています。正常に進む流れだけを1本作ります(エラーの場合などは、あとで「既存のテストに足す」で足します)。

### AIへの指示文

```text
project1 で、テストとして カートに追加する.swift を作成して。
基本ルートのテストとして、検索画面で「腕時計」を検索し、商品を開いてカートに追加し、カートにその商品が入っていることを確かめる。
iOS(ios-run)で実行して確かめて。
```

AIアシスタントは、コンパイルとデバイス無しの検証(dry-run)、デバイスでの実行まで行い、結果を報告します。

期待する結果:

- `scenarios/カートに追加する.swift` が作成されます。
- テストが実行され、テストセッションタブにテストの履歴が追加されます。

## 2. 既存のテストファイルにテストを追加する

### AIへの指示文

```text
project1 の カートに追加する.swift に、2本目のテストを追加して。
検索画面で「マフラー」を検索し、商品詳細で数量を3にしてカートに追加し、
カートでその商品の数量が3になっていることを確かめて。
iOS(ios-run)で実行して確かめて。
```

期待する結果:

- 同じファイルにテストシナリオが追加されます。
- テストが実行され、テストセッションタブにテストの履歴が追加されます。

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

自分で書くときは[テストクラスの作成](../reference/testclass/creating_testclass_ja.md)を参照してください。

</details>
<br>

指示した挙動がアプリに無いときは、実際の挙動が報告され、仕様どおりかの判断を求められます。

もっと詳しく:

- [テストクラスの作成](../reference/testclass/creating_testclass_ja.md)
- [セレクタ式](../reference/selector/selector_expression_ja.md)
- [壊れにくいシナリオの書き方](../reference/writing/writing_robust_scenarios_ja.md)

<br>

次へ: [テストを実行する](running_tests_ja.md)

### Link
- [index](../index_ja.md)
