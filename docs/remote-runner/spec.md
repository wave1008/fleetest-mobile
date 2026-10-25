# リモート実行: 用語とセキュリティ前提(RR-0・RR-15)

| 種別 | 範囲 | 読む場面 | 扱わないこと |
|---|---|---|---|
| 正典 | リモート実行の用語(host・machine 等)の定義と、セキュリティ前提・信頼モデル | リモート実行に関わる名前を付けるとき・権限や共有の扱いを変える前 | 設計の経緯と各機能の設計(→ このフォルダの他のファイル) |

リモート実行の全体(コードと文書)が従う定義。設計の経緯は他のファイル(記録)にある。

## RR-0 用語(**この文書と実装の全体でこの定義に従う**。ユーザー決定 2026-08-26)

| 語 | 意味 | 書く場所 | 鍵にしてよいか |
|---|---|---|---|
| **host** | **ホスト名 または IP アドレス**(`user@host` の形も含む。ネットワーク上の実体) | ホスト登録簿の `host`、`--runner`、ssh 宛先 | **よい**(安定した識別子) |
| **machine** | その host に対する**ローカルエイリアス**。このマシンの登録簿だけが知っている名前 | ホスト登録簿の `machine`、プロファイルの `machine`、`--runner` | **原則だめ** —— 頻繁に変わりうるので記録の鍵に使わない。**例外はその machine 自身に関する構成**(登録簿・プロファイルのデバイス割り当て) |

守る規律は4つ:

1. **エイリアスをリモートへ出さない**。転送するプロファイルは `FTCore.RunnerProfileView` が
   「そのランナーから見た姿」へ畳む(そのランナーのデバイスは `machine: "local"`・他機のデバイスは削除)。
   子へ渡すのも `--device-machine local` 固定で、`M1Ultra` 等はランナーのディスクにも引数にも出ない
2. **記録の鍵は host**。`run.json` / `scenarios/*.json` は `host`(ホスト名)を書き、LPT の
   「同じ機械の実績を優先」もこれで照合する。`.fleetest/remote-hosts/<ホスト>.json` も同じ
3. **プロファイルに ssh 実体を書かない**(従来どおり)。プロファイルはプロジェクト資産なので、
   書けるのは `machine`(エイリアス)だけ。`host` はローカル設定(`LocalConfig.remoteHosts`)にだけ置く
4. **手元の台帳(実行プロファイルの `devices`)を「ランナーの視点」で書かない** —— **発行側から
   見た姿**で書き、他機のデバイスには必ず `machine: "<マシン名>"` を書く。ランナーへ渡す姿(`"local"`)は
   転送時に `RunnerProfileView` が畳むので、手で `"local"` と書いてはいけない。
   書くと2つ壊れる: **①ディスパッチが手元へ落ちる**(`fleetest run` は「デバイスが居る機械」で
   宛先を決めるので、向こうのデバイスを手元で探して `no simulator with that UDID`)/
   **②実行プロファイル未選択の監視で、実在する手元のデバイスが消える** —— 台帳を畳む
   `MachineInventory` は (platform, machine, name) の重複を1件にするので、手元に**実在しない**
   udid のほうが (ios, local, 同名) を先に埋めると、本物の起動中シミュレータが「未登録の
   起動中デバイス」として合成され **id 衝突で毎周期落ちる**(実害 2026-09-03。症状は
   `[monitor] Skipped an unregistered simulator due to an id collision: …` が鳴り続け、
   そのデバイスのタイルが offline のまま)。実体(udid/avd/serial)の食い違いは
   `MachineInventory.merge` が警告し、`MachineInventoryTests` がこのリポジトリの台帳全数に当てる

**JSON キーの改名(2026-08-26)**: プロファイルの `devices[].host` → `machine`、マシンプロファイル
直下の `host` → `machine`、ホスト登録簿の `name` → `machine`、記録の `machine` → `host`。
**旧キーはプロファイルの `devices[].host` を除いて読める**(`devices[].host` は読まない = 書くと
手元のデバイスとして扱われる。書き出しは新キーのみ)。

**拡張 ⇄ webview のメッセージも同じ日に揃えた**(こちらは同時に配布されるので旧キーは読まない):
`remoteConfig.hosts[].machine`・`DeviceCommandSource.machine`・`machineProfileInfo` の
`machines[].machine` / `devices[].machine`・`deviceOp`/`deviceOpBusy`/`deviceDownFinished` の
`machine`・`machineDeviceRemove.devices[].machine`・`machineDeviceUpdate.deviceMachine`
(同じ階層の `machine` = マシンプロファイル名と衝突するため別名)・`runProfileSave` の
`fields.devices[].machine`。**片側だけ改名すると黙って壊れる** —— 実際、webview が `host` を
送り拡張が `machine` を読む状態が数時間残り、実行プロファイルのリモート参照が
`machine: "local"` に書き換わった。

**CLI ⇄ 拡張のワイヤも揃えた(ProtocolVersion 9)**: `api monitor` の `machineHost` → `machine`、
`api start-all-devices` のライフサイクル行の `host` → `machine`、`api remote-compat` の
`hosts[].name` → `machines[].machine`(`sshTarget` は本物のホストなのでそのまま)。
**旧キーは読まない** —— この3つは拡張だけが読む口で、版が合っていなければ拡張が起動時に警告する。

**Swift 側の識別子も同時に揃えた**(挙動は不変): `DeviceHostGrouping` → `DeviceMachineGrouping`
(ファイルごと)・`RunDeviceHost` → `RunDeviceMachine`・`DeviceHostRunner` → `DeviceMachineRunner`・
`ApiRunHostFanout` → `ApiRunMachineFanout`・`MachineHostDispatch` → `MachineDispatch`
(`Decision.host` → `.target` = マシン名か `--runner` の生の宛先)・`deviceHost` → `deviceMachine`。
**`host` を残したのは本物のホストだけ**(登録簿の ssh 宛先・ブリッジの宛先 IP・`RemoteHostFacts` の
鍵・fleet 定義の `runs[].host`)。

## RR-15 セキュリティ前提と信頼モデル

**実装前に必ず読む。** 以下は「守るべき前提」であって努力目標ではない。

### RR-15.1 信頼境界の向き — リモートは信頼、リモートの出力は不信

- **信頼するもの**: ランナー機そのもの(自分/自組織のフリート。ssh 鍵で入れる = そのユーザー
  として任意コード実行できる関係。これは設計上そう決めている)
- **信頼しないもの**: **リモートが生成して返してくる中身**。NDJSON・JUnit XML・レポート・
  スクリーンショット・録画・ファイルパスはすべて**外部入力として扱う**。具体的な規律:
  - 回収したレポート(HTML 等)を **webview で無検証に開かない**(RR-11 の「クリック時に
    回収して開く」の実装地点。外部ブラウザで開く / サニタイズする / テキストとして出す)
  - 回収パスは**書き込み前に検証**(展開先が想定ディレクトリ配下に解決されること)。
    回収の rsync には **`--safe-links`**(宛先の外を指すシンボリックリンクを受けない)を付ける
    —— RR-15.3 の既定では `results/` は同僚全員が書けるので、入力は「信頼するランナー」ではなく
    共有ディレクトリとして扱う。**送信側(手元 → リモート)には付けない**(受け手の
    `TestProjects/` 内の正当なリンクを落とすため)
  - 中継 NDJSON は既存の型検証を通してから描画する(不正行は捨てる)
- **RR-7 の適合チェックは認証ではない**。rev・ToolchainFingerprint は
  **リモートが生成した文字列**であり、敵対的ホストは任意に詐称できる。あれは**版スキュー
  検出**であって信頼境界ではない。「適合チェックを通ったから中身を信用してよい」と
  読まないこと
- **唯一の実効的な相手認証は SSH のホスト鍵検証**。だから RR-3 の禁止事項(
  `StrictHostKeyChecking` を無効化しない)は設計上の必須要件

### RR-15.2 ディスパッチ先の決定経路(設定の乗っ取り防止)

- **登録簿は LocalConfig に置く**(RR-13)。VSCode 設定は既定 window スコープで、
  リポジトリの `.vscode/settings.json` から上書きできるため、悪意あるリポジトリを開いて
  普通にテストを実行しただけで**ディスパッチ先を差し替えられる**
- **現行の対処**: 登録簿が LocalConfig へ移り、`fleetest.remote.hosts` / `fleetest.remote.target`
  の VSCode 設定は拡張に存在しない(`package.json` に無い)ので、ワークスペース設定から
  ディスパッチ先を差し替える経路そのものが無い
- 現状これが実害に至っていないのは、未知ホストへの ssh がホスト鍵検証で接続段階に
  失敗し、**rsync 転送(= プロジェクトファイルの送信)に到達しない**ため。
  裏を返せば、**ホスト鍵検証を緩めた瞬間にこれは実害化する**(15.1 の禁止事項と同根)

#### RR-15.2.1 `fleetest.binaryPath` だけは window スコープのまま(境界は Workspace Trust)

同じ「ワークスペース設定からの乗っ取り」の形が **実行ファイルのパス**にもある ——
開いたフォルダの `.vscode/settings.json` が `fleetest.binaryPath` を任意の実行ファイルへ
向けられ、activate 直後の `checkFleetestCompat`(`src/extension.ts`)がそれを spawn する。
既定値 `.build/debug/fleetest` もワークスペース相対なので、**設定を書き換えなくても**
その名前のファイルを置いたリポジトリを開けば動く。

**それでも `"scope": "machine"` にはできない**: 受け手のセットアップ(`ProjectScaffold` /
`InitCommand`)がこの値を `.vscode/settings.json` へ書くので、machine にすると
セットアップ直後の拡張が CLI を見つけられない。

よって境界は **VSCode の Workspace Trust 1本**に置く。`package.json` の
`capabilities.untrustedWorkspaces.supported = false` を**明示的に宣言する**(宣言が無くても
既定で制限モードでは無効化されるが、暗黙に頼ると気づかず外れる)。
`vscode-fleetest/test/workspaceTrust.test.mjs` が宣言の消失と、
「binaryPath を machine にして直す」誤った修正の両方を落とす。

### RR-15.3 共有ラボの identity(用途②を採るときの明示的選択)

RR-1 の用途②(デバイス/実機ラボの共有)は、**認証・帰属・失効の設計を伴わない限り
「同一信頼グループ内での共有」に限る**。全員が同じ UNIX ユーザーの `authorized_keys` に
鍵を足す構成では:

- 実行の帰属が取れない(RR-11 の「誰の run か」表示は実装できない)
- 鍵の失効手順が無い(退職・端末紛失時に個別取り消しができない)
- 各人のプロジェクトファイルが同一マシン上で相互に読める

**採るべき立場を先に決める**: (a) 同一信頼グループ限定と割り切り、RR-11 の占有表示は
「どの run が使用中か」だけにする(「誰の」は出さない)/ (b) ユーザーごとの macOS
アカウントを立てる(デバイス競合と運用コストが増える)。(a) が既定。

### RR-15.4 ランナー機に載る資産

- ランナーには SSH 鍵・ソース・シナリオ・プロファイル・レポート・録画が載る。
  **モード A(FileVault 有効)が既定**(RR-5・RR-14)。**モード B(FileVault 無効+自動ログイン)を
  選ぶ場合の受容リスクを明記して選ぶこと**:
  - Apple silicon ではディスク自体は常時暗号化されているが、**起動できる人はデータに
    到達できる**(鍵が起動時に自動で使える)。したがって**物理的に施錠された設置**が条件
  - 自動ログインは**ログインパスワードを `/etc/kcpassword` に可逆な形で保存する**。
    そのアカウントのパスワードを他所で使い回さない(ランナー専用にする)
  - 発行側から入ってくる SSH 公開鍵に対応する秘密鍵は**発行側**にあるが、ランナー上の
    鍵(ランナーが他所へ入るための鍵)は置かないのが望ましい
- **シナリオ・プロファイルに本番資格情報を置かない**。テスト資格情報も
  スクリーンショット・録画に写り込む(ログイン画面の入力等)。共有ラボでは他人が
  読める場所に残るため、**録画はランナー上に残さず回収後に削除する**
  (**回収に成功したときだけ** `RemoteArtifactCollection.deleteRecordingsCommand` で消す ——
  回収できていない物を消すと唯一の証拠を失う)
- 転送物は最小に保つ(アプリバイナリを送らない既定を維持。RR-12)

### RR-15.5 破壊的操作

- リモートへの `devices down` / デバイス削除・作成は**他人の実行を壊し得る** →
  ホスト側 `showWarningMessage({modal:true})` で確認(RR-11・RR-13)。
  **確認には保持者を添える**(RR-18.7。占有が不明なら何も足さない)
- 転送の `--delete` は宛先を上書きする → `--remote-dir` は登録簿の値のみ(RR-3 禁止事項)

### RR-15.6 ネットワーク露出 — inbound は sshd だけ

**このツールは公開インターフェースに1つも listen しない。** 発行側もランナー機も、
外から繋がれる口は **sshd 1つだけ**で、転送(rsync)・進行表示・成果物回収・ライブ映像は
すべてその ssh 接続の中を通る(映像は `api device-stream` が向こうで配信ヘルパーへ `execv`
して stdout に流す。RR-13)。実際に listen するのは全部ループバック:

| listen するもの | アドレス |
|---|---|
| in-app ブリッジ(シミュレータはホストとネットワークスタックを共有) | `127.0.0.1:<port>` |
| adb server | `127.0.0.1:5037` |
| エミュレータの gRPC | `[::1]` |

**この不変条件を崩さない。** ブリッジやヘルパーを外部アドレスへ bind する変更は、
**認証の無い口をネットワークに開ける**ことと同義になる(ブリッジは任意のアプリ操作を
受け付ける)。遠隔のブリッジが要るという話になったら RR-2 の案 A(却下済み)を読み直す。

運用側の帰結は3つ:

1. **ルーター越し・別ネットワークのランナーは設計上そのまま成立する**(ssh が通ればよい)。
   ポート・踏み台は `~/.ssh/config` に畳む —— `RemoteHostSpec.parse` は `:`・空白・`-` 始まりを
   拒否し、ディスパッチは `ssh` に `-p`/`-J` を付けない
2. **22 を素のインターネットへ晒す形は RR-15.3 の「同一信頼グループ」前提から外れる**。
   VPN 越しにするのが既定の想定
3. macOS の**「すべての着信接続をブロック」は sshd ごと落とす**(ループバックはこの
   ファイアウォールの対象外なので、ブリッジ類は影響を受けない)
