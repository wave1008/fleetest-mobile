# デバイスを用意する

[in English](preparing_devices.md)

クイックスタートで用意したデバイスを増やします。

## 1. 仮想デバイスを増やす

### AIへの指示文

```text
project1 の実行プロファイル ios-run に、Simulator をあと1台追加して。
使える Simulator が無ければ、同じ機種・同じ OS で作成してよい。
追加したら、実行プロファイルのデバイス一覧を報告して。
```

<details>
<summary><b>手動で実行する場合(クリックで詳細表示)</b></summary>

デバイスモニターの「プロファイル」タブで、実行プロファイルの「デバイスを追加」を押します。

CLI では次のとおりです。`--count` は、実行プロファイルの該当 OS のデバイスを全部で N 台にします(今ある分を含みます)。

```bash
../fleetest-mobile/.build/debug/fleetest profile setup --project project1 --platform ios --app-id com.sutec.mobile.ios --auto-device --count 3
```

</details>
<br>

期待する結果:

- Simulatorが1台追加されます（デバイスモニターの「プロファイル」タブで確認します）。

<br>

次へ: [サーバーを確かめる](preparing_app_server_ja.md)

### Link
- [index](../index_ja.md)
