# サーバーを確かめる

[in English](preparing_app_server.md)

SUT Store のサーバー(サーバー + PostgreSQL)は、クイックスタートで fleetest に宣言済みです。宣言したサーバーは、
`fleetest run` のたびに自動で起動し、終わると止まります。仕様の細部は[アプリが依存するサービス](../reference/writing/services_ja.md)です。

## 1. 宣言を見る

### AIへの指示文

```text
project1 で使用するサーバーの情報を教えて。
```

期待する結果:

- server, dbに関する情報が表示されます。

## 2. 起動して確かめる

### AIへの指示文

```text
project1 で使用するサーバーを起動して。
公開ポートの /health が ok を返すことを確かめて。
services down して、結果を報告して。
```

- MCPの許可ダイアログが表示された場合は許可してください。

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

```bash
../fleetest-mobile/.build/debug/fleetest services up --project project1 --profile ios-run
curl http://127.0.0.1:8090/health     # 印字された公開ポートへ
../fleetest-mobile/.build/debug/fleetest services down --project project1 --profile ios-run
```

</details>
<br>

期待する結果:

- 指示通りに実行されて結果が報告されます。

関連:

- [アプリが依存するサービス](../reference/writing/services_ja.md)
- [シナリオから外部へ通信する](../reference/writing/network_access_ja.md)
- [自分で機能を足す](../reference/writing/extending_ja.md)

<br>

次へ: [テストを作る](creating_tests_ja.md)

### Link
- [index](../index_ja.md)
