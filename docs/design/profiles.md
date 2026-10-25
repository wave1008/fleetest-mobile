# 設計: テストプロジェクト・プロファイル・結果・配布

| 種別 | 範囲 | 読む場面 | 扱わないこと |
|---|---|---|---|
| 正典 | テストプロジェクトと実行プロファイル・サンドボックス・相乗りガード・結果のファイル DB・外部パッケージ配布(DS-11・13〜15) | プロファイル・実行の入口・結果の保存・配布を変える前 | 結果 JSON のスキーマ(→ [results-json.md](../results-json.md)) |

プロファイルから実行に至る経路の設計。

## 目次

- DS-11 テストプロジェクトと実行プロファイル
- DS-11.1 テストプロジェクト
- DS-11.2 プロファイルは 2 種の組み合わせ
- DS-11.3 解決規則(ProfileResolver)
- DS-11.4 実行フロー(fleetest run --project P --profile ios-run)
- DS-11.5 インターフェース
- DS-11.6 移行と後方互換
- DS-11.7 シナリオのサンドボックス(Seatbelt・常に有効)
- DS-13 実行の相乗りガードと launch 事前検査
- DS-13.1 MonitorLease(占有ガード、B1)は撤去済み
- DS-13.2 launch 事前検査(LaunchPreflightDriver)
- DS-13.3 ライブ操作(`api live serve`)の宛先決定と門
- DS-14 実行結果のファイルベース DB
- DS-14.1 マージ安全性(設計の核)
- DS-14.2 記録パス
- DS-14.3 分析
- DS-15 外部パッケージ配布と mint 配布の履歴

## DS-11 テストプロジェクトと実行プロファイル

シナリオのフラット配置(リポジトリ直下 scenarios/)と UserDefaults 頼みの実行設定を廃止し、
**テストプロジェクト**(TestProjects/<name>/)と**組み合わせ型の実行プロファイル**(JSON)に移行した。

### DS-11.1 テストプロジェクト

`TestProjects/<name>/` = シナリオ+プロファイル+レポートを持つ器。プロジェクト毎に SPM の
executableTarget `fleetest-scenarios-<name>`(path: `TestProjects/<name>/scenarios`)が対応する。

- **Package.swift のマーカー区間自動生成**: `// === fleetest projects begin/end ===` の区間を
  `fleetest project create/sync` が全置換で再生成する(手編集禁止)。書換後に
  `swift package dump-package` で検証し、失敗時は元内容へロールバック(PackageManifestEditor)。
  マニフェスト内容自体が変わるため SwiftPM のマニフェストキャッシュ stale が構造的に起きない
  (Package.swift 内で FileManager 走査して動的生成する案はキャッシュ stale リスクで却下)
- **受け手が足す依存は区間の外の辞書 `fleetestScenarioDependencies`**(プロジェクト名 → `[Target.Dependency]`)。
  生成するターゲットは `dependencies: [FTScenarioRunner, FTDSL] + (辞書["<name>"] ?? [])` で参照するだけ。
  宣言が無い Package.swift には sync が空で足す(参照だけ生成すると Package.swift がコンパイルできない)。
  辞書のキーがプロジェクトでなければ sync が警告する(綴り違いは黙って依存が空になる)。辞書の名前は既存の
  受け手の Package.swift に残るので改名しない
- プロジェクト間はビルド隔離される(1 プロジェクトのコンパイルエラーが他を止めない)。
  バイナリ毎に objc 走査が分かれるため、シナリオ一覧のプロジェクト別化は発見ロジック無変更で成立
- プロジェクト名は SPM ターゲット名になるため `^[A-Za-z0-9_][A-Za-z0-9_-]*$`(日本語はクラス名側で使う)
- `--project` 省略時の解決: TestProjects/ が 1 つならそれ → LocalConfig.defaultProject → `default` という名前の
  プロジェクト(拡張が起動時に用意する。`ProjectStore.defaultProjectName`)→ 候補一覧付きエラー
- CLI: `fleetest project create <name>` / `project list` / `project sync`
  (手動コピーや git pull 後の TestProjects/ ↔ マーカー区間の再整合)

### DS-11.2 プロファイルは 2 種の組み合わせ

`TestProjects/<name>/profiles/` 配下。共通設定の継承ではなく**部品の参照合成**で表現する。

**アプリケーションプロファイル** `apps/<name>.json` — 最上位キーは `platform` / `autoInstall` / `healthCheckURL` /
`ios` / `android`(それ以外の最上位キーは未知キーとして警告)。
`platform`(`ios`/`android`/`hybrid`。省略 = hybrid)は対象 OS で、**対象外 OS のデバイスは実行時に無視**する
(resolve は1台ごとに警告・全滅ならエラー。`RunProfileScope.roster`/`runDeviceMachines` も同じ判定 =
`AppPlatformScoping` の1箇所。実行プロファイルの JSON は変えない)。拡張のプロファイルタブも同じ意味で絞る ——
`profileInfo.appPlatforms`(アプリ名 → 対象 OS)を実行プロファイルの編集欄が引き、選んでいない OS の
セクションとデバイス行を**表示だけ**隠して名指しで警告する(保存は JSON のエントリを残す)。モニターの
再起動判定の指紋(`runProfileScopeKey`)は `app` も含み、アプリの `platform` の変化も再起動の契機
(`appProfileNeedsRestart`)。
`autoInstall` は最上位のみ(未指定時の既定は
`appPath`/`appPathPhysical` の有無 — パスを書いたのに入らない事故を避ける。止めたいときだけ `false` を明示する)、
`appName`(表示名)・bundle ID(`app`)・`appPath`・`appPathPhysical` は
**ios/android セクションのみ**採用(表示名を OS ごとに書き分けられる):

```json
{ "autoInstall": true,
  "ios":     { "appName": "サンプルアプリ", "app": "com.example.sampleapp",
               "appPath": "~/builds/SampleApp.app",
               "appPathPhysical": "~/builds/device/SampleApp.app" },
  "android": { "appName": "サンプルアプリ", "app": "com.example.sampleapp", "appPath": "builds/app-debug.apk" } }
```

**`appPathPhysical` は実機に配るパッケージ**(省略時は `appPath`)。iOS はシミュレータ用ビルド
(iphonesimulator SDK・未署名)を実機へ入れられず、`0xe8008014 The executable contains an
invalid signature.` で失敗するため、同じアプリでも成果物が2つ要る。**端末ごとにアプリ
プロファイルを分けないための欄**(2026-08-26 ユーザー決定。分けると実行プロファイルまで
二重管理になり、`all` のような混在プロファイルに実機を入れられない)。Android は同じ APK が
両方で動くので普通は書かない。選び分けの規則は `ResolvedAppTarget.packagePath(physical:)` の1箇所。
**ステージング先は `apps/physical/<declared のハッシュ12桁>/<ファイル名>`**(仮想デバイス用は
`apps/<declared のハッシュ12桁>/<ファイル名>`。`WorkspaceAppStaging.installPath`)——
2つのビルドは同名(`dist/ios-simulator/X.app` と `dist/ios-device/X.app`)なのが普通で、
ハッシュの名前空間が無ければ後からステージングした方が相手を上書きし、**片方の端末に必ず誤った
ビルドが入る**。実機用の転送は**その platform に実機が居る run でだけ**行う(100MB 級を
毎回リモートへ rsync しない)。**実機が居るのに `appPathPhysical` が無い iOS の run は
resolve の時点で警告する**(インストール失敗はブリッジ供給の後に出るので遅い)。

`appPath` の相対パスは**リポジトリルート**基準(上例の `builds/app-debug.apk` は `<repoRoot>/builds/...`)。
`~` 展開・絶対パスも可。ビルド成果物は TestProjects/ 外に置くのが普通なためプロジェクト基準にしていない。

**Android は `.apk` のほかに `.apks`(App Bundle 由来のスプリット束)も書ける**(2026-08-19)。
`.apks` は単一 APK ではないので `adb install` に渡せず、**インストールは bundletool へ委譲する**
(`ApksBundle`。無ければ「`brew install bundletool` するか `FT_BUNDLETOOL` を指す」で落ちる)。
選別を自前でやらない理由は実測 —— 実物の `.apks` には variant 違いの master が2つ
(`base-master.apk` / `base-master_2.apk`)あり、正しい方は名前ではなく `toc.pb` の targeting で決まる。
差分判定(下の 4.)は bundletool 抜きで効く: 端末に入っている base/split の**各ファイルの md5 が
この `.apks` のエントリのどれかと一致するか**を見る(大きさで候補を絞ってから展開するので、
79MB を毎回ほどかない)。限界は**足りない split を見つけられない**こと(何が入るべきかは
targeting = bundletool にしか決められない。feature module を足した回だけ入れ直しを取りこぼす)。

`healthCheckURL`(最上位・任意)— アプリが依存するバックエンドの死活確認 URL。実行開始前に
3秒タイムアウトで到達確認し、不達なら警告する(実行はブロックしない)。バックエンド停止中は
アプリが非同期処理でクラッシュし「Application is not running」で全滅して原因が見えにくいため
(2026-07-21 実害)、入口で気づけるようにする。

**実機**(`kind: "physical"`。省略時は `"virtual"` = シミュレータ/エミュレータ)。
識別子は iOS が `udid`、Android が `serial`(実機の serial は起動順で変わらないので直接書く):

```json
{ "devices": [
    { "platform": "ios", "machine": "local", "name": "iPhone 実機", "kind": "physical",
      "udid": "00008130-000A1B2C3D4E5678" },
    { "platform": "android", "machine": "local", "name": "Pixel 実機", "kind": "physical",
      "serial": "14141JEC204922" } ] }
```

- iOS 実機の `udid` は `xcrun devicectl list devices` の **`hardwareProperties.udid`**
  (`00008130-...` 形式。同じ一覧の Identifier 列(UUID)とは別物で、`xcodebuild -destination id=`
  が受け付けるのは前者だけ。Identifier を書いても解決はする)。Android 実機の `serial` は
  `adb devices` の左列(WiFi 接続なら `192.168.1.23:5555` 形式)
- 拡張のデバイスピッカー(「+既存から選択」)が接続中の実機を出すので、手書きしなくてよい
- **iOS 実機も inapp モードに対応する**(開発署名のアプリのみ。ユーザー決定 2026-10-22)。供給が、注入する dylib を
  アプリと同じチームの証明書で署名(`InAppCodeSign`。leaf 証明書の SHA-1 で `codesign`)→ `devicectl` でアプリの
  データコンテナへ置き → `DYLD_INSERT_LIBRARIES` 付きで `devicectl process launch` → iproxy のトンネル(XCUITest 実機と同じ
  `IOSDeviceTransport`)で到達する。**開発署名(get-task-allow)でないアプリは注入できないので、供給がモードを
  `xcuitest` へ黙って縮退する**(`BridgeProvisioner`。`InAppCodeSign.inspect`)。サンドボックスのシナリオは codesign も iproxy も
  起こせないので、**署名・配置・トンネルは供給(親)でだけ**行い、シナリオの起こし直しは署名済み dylib の再コピー + `devicectl`
  起動だけにする(`clearAppData` = 実機では再インストール = データコンテナごと消えるため、起こし直しのたびに再コピーする)。
  inapp モードの実機は in-app ブリッジと XCUITest ブリッジの2本のトンネルを同じデバイスに張る(`IOSDeviceTransport.establish` の `keepPeerPorts` で
  相方のトンネルを消さない)。実機の in-app ブリッジは `FT_BIND_ALL=1` で全インターフェースに bind しトークンを要求する
  (XCUITest 実機と同じ fail-closed)。**ディスパッチした実機**では、運ばれるアプリが発行側の証明書で署名されていて
  ランナー機に鍵が無いことがある。**発行側がステージングのときに同じ証明書で device 用 dylib に署名し、アプリの隣
  (`<App>.app.fleetest-inapp/` = アプリの外なのでアプリの署名を壊さない)に控え(証明書の SHA-1・in-app ソースの digest)
  と一緒に置く**(`PresignedInAppDylib.prepare` ← `RemoteRunDispatcher.prepareWorkspace`)。ランナー機は**自分で署名できない
  ときだけ**、証明書と digest が一致する控えを使う(`InAppCodeSign.inspect(sourceDigest:)`。一致しなければ理由を足して縮退)
- **一括起動(`devices up` / `api start-all-devices` / モニターの「全て起動」)は実機を含む**
  (ユーザー決定 2026-09-08。2026-08-30 の除外を撤回)—— 実機の「起動」= ブリッジの起動
  (iOS は `BridgeProvisioner` の供給、Android は `DeviceBooter.startPhysicalAndroidBridge`)。
  **仮想デバイスの同時起動枠(maxConcurrent=2)とは別の、幅1の専用レーンで走る**
  (`DeviceBooter.buildBootQueue` の `physicalItems`)ので、数分かかるブリッジ供給が
  仮想デバイスのブートを遅らせることはない(2026-08-30 に丸ごと除外していた理由はこれで、
  レーンを分けたことで解消した)。`deviceStarting`/`deviceFinished` も他機と同様に出す
  (拡張のタイルは「ブリッジ起動待機」→「ブリッジを起動中」)。
  **`restart-devices`(down→up)だけは実機を丸ごと対象外のまま** —— 実機は端末を停止できず
  down 側が成立しない
- **「すでに停止している」は停止の成功**(実害 2026-09-10。`DeviceBooter.isAlreadyStopped`):
  iOS は `sim.booted` の guard で成功扱いなのに、Android は serial の解決が `avdNotRunning` で
  throw するため**停止済みのデバイスが「停止に失敗」に化けていた**。全滅だけを失敗として伝えるように
  なった直後、全台停止済みの機械で一括停止が `every device failed to stop` を出した
  (受け手の報告。それまでは何を積んでも ok:true だったので隠れていた)。
  **プロファイルの誤り(avd 未記載)や実機の未接続は失敗のまま** —— 仕分けは純粋関数の1箇所で、
  テストが直接叩く(`DeviceBooterAlreadyStoppedTests`)
- **一括停止(`devices down` の `--profile` 指定時 / `--profile` 無しの掃討(sweep) /
  `api stop-all-devices` / モニターの「全て終了」)は実機のブリッジだけ止める**
  (ユーザー決定 2026-09-08。起動側の規則は変えていない)—— **端末そのものは絶対に落とさない**
  (利用者の電話を勝手に落とさない)。イベントは `deviceStopping`/`deviceFinished` を出さない
  (実機は端末が生き続けるので、出すと拡張のタイルが「停止した」→次の観測で「接続中」に戻り
  ちらつく) —— log イベント1行だけ報告する。分岐は2箇所ある(どちらも同じ制約を満たす):
  - `--profile` 指定時 / `api stop-all-devices` は `DeviceBooter.shutdownOne` の実機分岐
    (spec 単位)。iOS はポート照合でブリッジプロセスを止め、Android は
    `AndroidDriver.stopBridge()` でアプリと adb forward を止める
  - `--profile` 無しの掃討(sweep)は spec を持たない(接続中の全台が対象)ので、
    `DevicesCommand.Down.run` が直接: iOS は `BridgeLauncher.stopAll(skipPhysical: false)`
    (ps 走査でランナーだけ殺す)、Android は `AndroidDeviceCatalog.connectedSerials()` から
    `allEmulatorSerials()` を引いた残り(= 実機の serial)へ個別に `AndroidDriver.stopBridge()`
    を撃つ。**この掃討は以前 `skipPhysical: true` で実機のブリッジを素通りしていたが、
    それでは「全て終了」を押しても実機のブリッジが残るため 2026-09-08 に false へ改めた**
  **モニターの「全て終了」は、拡張が自分のライブ操作の serve を畳んで(終了 = デバイスの印
  `.fleetest/mcp-<鍵>.lease` が消えるまで待って)から撃つ**(`LiveTabHost.suspendServeForSweep`。
  掃討はどの機械のぶんもキューが空いてから `resumeServeAfterSweep` で立て直す)—— ライブ操作も
  MCP と同じ印を書くので、畳まないと全掃討は sweepRefusal で丸ごと断られ、プロファイル指定でも
  そのデバイスだけ残る(実地 2026-09-24 → MN-48)。
  **ブリッジの起動・停止は `fleetest run`・モニタータイルの右クリックメニュー・上記の一括起動・
  一括停止** が担う(ラベルは「ブリッジを起動/停止」)。`bridge down --all` も同じく実機のブリッジを含めて
  止める(明示コマンドなので元から対象)
- **iOS 実機の `state: "booted"` は「端末は接続済みだがブリッジが1本も無い」**の意味
  (`ApiMonitorCommand.iosState`。シミュレータの booted=起動済みとは意味が違う)。実機のブリッジは
  自動供給されないのでこの状態は待っても変わらない ⇒ モニタータイルは**未起動として表示**し、
  右クリックも「ブリッジを起動」を出す(`deviceTiles.js` の `bridgeNotRunning`)。
  Android 実機の booted は「adb は見えるがブート未完了」= 本当に遷移途中なので対象外
- ライブ映像は実機だけ **`fleetest-devicepoll`**(スクショのポーリング → MJPEG)を使う。
  `fleetest-simstream` は CoreSimulator 私有 API で iOS 実機に使えず、`fleetest-androidstream`
  (screenrecord)は Android 実機だと静止画面でフレームが流れないため(詳細 docs/verification/)
- iOS 実機の録画は**静止画のコマ送り**(`StillFrameRecorder`)。`simctl io recordVideo` はシミュレータ専用で、
  macOS 27 は iPhone を AVCaptureDevice として出す DAL プラグインも無い。シナリオ実行プロセスが操作のステップと
  失敗したステップの直後に `/screenshot` を1枚撮って `--still-frames-dir` へ `<epoch ms>.png` で置き
  (**最初の操作の直前にも1枚** = これが無いと動画は最初の操作の後の絵から始まる。シナリオ開始時でなく
  直前にするのはユーザー決定)、
  ワーカー停止時に `StillFrameMovieEncoder` が時刻どおりの mp4 にまとめて既存の切り出しへ渡す。
  **ホストが撮り続ける方式は不採用** —— 撮影と操作が同じブリッジを奪い合い、5 コマ/秒でも `/snapshot` が
  76ms → 114ms に延びた(SE3 実測。上限は約 20 コマ/秒)。子は操作と同じ順番でブリッジを使うので奪い合わない。
  撮影1回 約 50ms をステップごとに払う。**動画の録画を起動できなかったデバイス(シミュレータの試し撮りが空・
  adb が無い等)もこの方式へ切り替える**(`VideoRecordingCoordinator.start`。警告を1行出す)。iOS シミュレータは
  9/17 の修正後もデバイス×実行の約2%で録画が丸ごと消えていた(3/135)。**常用はしない** —— 設定で全デバイスを
  静止画にする `recordStillFrames` を一度置いたが外した(2026-10-04 ユーザー決定): 撮影1枚あたりの実測
  (2026-10-03・M2 Ultra・モニター停止・E2E の「起動と画面遷移」1本 = 14枚・静止画/録画なしを交互に5回ずつ・
  シナリオの durationMs の差 ÷ 14)が iOS シミュレータ 約 112ms(6415 vs 4850ms・+32%)/ Android
  エミュレータ 約 165ms(7939 vs 5634ms・+41%)で、操作と操作の間の出来事(遷移・読み込み表示)も残らない。
  物理 iPhone の「約 50ms」は `/screenshot` 単体の値で、こちらは PNG の書き出しまで含む子の側の実費。
  **救えるのは起動時に気づける失敗だけ** —— 止めたら中身が空だった型は切り替えられない(9/17 以降の3件が
  どちらの型かは判別できなかった。理由は stderr にしか出ておらず、結果に残っていなかった)。**以後は
  `recordings/index.json` の `sourceIssues` に事実として残す**(デバイス・起動時/停止時・録画クラスが観測した
  理由・静止画へ切り替えたか。`RecordingIndex.swift`)。録画まわりの計測の全体は PT-3.31
- 実機で成立しない機能は無効化される: Reduce Motion 自動設定、autoInstall の差分スキップ(コンテナを読めないため
  毎回インストール)。Android 実機は録画(`adb screenrecord`)も従来どおり動く
- `model` / `osVersion` は実機では**表示専用**(登録時に控えるだけで同定には使わない。端末を挿し替えても
  追随しない)。iOS シミュレータの `name`/`osVersion` だけは実体解決に使う値なので意味が違う
- 実機の要件と罠(iOS の署名・LAN/USB 経路、Android の画面ロック)は docs/verification/

**実行プロファイル** `runs/<name>.json` — アプリ+デバイス+実行時設定。
実行プロファイル自体は platform フィールドを持たず、**devices の各要素が `platform`
(`"ios"` / `"android"`)を直接持つ** —— iOS/Android のデバイスを混在させれば両OS同時実行になる。

`devices` の1要素:
- `platform`(必須): `"ios"` / `"android"`
- `machine`: **そのデバイスがある機械**(ホスト名ではなく `fleetest remote machines` の
  マシン名 = このマシンだけのエイリアス)。手元は `"local"`(ツールは常に明示して書く。
  既定は無い)。書けるのはマシン名だけ(ssh の宛先は書けない)
- `name`(必須): デバイスの名前。**一意なのは (machine, name)** なので、別の機械に同名の
  デバイスが居てよい(1つの実行プロファイルで手元とリモートを同時に回せる)
- `enabled`: `false` なら一覧に残すが走らせない(拡張のチェックボックス)。省略 = 走らせる
- 実体: iOS は `name`(シミュレータ自身の名前 = Xcode の Name)+`osVersion`(Xcode の OS Version。
  または `udid` 直指定。`port` で固定も可)、`model`(Xcode の Model)は表示専用。
  Android は `avd`(AVD の ID と表示名(config.ini の avd.ini.displayname)のどちらでも可。
  起動中エミュレータの AVD 名と照合して adb serial に解決。未起動はヒント付きエラー。
  **エミュレータの** serial 直指定は廃止 —— serial は起動順で変わるためプロファイルに書かない)。
  実機は `kind: "physical"` + iOS なら `udid`、Android なら `serial`

**同じデバイスは複数の実行プロファイルに載る**。拡張で名前などを直すと、同じ
(platform, machine, name) を持つ全ての実行プロファイルへ反映される。手で直すときは全部を揃える。

```json
{ "app": "sampleapp",
  "devices": [
    { "platform": "ios", "machine": "local", "name": "iPhone 17 Pro-01", "osVersion": "iOS 27.0", "model": "iPhone 17 Pro" },
    { "platform": "ios", "machine": "local", "name": "iPhone 17 Pro-02", "osVersion": "iOS 27.0", "model": "iPhone 17 Pro" },
    { "platform": "android", "machine": "local", "name": "Pixel 9(Android 15, API 35, APIs)-01", "avd": "Pixel_9_Android_15_API_35_APIs_-01" }
  ],
  "heal": true, "reportDir": "reports", "defaultTimeout": 5,
  "wipeDataOnBloat": true, "wipeDataThresholdGB": 8 }
```

`fleetest profile setup --auto-device` の選定規則(`DevicePicker`。**規則は Swift の1箇所**で、
`api device-catalog` の `recommended` と拡張の「デバイスを追加」の初期選択も同じ関数の結果):
- **iOS**: ランタイムは選択中の Xcode の SDK の版(`xcrun --sdk iphonesimulator --show-sdk-version`。
  `xcodebuild -downloadPlatform iOS` が入れる版)に届く導入済みの最大、届かなければ**要ダウンロード**
  (`IOSRuntimeInstaller`。導入はデバイスを新しく作る直前だけ)。機種はそのランタイムが対応する
  `iPhone-<N>` ちょうど(Pro・Pro Max・Plus・Air・Duo・e・mini・SE・iPad は除く)のうち N 最大。
- **Android**: 機種は最新の `pixel_<N>` / `pixel_<N>a`(同じ N なら無印。Pro・Fold 等は除く)、イメージは tag `google_apis`・ホスト ABI で API 最大
  (導入済み + ダウンロード可能。同じ API なら導入済み)。未導入は `--accept-licenses` のときだけ導入する。

`api device-catalog` の契約(プロトコル版 40): iOS に `downloadableRuntimes`(要ダウンロードのときだけ1件、
`{identifier(導入後の予測値), name, nameLabel, version}`)と `recommended`(`{deviceTypeIdentifier, runtimeIdentifier}`
または null)、Android に `recommended`(`{modelId, package}` または null)。いずれも必須。
`api create-device` は iOS で `--os` がインストール済みに無く、SDK の版の予測 identifier と一致するときだけ
ランタイムを導入してから作る(一致しなければ `runtime not found`)。
`api install-ios-runtime --version <版>` はランタイムの導入だけを行う独立コマンド(NDJSON は `install-system-image` と同形: log* → finished {ok, error}。ok:false は exit 1)。
導入済みなら何もせず ok、選択中の Xcode の SDK の版(`xcodebuild -downloadPlatform iOS` が入れられる唯一の版)と主・副が一致しない版は何も入れずに拒む(判定は純粋関数 `decide`)。
拡張の「デバイスを追加」は iOS のダウンロード候補で、確認の後、単発・バッチとも create-device の前にこれを1回だけ呼び、失敗したら1台も作らずに中止する(Android の `install-system-image` と同じ扱い。バッチで1台ずつ create-device に導入を任せると失敗のたびに再試行するため)。create-device 内の自動導入は profile setup と直接呼びのために残す。

FM(Foundation Models)を使うのは `fmTextVisibilityCheck`(occlusion-guard の FM の段。OCR の段
`ocrTextVisibilityCheck` と独立で、guard はどちらかが true なら走る = FTRuntime が合成)・`screenLooksLike` のどちらかが true のときだけで、いずれも既定 true
(`fmTextVisibilityCheck` は 2026-09-03 にオプトインをやめた)。両方 false の run では FM 呼び出しを
一切行わない(子ランナーへも伝搬し、delegate 自体を作らない)。screenLooksLike を無効にした
run では該当ステップは skip(素通り)になり、FM 利用不可時と同じ扱い。子への伝搬(プロファイル →
子 → 実行時)は `FMToggleWiringTests` が固定する。UI は「プロファイル」タブの実行プロファイル設定
「Advanced Features(Experimental)」セクションに、親チェックボックスの無いフラットな4行
(セレクタの自己修復(`heal`)・OCR の視覚検証・FM の視覚検証・FM の
`screenLooksLike`)で並ぶ。`heal`(既定は `--profile` 実行 true / プロファイル無し false)は
同じセクションに並ぶが他のトグルから独立している(自己修復は FM 機能ではない。
ユーザー決定 → MN-22)。

**guest の /data だけが満杯**(ホスト側の合計は閾値未満)の形は上の肥大化チェックでは拾えず、
`adb install` が `INSTALL_FAILED_INSUFFICIENT_STORAGE` で落ちる(実測 2026-09-28 M1Ultra Pixel-07: 5.8GB 中
587MB 空き。さらに詰まると状態コードの代わりに `Requested internal only, but not enough space` で落ちる)。
**`wipeDataOnBloat` が ON のときだけ**、その失敗を見た `ProfileWorkerFactory.installIfNeeded` がその AVD を
Wipe Data し、パッケージマネージャの応答を待ってから1回だけ入れ直す(`AndroidInstallFailure` /
`AndroidStorageRecovery`。同じ serial で戻ってきたときだけ)。**OFF のときは Wipe せず従来どおり離脱**し、
理由と手動の Wipe(`fleetest api wipe-device`)をログに言う(Wipe は破壊的 = 利用者が自動 Wipe を許した
ときだけ撃つ。ユーザー決定 2026-09-28)。判定は Android 側が出す2つの形で、自前の文言の一致ではない。
`wipeDataOnBloat`(既定 true)は実行開始時に Android AVD の wipe 対象
(userdata/cache/snapshots)合計が `wipeDataThresholdGB`(既定 8。**Play イメージは wipe 直後の
再構築だけで 2〜4GB になるため 4GB 以下はスラッシング**、実測 2026-07-17)超過なら Wipe Data してから
実行する(AndroidDataWiper.swift。ゲストは初期化されるが、アプリは appPath があれば強制
再インストール、ロケールは下記 `locale` が再ブート後に自動適用される)。

手動の Wipe Data はプロファイルタブの**デバイス行の右クリック**から撃つ(Android =
`fleetest api wipe-device --platform android --avd <ID>` = 上と同じファイル集合の削除、
iOS = `--platform ios --udid <UDID>` = `simctl erase`。リモートは `remote exec <機械> --` で回す)。
**識別子だけで撃ち、プロジェクトも実行プロファイルも参照しない**(`api delete-device` と同じ契約)
—— 名前で引くと、リモートではランナー側の複製が古いときに `device not found` で必ず失敗し
(複製の更新はモニターの fan-out 開始時だけ)、操作のたびにプロジェクトを送り直す羽目になる。
**実機には項目を出さない**(識別子から作る spec は必ず仮想デバイスなので原理的に来ないが、
`DeviceWiper.target` が別の呼び手のために拒否を持ち続ける)。**識別子を持たない行にも出さない**
(avd 未設定の Android エントリはそもそも wipe できない)。

**停止を確認できなければ1バイトも消さず、失敗として返す**(2026-08-29 に「中止したのに
ok:true」を踏んだ。デバイスが止まっただけで中身は残り、利用者には成功と見えた)。確認は2つの
どちらかで取れればよい: ①adb の serial が消えた ②**その AVD の qemu プロセスが消えた**
(`AndroidDataWiper.avdProcessPresent`。前方一致では見ない —— 片方がもう片方の接頭辞になる
AVD 名は普通にある)。②を併せて見るのは、まさに kill が遅い状況では adb 側も詰まっており、
①だけだと「本当は止まっているのに確認が取れない」で中止してしまうため。締切は 60 秒
(フリート実行中は 30 秒で取り切れなかった実例がある)。
**しきい値は見ない**(人が選んで撃つので、消すか消さないかの判断はもう済んでいる)。
本体は自動チェックと同じ `AndroidDataWiper.performWipe` / 起動・停止は `DeviceBooter` を通す ——
「停止を確認できたときだけ消す」「稼働中だったデバイスだけ起こし直す」を2箇所に持たない。
拡張はこれを **device ジョブ(op: `wipe`)としてライフサイクルの直列キューへ載せる**
(中で停止と再起動をするので、一括起動や個別の起動/停止と重なると simctl/adb・ブリッジ供給が
競合する)。進行は CLI の NDJSON `wipeStatus`(phase: stopping/rebooting/done/failed)を
run 開始時の自動 Wipe と**同じタイル表示**へ流す。

`recoverCpuFallbackToGpu`(既定 false)を true にすると、実行開始時に**画面凍結で CPU 描画
(swiftshader)へ落ちた Android エミュレータを GPU(`-gpu host`)で起動し直す**
(AndroidGpuRecovery.swift。`dumpsys SurfaceFlinger` で現に CPU の個体だけが対象、1台ずつ直列)。
GPU モードは emulator の**起動引数で固定**されるためプロセス再起動が必須で、該当機1台につき
run 開始が約1分延びる(ゲスト再起動では戻らない)。戻した先で再び凍結すればモニターの watchdog が
また CPU に落とす(DS-12.4 の既知トレードオフ)。UI は「プロファイル」タブの実行プロファイル設定
「CPUフォールバックをGPUに回復する」。拡張側の記憶(`MonitorDeviceOps.cpuRenderNames`)は
モニターが再検出した renderMode を見て `syncCpuRenderNames` が落とす(run 側の復帰は拡張の外で
起きるため、これが無いと次の個別 `start-device` が再び swiftshader で起こしてしまう)。

`enableAnimations`(既定 false)を true にすると、**テスト対象アプリのアニメーションを残す**。
既定(false)では run 開始時に Android の `window/transition/animator_*_scale` を 0 にし、iOS
シミュレータの Reduce Motion を ON にする(アニメーションは a11y イベントを出さないため、静穏判定を
通過した後も絵が動き続けてスクリーンショットが遷移途中を掴む。DS-7 の実害)。判定元は
`FTCore/AnimationPolicy`(実行プロファイル → `FT_ANIMATIONS` → 各ドライバ。CLI は
`fleetest run --profile <名> --set enableAnimations=true`、環境変数直指定でも ON にできる)。

適用は2箇所ある。**ブリッジのコールド起動時**(`AndroidBridge` / `BridgeLauncher`)だけでは
ブリッジが run をまたいで再利用されたときに前の run の状態が残るため、**run 開始時にも毎回同期**する
(Android: `ProfileWorkerFactory.syncAnimationSettings`、iOS: `buildIOSWorkers` の供給直後)。
Android 実機はグローバル設定が**永続的に**書き換わるので、現在値を読んで差分があるときだけ書き、
そのときだけ1行知らせる(エミュレータ/シミュレータは無条件・無言)。iOS 実機はホストから
アクセシビリティ設定を変更できないため対象外(端末側で手動設定する)。

**`adb install` の検証(Play Protect)は install の間だけ切る**(`AdbInstallVerifier`。**実機・
エミュレータを問わず全 Android**に効く —— Google Play 入りの像は Play Protect を持つ。
**ユーザー決定 2026-09-05: テストツールはアプリを Google へ送らない・確認も取らない**)。
実機 Pixel 4a(Android 13)で release 署名の APK を入れると Play Protect が
「Send app for a security check?」を出して `adb install` が無期限に止まった(9.5 分・ログ 0 バイト。
同じ APK でも毎回)。`verifier_verify_adb_installs`(開発者オプション「USB 経由でアプリを確認」)を
0 にすると 4 秒で入り、戻すと再び止まる。元の値(未設定なら `delete`)へ必ず戻す。ダイアログを
押す方式は採らない(ボタンは id 無し・ロケール依存のラベルだけで、送信の選択肢が画面に出る)。
**門は `AndroidDriver.adb` が引数(`install` / `install-multiple` / `shell pm install` 等)で掛ける**
ので、入れる経路を足しても呼び忘れは起きない。例外(bundletool・`AndroidWebViewUpdate`)だけ明示で、
素の `Shell.run` による adb install は `AdbInstallVerifierTests` のソース走査が落とす。
**キルスイッチは実行プロファイルの `playProtectBypass`(既定 true)**: false のときはツールが端末の
設定に1バイトも触らず(`FT_PLAY_PROTECT_BYPASS=0` → `AdbInstallVerifier.bypassEnabled`)、release
署名の APK は端末側のダイアログで止まったままになる —— **それでもツールはダイアログに答えない**。

`homeOnStart`(**既定 true**)は run 開始時に各デバイスへ `home()` を1回撃つ
(`ProfileWorkerFactory.pressHomeOnStart`)。一斉に launch した直後の端末は「描画要求が無いだけ」で
画面が黒いまま止まることがあり、そのままだと凍結と見分けが付かない(2026-08-11 実測: 黒かった5台の
うち4台は入力で戻った)。予防として1回だけ入力を入れる。**デバイスあたり1回**なので実行時間への
影響はほぼゼロ。UI は「プロファイル」タブの実行プロファイル設定。

**XCUITest ランナーはタップ・ダブルタップ・長押しの前の quiescence 待ちを既定で飛ばし、整定は木の観察で行う**(操作後の
`captureSettled`。ユーザー決定。4 SUT の A/B で退行無し)。**スワイプ(スクロールを含む)は待ちを残す**(慣性の終わりを木では
見届けられない = E2E-RN S0090 が 6 回中 4 回落ちた)が、操作の間は待ちの上限を 6 秒に縮める(`QuiescenceWait.quiescenceCapSeconds`)。
**DSL の `settle: false`(コマンド1回だけ、操作後の整定をすべて飛ばす)**: スワイプ(スクロールを含む)・/drag・/pinch・/rotate・/systemui/*・アプリスイッチャー・ホームの XCTest の待ちは
`settle: false` のときだけ飛ばし、それ以外は上限 6s に縮める(v176 から。それまで /drag と /systemui/* は縮めず、知らせを返さないアプリで 60s 止まってランナーが起動し直された。走査 `RunnerQuiescenceCapCoverageTests` が上限の外の操作を落とす。/type・/clear の中の焦点のタップは待ちを飛ばす = 直後の打鍵の前の待ちと二重になり、/type 1回が 24s でホストの上限 20s を超えていた。v177 から /type の中だけ操作の**後**の待ち(isPreEvent == false)も飛ばす = `QuiescenceWait.capping(skipPostEvent:)`。完了は読み返しが値で確かめるので二重で、知らせを返さないアプリで /type が 7.8〜12.9s → 0.9〜1.8s)(/type・/clear・/pressEnter は前の待ちを飛ばさないが、v175 から待ちの上限だけ 6s に縮める = `QuiescenceWait.capping`。キーボード出現待ちを quiescence に頼るため飛ばせないが、落ち着かないアプリでは打鍵ごとに XCTest 既定の 60s を待っていた)。契約:
- **ワイヤ**: ホストが該当ステップの実行中、ブリッジへの HTTP リクエストに `X-FT-Settle: 0` を付ける(`BridgeAPI.settleHeader`)。
  ホスト側は `FlowStep.settle` → `StepExecutor.execute` が TaskLocal `SettleOverride.skip` に載せ、ブリッジクライアントが読む。
  ブリッジの版は iOS `bridgeProtocolVersion` 165・Android `VERSION_CODE` 89。
- **ヘッダはそのステップの全要求に付く**ので、複数回スワイプするコマンド(スクロール探索・端送り)では**1本ごとのブリッジ側の待ちも飛ぶ**。
- **各ブリッジの読み先**: XCUITest ランナーは XCTest の完了通知の待ち(`QuiescenceWait`)と、次の snapshot での木の整定の予約
  (`settlePending` → `captureSettled`)を外す。**GET /snapshot ではヘッダを見ない** —— `settlePending` を立てたのは前の操作(前のステップで
  ありうる)なので、見ると前の操作の整定を打ち消す。in-app ブリッジは `InAppSettle` と描画追従の控え(`renderBefore`)・
  Android ブリッジは `settle()`(静穏待ち)と `/scrollAction` の静止待ち。ホストは操作後の木の整定(`settledSignature` / `settleAfterScroll`。
  飛ばしても次の解決はキャッシュ迂回にする)と、次のステップへ持ち越す待ち(`type` 後のキーボード確認・Android の `hideKeyboard` の待ち)を飛ばす。
- **残すもの**: 結果を確かめる待ち(回転・home の到達・`type` の読み返し・焦点待ち・起動の準備待ち)と操作前の待ち。複数回スワイプするコマンドの
  中でホストが行う計測(`scrollToBottom` 等の端の判定・スクロール探索のループ)は残し、ホスト側で省くのはコマンド最後の整定だけ。
- 慣性のあるスクロールの直後の操作がずれうるので、使うかどうかは書き手が選ぶ(オプトイン・全体設定は無い)。
**quiescence(XCTest の完了通知の待ち)と fleetest の整定(木の比較)は別物** —— `settle: false` はこの両方を飛ばすが、`settle` を省略したときの
タップ系は XCTest の待ちを飛ばしても整定をホストが木で行う。
計測値は PT-8。**XCTest の完了通知の待ちを外すのは XCUITest ランナーだけ**
(`Runner/FleetestRunnerUITests/QuiescenceWait.swift`。in-app ブリッジには quiescence の概念が無い)。

`iosPreActionPing`(**既定 true**)は **interop WebView 画面(domInterop モード)の委譲イベント
直前に、ランナーへ木を1回読ませてから撃つ**(`WebViewDelegatingDriver.pingDelegatedBeforeEvent`)。
attach したままの XCUITest セッションは、ランナーに問い合わせないまま数秒置いた直後の
座標イベントを **200 を返しつつ届け損なう**(実測 約13%。ページは pointerdown すら見ない。
機構は非公開で特定できておらず、観測に立脚した防御。A/B と経緯は docs/verification/
§interop WebView)。時間閾値にしないのは、短いギャップでも確率的に落ちる実測があり安全な
境界を引けないため。false は `FT_PRE_ACTION_PING=0` として注入される(`FTCore.RunEnvironment`
が唯一の定義元 —— ProfileRunner / ApiRunCommand の profile 有無2経路 / Fleetest.swift の
profile 無し経路と、fleetest-mcp の resolveProfileTarget から呼ばれる)。**効くのは inapp モードの
domInterop 経路だけ**(委譲モード・xcuitest
モードは毎ステップ ランナーが働くので元から出ない)。コストは該当画面のイベント1回につき
約 +0.4 秒で、スイート全体では並列に隠れて差が出ない(25周比較 88.9s vs 90.0s)。
UI は実行プロファイル設定の iOS セクション(iOS のモードが inapp のときだけ表示)。

`record`(既定 true。`--profile` を使わない実行だけは false)が true のとき、各ワーカー(デバイス)で run 全体を録画し続けつつ
(iOS: `simctl io recordVideo` の .mov / Android: `screenrecord` の 180 秒セグメント群)、
ファイナライズ時に**テスト関数(シナリオ)ごとに1本の mp4**へ壁時計区間で切り出して
`<runDir>/recordings/` に保存する(AVAssetReader/Writer で該当区間だけ半分解像度+低 bitrate の
H.264 に再エンコード。VFR ソースの区間頭フレーム欠落は直前サンプルの retime で補う)。拡張側との
契約は `recordings/index.json`(schemaVersion 2。VideoRecordingCoordinator.swift・
RecordingIndex.swift・RecordingWallClock.swift)。録画自体の失敗は run を失敗させない。

**録画できることを実物で1本確かめてから本番を始める**(2026-08-26)。`simctl io recordVideo` は
**端末側に録画セッションが刺さっていても "Recording started" を出し、0 バイトの .mov を作り続ける**。
気付けるのは run の終わり(切り出し)で、その run の録画は全部失われる。そこで
`IOSSimulatorVideoRecorder.start()` は ①同じ udid の stale な client を pkill(従来)
②**1 秒だけ録って閉じ、ファイルが空でないかを見る**(新規)—— 空なら「この端末は録画できない」と
理由と復旧手順(デバイスの停止→起動)を出して**そのデバイスの録画だけ諦める**(run は続ける)。
**「ファイルが育たない」は検知に使えない** —— 正常な録画でも閉じるまで 0 バイトのまま
(実測: 8 秒間ずっと 0、停止した瞬間に 21KB)。だから*閉じてから*大きさを見る。

**失敗しても index は残す**(2026-08-26)。集計欄は2つあり**別のことを言う**:
`clipsAttempted`/`clipsFailed` は「録れた動画から切り出せなかった」、
**`sourcesFailed` は「そもそも録れていない」**(録画プロセスは起動したのに、読めるファイルが
1本も残らなかったワーカー数)。以前は後者のとき index を書かずに `recordings/` ごと消していたため、
**録画が全滅した run は拡張の録画タブから黙って消え、「録画していない run」と区別が付かなかった**
(実害: `simctl io recordVideo` が 0 バイトの .mov を作る Mac で、その機械のセッションだけ
一覧から消えた。fleetest ではなく環境側の不調だったが、画面からは追えなかった)。
拡張は行に「録画失敗 N 台」を出し、再生ビューでは**「録れていない」を「切り出せなかった」より
優先して**理由に出す(直す場所が simctl / screenrecord 側なのか、エンコーダ側なのかが変わるため)。

**切り出しは全シナリオが終わってからまとめて行う**(`VideoRecordingCoordinator.finish`。方式は1つだけ = ユーザー決定。
シナリオごとに区切る方式・この Mac の run がすべて終わってから背景で切り出す方式も作って比べたが、ハードウェアで切り出せる
状態では壁時計の差が数秒で、区切る方式は各シナリオの先頭 約 0.5 秒が欠け、区切りと停止の SIGINT が重なると最後のファイルが
壊れる不具合も出たので外した。比較の数値は PT-3.37)。

**各シナリオの直前に録画が撮れていることを確かめる**(`prepareScenario` → `DeviceVideoRecorderSession.ensureRecording`。
シナリオの区間を始める前に呼ぶ = 待ちをシナリオに数えない)。止まっていれば撮り直して開始を確かめ、撮り直しても始まらなければ
そのワーカーの残りを静止画方式へ切り替える(テストは止めない・それまでの動画も切り出す)。iOS は "Recording started" を、
**Android は端末上の録画ファイルが大きさを持ったこと**(screenrecord は最初のフレームを符号化してから書き始める)を開始の印にする
(上限 10 秒)。確かめられなかった Android の録画は止め、自動では撮り直さない(撮り直すかは次のシナリオ前の確認が決める)。
**防げないもの**: シナリオの最中に止まった録画(次のシナリオ前に撮り直す)・Android の 3 分ごとの切り替えの間(約 0.2〜0.3 秒)。

**エンコーダはハードウェア優先・2 並列**(ユーザー決定)。実測(M2 Ultra・E2E の実クリップ 116 本): ハードウェア 2 並列 18.2 秒 /
ソフトウェア 2 並列 79.5 秒(ソフトウェアは別プロセス `VTEncoderXPCService` で総処理量が並列度でほぼ増えない。混ぜると遅くなる)。
出力はハードウェアが約 1.22 倍大きく、OCR で読める文字数は同じ(39 本)。ソフトウェアへ切り替えるのは次のとき(**その run の残り**):
- ハードウェアの**失敗・固まりが1回でも出た**(壊れる前に手を引く = 故障の前には失敗がぽつぽつ出ていた。素材のせいでも切り替える)
- 台帳(下)が**新しい故障**を示している(最初から撃たない)
- **ライブ更新の iOS の h264 配信がこの Mac で動いている**(`LiveEncodeStreams`)ときは1本目だけを先にハードウェアで切り出し、
  速さ(クリップ長 ÷ 所要)が `minHardwareSpeedWhileStreaming`(8 倍 = ソフトウェアの典型的な速さ)未満なら残りはソフトウェア
  (配信が取り合って余力が無い。実測: 配信 14 本でハードウェアの中央値 28 倍・最遅 11 倍 = 切り替わらない)

ハードウェアの期限は `max(10秒, クリップ長 / 4)` で、超えたクリップはソフトウェアで切り出し直す。切り出しごとに短い UUID 名の
一時フォルダを作り、その中へ最終名で書く。成功した出力だけ recordings/ へ移し、一時フォルダは片付ける(期限超過した敗者 task の
出力は公開しない)。エンコーダはスロットを取った後に決める。ソフトウェアの期限は
`max(60秒, ソース総尺)` で、超えたらエンコーダ無応答とみなして**その run の残りクリップを断念**する(敗者 task に触れない =
`cancelWriting` は固着した VT セッションのロックで共倒れし得る)。**期限内の失敗(`-11821 Cannot Decode` 等)は1回だけソフトウェアで
やり直し**、2回とも失敗したクリップの元の録画は消さずに残して場所を出す(同じソースへの切り出し 200 回で再現しなかった)。
録画が1本も重ならないシナリオは黙って飛ばさず失敗として数える。VFR のソースは最後に画面が変わった所でファイルが終わるので、
録画プロセスの終了を観測した時刻(`RecordingSource.closedAt`)まで、素材ごとに最終フレームを伸ばしてから連結する。
位置計算と index.json もこの尺を使い、録画が止まっていた素材間の欠落だけを詰める。

**ハードウェアエンコーダの死活は機械全体の台帳 `FTCore.VideoEncoderLiveness`**(`~/.fleetest/video-encoder-liveness.json`。
生 / 死 / 不明の3値・120 秒より古いは不明)。AppleAVE が**マシン全体で**壊れる(全部 `-17691` / 合成映像も固まる)ことがあり、戻すのは
再起動だけで、Simulator の録画と iOS の配信も巻き添えになる(原因は未特定 → MN-86)。書き手: 切り出し(成功 = 生・
期限超過 = 死。失敗の後は合成映像の確かめ `HardwareEncoderProbe` を run につき1回撃ってその結果を書く = 切り替えの判断には使わない)と
`api host-metrics --video-encoder-probe`(拡張のモニターだけが渡す。台帳が 60 秒より古いときだけ確かめる)。モニターはホスト負荷の行に
「⚠︎AVE」を出す(死のときだけ)。**故障の兆候は履歴に追記する**(`VideoEncoderHistory` = `~/.fleetest/video-encoder-history.ndjson`。
切り出しの失敗・固まり、台帳の死への変わり目・死からの回復。起動の識別子と起動からの経過つき = 監視して改善する方針・ユーザー決定)。
注入は `FT_FAKE_VIDEO_ENCODER_DEAD=1`(ハードウェアに触らずに死を返す)。
診断手順は docs/verification/triage.md「録画(record:true)の検証」。

録画の付随設定(すべて `record: true` のときのみ意味を持つ): `recordFailuresOnly`(既定 false)
は true で成功したシナリオのクリップを保存せず失敗(frozen 含む)分のみ残す。`recordBitrateKbps`
(既定 1000)は再エンコードの bitrate(kbps)で AVVideoAverageBitRateKey と Android screenrecord
`--bit-rate` の両方に適用。既定は 2026-10-04 の実測で 1500 から下げた(iOS のクリップが 15〜35% 小さくなり、
OCR で読める文字の割合に差が見えない。500 は iOS の半分解像度で誤読が 2〜5 倍。条件と数値は
PT-3.31)。`recordFullResolution`(既定 false)は true で半分解像度化(iOS 再エンコード
時の縮小・Android `screenrecord --size`)をスキップしフル解像度のまま出力する。

`locale`(既定 "ja_JP")は Android エミュレータのブート完了時(`api start-device` と wipe 後の再起動)に
適用される。**Play イメージは root/`setprop`/`settings put system system_locales`/emulator の
`-change-locale` が全て無効**(実測 2026-07-17)のため、適用はブリッジの `POST /locale`
(BridgeRouter.java: shell 権限借用 CHANGE_CONFIGURATION + IActivityManager.
updatePersistentConfiguration、要 `hidden_api_policy=1`=ブリッジ起動時に自動設定)で行う。
一致時は no-op、変更は再起動を跨いで永続。iOS には影響しない。`api start-device` 経由の既定は
DeviceBooter.defaultLocale(実行プロファイルの locale が届くのは wipe 再起動経路のみ)。

### DS-11.3 解決規則(ProfileResolver)

1. **デバイス解決**: 実行プロファイルの `devices` のうち enabled なエントリをそのまま使う ——
   各エントリが `platform`/`machine`/実体(`name`/`osVersion`/`udid`/`avd`/`serial` 等)を直接持つので、
   「これは現在のマシンのデバイスか」で絞り込む工程は無い。**どのマシンへ実行を送るかは別の層が
   決める**(`FTRemote.RemoteDispatch` / `DeviceMachineGrouping` がホストごとのサブ実行に分ける。
   DS-13)。enabled なエントリが1つも無ければエラー(`noEnabledDevices`)。(machine, name) の
   重複はエラー(`DeviceMachineGrouping.firstDuplicate`。別マシンの同名は許す)。実体を持たない
   エントリ(`DeviceSpec.lacksConcreteTarget`)は**止めずに警告**する(iOS は名前解決の既定へ
   落ちて別のデバイスで黙って走ることがあるため。既定に頼っている既存プロファイルを赤にしないための
   選択)。Android の serial 解決(`AndroidDeviceCatalog.resolveSerial`。**AVD ID 完全一致**での
   み serial を引き、不一致は throw)はこのあとのデバイス供給の段(DS-11.4 手順3)で行う ——
   → **profile 外のはぐれエミュレータは profile 実行には一切混入しない**(ワーカー0件)。
   ただし serial 未指定の対話コマンド(`ft_status`/`ft_snapshot` 等)は接続中デバイスが
   **1台のときだけ**それを自動採用する(2026-08-06。複数なら AVD 名付きで列挙してエラー)。
   はぐれ Android 機が1台混ざっていると、それが唯一の候補になって診断画面がそれになりうるので、
   規模ランの調査前に `adb -s <serial> emu kill` で掃除する(2026-07-16)
2. **アプリ解決**: デバイスの platform セクション(ios/android)から。`app`(bundle ID)必須
3. **並列数 = 解決後のデバイス数**(maxParallel は存在しない)。プラットフォーム毎にワーカーを立て、
   RunOrchestrator の platform 別キューで両OS同時並列実行
4. platform 未指定(@TestClass / @Test 両対応)のシナリオは iOS ワーカーがいれば ios キューへ。
   **platform を宣言していて、この run がその OS を回さないシナリオはキューに入れず skipped**
   (`PlatformApplicability`。ProfileRunner / `api run` の profile 経路だけ。
   `--port` / `--serial` 直指定は回す OS の集合を宣言しないので対象外)
5. 未知キーは警告(タイポ検出)。相対パスのチルダ展開あり。基準は用途で異なる:
   `appPath` はリポジトリルート基準、`reportDir` はプロジェクトルート基準(RunProfile.resolve)
6. 合成後は必須検証済みの `ResolvedProfile` になり、実行コードはこれだけを見る

### DS-11.4 実行フロー(fleetest run --project P --profile ios-run)

1. **`--set` は読み込んだ `RunProfileDocument` へ合成の前に当てる**(`ProfileResolver.resolve` の
   `overrides:`)。**解決後の `ResolvedProfile` を上書きしない** —— 欄ごとに上書きを配線すると
   足し忘れが生まれ、実際に「チェックボックス 20 個に対し CLI は 4 個・形は3通り」まで育った
   (MN-16)。文書に当てれば全欄が自動で追随する。
   `--report-dir` 等の専用フラグは従来どおり解決後に効くが、**同じ意味のキーを `--set` でも
   渡したらエラー**(どちらかを黙って勝たせない)
2. `ScenarioHost.build(project:)`(ホスト 1 回。入力の BuildFingerprint が前回ビルドと一致すれば
   スキップ=無変更の再実行で no-op build ~2.6s を払わない。PT-3.2)。
   `fleetest api run` の並列実行経路ではワーカー供給(3〜4)をビルドと並行に開始する
3. **デバイス供給**: iOS は BridgeProvisioner がポート範囲(8123〜)を短タイムアウトで並行スキャンし、
   /status のデバイス名 × simctl の UDID 照合で**稼働中ブリッジを再利用**、不足分は空きポートを採番して
   BridgeLauncher(xctestrun FT_PORT 注入)で起動・waitUntilReady。シミュレータの新規作成はしない
   (同名複数の曖昧時は UDID 明記を推奨)。Android は AndroidDeviceCatalog で avd 照合。
   コールド起動は「プランニング(ポート採番、直列)→ 共有ビルド(dylib/xctestrun、直列)→
   起動(デバイス単位で並列。inapp モードの 2 ブリッジはデバイス内直列)」(PT-3.2)。
   **run は終了時にブリッジを停止しない**(常駐を残すのが仕様。次の run が再利用する)
4. **自動インストール**: `appPath` あり+`autoInstall`(**未指定の既定は appPath/appPathPhysical の有無**。
   `false` 明示で opt-out)→ オーケストレータ投入前に各ワーカーへ並行 install
   (差分判定=installedIsCurrent も並列。失敗ワーカーは離脱、残ワーカーがキューを引き継ぐ)。
   **ライブ操作(`api live serve` の install)も同じ差分判定**を通す(`ApiLiveServe`。無条件に入れ直すと
   そのたびにアプリが終了し、状態が消える)
5. RunOrchestrator で並列実行。ワーカーラベル=デバイスの論理名。レポートは
   `TestProjects/<P>/reports/`、ロケータの指紋は `--project-dir` 経由で `TestProjects/<P>/.fleetest/` に分離
   - **シナリオの振り分けは platform 別の静的分配**(ワークスティールではない)。
     `ProfileRunner` は iOS デバイスが1台でもあれば既定 platform を `ios` にし、
     `RunOrchestrator` は `@TestClass` の `platform:` **未指定**シナリオをその既定 platform の
     キューにだけ入れる。自分の platform のキューが無いワーカーは1本も受け取らずに終わる。
     → **両OSのデバイスを供給する実行プロファイル(`all` 等)を使っても、platform 未指定の
     シナリオは片方の OS でしか走らない**(供給された他方のデバイスは空回り)。
     platform 非依存に書いたシナリオを両OSで回すなら `--profile ios-run` と `--profile android-run` を
     別々に実行する。シナリオ数や負荷には依存しない決定的な挙動(2026-07-22 実測)
6. `defaultTimeout` は ScenarioHost が子へ渡す `--tunables`(`RunTunables` の JSON)→ FTDriveCore に渡り、
   exist/textIs/valueIs の `waitSeconds: Double? = nil` の既定値になる
7. ワーカー構築(供給+インストール)は ProfileWorkerFactory(FTAndroid)に共通化され、
   CLI(ProfileRunner)と `fleetest api run`(VSCode 拡張など UI 入口向けの共通経路)が共用する

### DS-11.5 インターフェース

- CLI: `fleetest run [--project P] [--profile 名] [--scenario ...]`(profile 未指定時は従来どおり
  手動 --port/--serial)、`fleetest profile list`(解決結果と整合チェック)
- **GUI(SwiftUI 版 `fleetest-gui`)は 2026-07-10 に削除**。対話的 UI は VSCode 拡張
  (`vscode-fleetest/`)に一本化した。プロジェクト/実行プロファイルの選択はコマンドパレット
  (「fleetest: プロジェクトを選択」「fleetest: 実行プロファイルを選択」、`fleetest.project` /
  `fleetest.profile` 設定)、プロファイル JSON の編集・保存時検証は問題パネル(Diagnostics)で行う。
  **実行/デバッグ実行は `fleetest.profile` 未指定なら実行せず、「デバイスモニター」タブでの指定を促す通知
  (ボタン「デバイスモニター」タブを開く = `fleetest.showDeviceMonitor`)を出す**(未指定だとブリッジ自動供給の無い
  直接ポート接続に落ち、全シナリオが接続拒否で即失敗するため。ユーザー決定 2026-07-26。
  dry-run は実デバイスを要さないため除外)
  内部的には CLI と同じ `fleetest api ...` サブコマンドを呼ぶため、解決ロジック(ProfileResolver 等)
  は CLI と共通(詳細は [vscode-fleetest/README.md](../../vscode-fleetest/README.md))
- MCP: `ft_list_scenarios` / `ft_run_scenario` に `project` / `profile` 引数、`ft_list_projects` 追加。
  ft_run_scenario は 1 シナリオ実行なので profile からはシナリオの platform に合う先頭デバイス・
  heal・reportDir のみ利用(シナリオを書いている途中の確認用。results/・録画・setup/teardown は持たない)
- **MCP は既定で FM と Vision を使わない**(ユーザー決定。Vision のコンパイルも起こさない)。`ft_run_scenario` は
  `MCPServer.withoutFMAndVision`(FM 全体・OCR の段・checkIsON の分類器の優先を切る)、`ft_start_run` は
  `--set` の4キー(run の開始時の `compile-ocr` もこれで起きない。別の機械へも `--set` が届く)と、手元の子へ効く
  `FT_OCCLUSION_OCR=off`・`FT_FIND_IMAGE_PREWARM=off`、`ft_doctor` は実呼び出しを撃たない。findImage の見本の暖機も切る
  (`ScenarioExecutionSettings.findImagePrewarm` → 子へ `--no-find-image-prewarm`)。使うのは `fmAndVision: true` のときだけ。
  切った run の応答には `fmAndVisionOffNote` を添える。`findImage` そのものは切らない(シナリオが明示的に求める。初回に払う)
- MCP の本番の実行: `ft_start_run` / `ft_run_status` / `ft_stop_run`(MCPServer+RunJobs.swift)。
  **エージェントに頼まれた実行の正規の経路**(受け手の AGENTS.md・手引き・スキルが案内する)。理由は
  Codex 等のシェルのサンドボックスで `fleetest run` が通らない(SwiftPM の入れ子の sandbox-exec・
  CoreSimulatorService)のに対し、MCP サーバはその外で動くため(実測: Codex の既定で全部実行 4/4・
  broadcast 9/9 が実行前に失敗 → MCP では通る)
  - **start は即返し、status を引かせる**: MCPServer は1リクエストずつ処理する(長い待ちは他の ft_* を
    止める)+ Codex は MCP の呼び出しを約 60 秒で切る
  - 起こすのは作業フォルダでの `swift run fleetest run …`(`fleetest api run` は --failed / --broadcast /
    --folder を持たない。ランチャーが作るのは fleetest-mcp だけで隣の fleetest は古いことがある)。
    **`swift run` は製品を同じ pid で exec する**(実測)ので、SIGTERM・進捗の台帳(pid 一致)・
    MCP の端末リースの親判定(getppid = MCP サーバ)がそのまま効く
  - 子の出力はパイプで読まずログファイル(`.fleetest/mcp-runs/`)へ。止めるのは SIGTERM だけ・
    このサーバが起こした run だけ・同時に1本
  - `runner` は登録簿の機械名と `local` だけ(生の user@host は断る。承認なしで呼ばれうる MCP から
    未登録の機械へシナリオ・プロファイルを送らない)。`--fleet` は CLI だけ(実行プロファイルと
    併用せず機械ごとに別の run になり、1本を追う start/status の形に載らない)
  - 承認: Codex では `ft_start_run` だけ `approval_mode = "prompt"` を推奨(setup/teardown と別の機械への
    送り出しはこのツールにしか無い)。断られたらシェルで回り道をしない(手引きに明記・Codex と
    Claude Code で実測)
- MCP の集計: `ft_results`(`fleetest results <query>` と同じ文面。表の組み立てと実行ログの収集は
  FTCore の ResultsRendering / ResultsLogReport の1箇所で CLI と共有)

### DS-11.6 移行と後方互換

- 旧 `scenarios/` は `TestProjects/SampleApp/scenarios/` へ git mv(同一コミットでアトミック移行。
  レガシーレイアウトのランタイムサポートは持たない)
- ルート `reports/` の既存成果物は履歴として残置。旧 `.fleetest/heal-cache.json`(2026-09-15 に
  ヒールキャッシュ機構ごと撤去 → MN-22)は放置で無害 —— 現行コードはもう読み書き
  しないので、残っていれば消してよい

---

### DS-11.7 シナリオのサンドボックス(Seatbelt・常に有効)

シナリオ実行バイナリを**常に** `/usr/bin/sandbox-exec -p <プロファイル>` 経由で起こす。外せるのはマシン側の
`~/.config/fleetest/config.json` の `sandbox.disabled` だけ(プロジェクト・実行プロファイル・環境変数からは
緩められない = エージェントが書き換えられる場所に緩める口を置かない)。**縛るのは子とその子孫だけ**で、
fleetest 本体(供給・ビルド・モニター)・MCP サーバ・拡張は包まない。利用者向けの説明は
docs/user-docs/reference/tools/mcp_server_ja.md §サンドボックスと承認。実測した性質・要った許可・調べ方・
踏んだ失敗は [sandbox-seatbelt.md](../sandbox-seatbelt.md)。

**型の分担**(どれも `Sources/FTCore`):

| 型 | 役割 |
|---|---|
| `ScenarioSandbox` | マシン側の設定(`MachineSettings`)→ 計画(`Plan`)→ 範囲(`Scope`)→ プロファイル本文。包むかどうかを決めるのは `plan` の1箇所 |
| `ScenarioHost.sandboxedLaunch` | 包む入口。実行(dry-run を含む)・一覧取得(`list`)・OCR のコンパイル(`compile-ocr`)の3経路がここを通る(`ScenarioSandboxWiringTests`) |
| `SandboxBroker` / `BrokerPolicy`(`SimctlPolicy` / `DevicectlPolicy` / `AdbPolicy`)/ `SandboxGateway` | Simulator・iOS 実機・Android の操作の代行(親 / 方針 / 子) |
| `SandboxProxy` / `SandboxDomainPolicy` / `ProxyDestinationPolicy` | 許可ドメインへのプロキシ(名前の照合 → 親で解決 → loopback・自機・内部サブネットを断って数値アドレスへ接続) |

**全拒否が土台**(`(deny default)`)。全許可を土台にして書き込みと通信だけ絞る形は壁にならない ——
実測(PoC)で、その枠の中から `simctl spawn <udid> defaults write <枠の外>` が成功し、`open -a` でアプリが
枠の外に起動した(LaunchServices)。開けるものは `ScenarioSandbox.baseRules` / `machServices` /
`writablePaths` に名指しで並べる。

- **呼び手は何も運ばない**。包む判断は入口の中で完結する(マシン側の設定を読む)ので、MCP・CLI・拡張・
  リモートのランナーはどれも `ScenarioHost` の3関数を呼ぶだけで包まれる。**シナリオ実行バイナリを起こす経路を
  足したら入口を通す**(バイナリは起こし方に関わらず利用者のコードを実行しうる。`_Main.swift` もシナリオの置き場にある)
- **環境変数から枠を緩めさせない**: ホームは `getpwuid`(`HOME` を見ない。偽のホームに `~/.ssh` の拒否を組ませない)・
  設定は `XDG_CONFIG_HOME` を見ずに実ホームの固定パスから読む・子の `TMPDIR` は親の値を継がせず明示する・
  書く場所を差し替える `FT_*_DIR`(`redirectedDirectoryKeys`)は**書ける場所の中を指すときだけ**通し、外なら
  起動前に止める(足す形にすると `~/Library/LaunchAgents` 等を書けるようにできる。新しい `FT_*_DIR` は、この一覧か
  「子が書かない」表のどちらかへ載せるまで `EnvironmentKeyLiteralTests` が落とす)・`FT_TOOL_ROOT` は
  ツール本体の目印(`Runner/FleetestRunner.xcodeproj/project.xcproj`)があるときだけ採る
- **子の環境は許可リストで作る**(`SandboxedLaunch.childEnvironment(base:)` = `ScenarioSandbox.inheritedEnvironment`
  で親の環境を絞ってから入口の分を足す。3経路とも。一覧取得は `/usr/bin/env -i`)。親の環境を継がせると
  `.mcp.json` の `env` やシェルのトークンをシナリオが読める。**子が読む環境変数を足したら許可リストにも足す**
  (`FT_*`・`LC_*` は前方一致で通る。`ScenarioSandboxWiringTests` が配線を固定)
- **`/dev` は名指しの literal と `/dev/fd` だけ書ける**(丸ごと開けると他の端末 `/dev/ttys*` へ書ける)。
  **Simulator のデータコンテナはレーンの UDID が分かればその1台だけ**(`Scope.simulatorUDID`)
- **設定が壊れていたら止める**(`LocalConfig.load` の「壊れていたら空設定」に倒さない。追加した `denyRead` が
  黙って消えた状態で走る)。未知のキーもエラー
- **読み取り**: 内蔵の `defaultDenyReadHomeSubpaths`(認証情報・個人データの定番の置き場。網羅ではない)+
  マシン側の `denyRead`(足すだけ)。`~/.config` は丸ごと閉じ、子が FM の並列枠を読む `~/.config/fleetest/config.json` と
  そのプロジェクトのデータセット(`dataset/<プロジェクト名>/`)だけ読み直しを許す(`ScenarioSandbox.readReopenedPaths`。
  丸ごと開けると別プロジェクトの accounts.json を読めた。リンクになっている段はリンクの位置も許す = `symlinkHopsUnderConfig`。
  書けない = 子は `disabled` を立てられない)。受け手の `.claude/settings.json` には
  `~/.config/fleetest` の Edit deny を書く(`ProjectScaffold.machineConfigEditDeny`)
- **Simulator と iOS 実機の操作は親が代行する**。子はドライバそのものなので CoreSimulator / CoreDevice が要るが、
  繋がせると `simctl spawn` 等で枠の外にプロセスを起こせる。子の `Shell.runRaw` が `xcrun simctl …` /
  `xcrun devicectl …` を unix ソケット越しに親へ送り(`FT_SANDBOX_BROKER`)、親は `BrokerPolicy.check` が
  認めた形だけを実行する。CoreSimulator の直叩き(`FTCoreSimShim`)は `FT_SIMULATOR_CONTROL=simctl` で止める。
  方針が断るもの: 列挙に無い動詞・形、レーン以外のデバイス、`simctl spawn` の固定2形以外、子が書ける場所からの
  `install`、`launch` の環境変数のうち決まった4つ以外とツール本体の `InAppBridge/build/` 以外の
  `DYLD_INSERT_LIBRARIES`、`devicectl --json-output` の書き先が子の書ける場所の外。
  **検めたパスは実体パスに固定して実行する**(`BrokerPolicy.pinned`。子が送った文字列のまま実行すると、途中の symlink を
  検めた後に差し替えられる)。**親は子の書ける場所へ書かない** —— devicectl の出力は親だけの一時ファイルに書かせ、中身を
  応答で返して子が書く。
  **`simctl` / `devicectl` の呼び出しを足したら方針にも足す**(`devicectl` は
  `DevicectlPolicyTests.testEveryDevicectlCallInTheSourcesHasAKnownShape` がソース走査で落とす)
- **Android の操作(adb)も親が代行する**。子が adb サーバへ繋げると `adb shell` で Emulator の中 = 枠の外から
  外部へ出られ、繋がった全端末を操作・読み出せる。子の `Shell.runRaw` が `<…>/adb …` を親へ送り、親は
  `AdbPolicy.check` が認めた形だけを**親自身の adb**(`AdbLocator.adbPath`。子が送ったパスは使わない)で実行する。
  方針が断るもの: 列挙に無い形(`push` / `pull` / `reverse` / `emu` / `reboot` / 任意の `shell` コマンド等)、
  レーン以外の端末(`-s` の無い呼び出しもレーンを持つ run では断る)、パッケージ名・URL・数値の欄が文法を外れる値、
  子が書ける場所からの `install`。枠は adb サーバ(`ANDROID_ADB_SERVER_PORT`、既定 5037)と Emulator の
  コンソール / adbd(5554〜5585)への接続を `localhost:*` の許可より後で拒否し、`~/.android`(adb の鍵)と
  `~/.emulator_console_auth_token` を読ませない。`.apks` のインストール(bundletool は adb サーバへ直に繋ぐ)も
  親が代行する(`BundletoolPolicy`: `install-apks` の1形・絶対パスで子の書けない場所の `.apks`・レーンの端末だけ。
  親自身の bundletool と adb で実行)。マシン側の `allowDirectAdb: true` だけが、子に adb / bundletool を直接使わせる
  (ポートと adb の鍵を開け、子の横取りを止める。プロジェクト・環境変数からは開けない)。**adb の呼び出しを足したら方針にも足す**
  (`AdbPolicyBuilderSyncTests` が組み立ての出力とドライバの定数の呼び出しを表に当てる)
- **書ける場所は `writablePaths` の1箇所**。足すときは「そこに置いた物が枠の外で実行・解釈されないか」を
  先に見る(`<root>/.fleetest/hooks/` は次の run が teardown を実行するので拒否。同じ理由で `DerivedData*`・
  `.inapp` 以外の `bridge-*` 台帳・`~/.fleetest/ftbridge.apk`・`dispatch.lock` / `dispatch.queue` も拒否 =
  `writeDeniedPaths` / `ledgerDenyRegexes`)。**親だけが書く場所も拒否する**(WebView のキャッシュ・掃除のロック・`cleanup.log`・録画の点検・Emulator のログ)。
  子も使う場所へ親が書くときは symlink を辿らない(上書きは atomic・ロックの `open` は `O_NOFOLLOW` = `NoFollowOpenScanTests`)。**根そのものは書かせない**(literal の拒否。親が `prepareWritableRoots` で
  先に作り、symlink なら起動しない —— 根を symlink に差し替えられると次の枠がその先を開ける)。
  **ユーザーの一時領域は子専用のものだけ**(`T/fleetest-sandbox/<実行バイナリ名>/` = 子の `TMPDIR`・`C/<実行バイナリ名>/`・
  `T/TemporaryItems/NSIRD_<実行バイナリ名>_…`・Core ML / Create ML の `T/model_*.mlmodelc`・`T/CreateMLModels/`)。
  子に入るコードは一時領域を `TemporaryDirectory.url` で引く(`NSTemporaryDirectory()` は `TMPDIR` を見ない。
  `TemporaryDirectoryScanTests`)。**OS の部品が書く場所が変わると黙って縮退しうる** —— 分類器は注記
  `vision-classifier-unavailable` とシナリオ末尾の警告で表に出し、e2e.sh はその run を赤にする
  (学習の経路は `--retrain-classifiers`。docs/verification/)親が決めて子に書かせる場所
  (静止画の置き場 `--still-frames-dir`)は `Scope.extraWritable` で渡す(環境変数から作らない)。
  **書けないと黙って効かなくなる型がある**(`FMCallSlots` は取れたことになる)。拒否は E2E 中の `log stream` で拾う
- **子が繋ぐ unix ソケットは名指しで開ける**(親の broker と画像判定の補助プロセス `VisionHelperHost`。
  `Scope.helperSockets`)。補助プロセスを閉じたままにすると、ANE が壊れた機械で画像照合が落ちる。
  **この拒否は `log stream` に出なかった**(失敗文の `connect: errno 1` で気づいた)
- **LaunchServices は読み取り専用の写像 `com.apple.lsd.mapdb` だけ開ける**(Create ML が見本の画像の UTType を
  判定する。閉じると分類器が学習できない)。アプリを起こす `coreservicesd` と登録を書き換える `lsd.modifydb` は閉じる
- **起動できないランナーは包む前に止める**。包むと `sandbox-exec` 自体は起動でき、ランナーの exec の失敗は
  子の終了に化けて失敗の記録が残らない(`ScenarioHostRunnerUnavailableTests`)
- **run の前後のスクリプト(run-setup.sh / run-teardown.sh)も同じ土台で包む**(`Scope.purpose = .script`・入口は `FTCore.ScriptSandbox.launch`・
  呼び手は `fleetest` の `RunHookRunner.runScript` の1箇所)。用途で集合が変わる: 書けるのは `<workspace>/data/` と
  マシン側 `hooks.writablePaths`(`HooksSettings` が scripts/・`.fleetest`・ツール本体・ビルド元・秘密の置き場との重なりを断る)と
  子専用の一時領域 / 通信は宣言した公開ポートと親のプロキシ・gateway のソケットだけ(`localhost:*`・bind・inbound は無し)/
  GPU・ANE・LaunchServices の mach / iokit は開けない。コンテナの操作は中継コマンド `fleetest-services`(exec / logs / status / port)で
  親が代行し、判定は `FTServices.ServicePolicy`(宣言したサービスだけ・ランタイムのオプションは固定)。
  **中継に動詞を足したら `ServicePolicy` と `ServicePolicyTests` にも足す**。詳細は RR-17「スクリプト」
- **Vision / Core ML に要る許可を閉じると、落ちるより先に遅くなる**。IOSurface・GPU・ANE の
  user client と `MTLCompilerService` を閉じた状態では、1 プロファイルが 120 秒 → 1,478 秒になり、
  画像照合は `Failed to create CVPixelBufferPool` / `espresso error: -1` で落ちた
- **通信**: 外向きは localhost と親の broker のソケットだけ。Seatbelt のアドレス条件はホストに `*` か
  `localhost` しか書けないので、ドメイン単位の許可は親のプロキシで行う(`allowedDomains`)。
  Wi-Fi 越しの iOS 実機のブリッジも外向きの穴は開けず、親が `127.0.0.1:<実機のブリッジと同じポート番号>` に
  シナリオごとの中継(`FTCore.BridgeRelay`。`ScenarioHost.run` で配線。実機の LAN の IP・ポートにだけ転送する)を張る。
  子の `BridgeClient` は `.fleetest/bridge-<port>.endpoint` をポート番号で引いてトークンを得るので番号は揃える。
  張れなければシナリオは起動せず理由を記録する
- **書式の罠(実測)**: ①パスは symlink 解決後で照合される(`/var` → `/private/var`)。
  `URL.resolvingSymlinksInPath` は `/private` を剥がすので `realpath` を使う ②`network*` に
  `(local ip "localhost:*")` を書くと外向きの接続が全部通る(向きごとに分けて宛先で絞る)
  ③`localhost` は自機の全アドレスを含む ④unix ソケットへ繋ぐには、名指しの許可に加えて
  そのパスへの書き込みも要る ⑤出力先そのものは作れるが、途中の親ディレクトリは作れない(だから親が先に作る)
  ⑥後に書いた規則が勝つ(閉じた場所の中の開け直しはこれで書く)
- **拒否の調べ方**: `log show` では拾えない。**先に** `/usr/bin/log stream --style compact
  --predicate 'sender == "Sandbox"'` を起こしてから実行する(zsh の `log` は組み込みなのでフルパス)
- **pid は変わらない**(`sandbox-exec` は枠を掛けて exec する)ので、SIGTERM・`ParentDeathWatch`・
  stdin の制御チャネル・拡張のプロセス分類は包まないときと同じ

**壁の外に残るもの**(利用者向けページにも同じ内容を書いてある):

- **localhost のサービス**。子はブリッジと adb へ繋ぐので `localhost:*` を開けている。adb サーバ経由で
  Emulator の shell と、そこからの外部通信に届く。閉じるにはドライバごと親へ移す必要がある
- **デバイスを介した持ち出し**。読めたファイルの中身を、アプリへの入力として送れる
- **テスト対象のアプリ**。Simulator の中のプロセスは枠の外のホストプロセス
- **setup / teardown スクリプトと `Package.swift`**。前者は `ft_start_run` の確認(`ask`)で受け
  (枠に入れてコンテナ(Docker / Apple Container)を宣言へ移す設計は RR-17「サービスの宣言とスクリプトのサンドボックス化」。未実装)、後者は
  SwiftPM 自身のサンドボックスで評価される。`fleetestScenarioDependencies`(DS-11.1)で足した依存のビルド
  (マクロ・ビルドプラグインを含む)も枠の外 = SwiftPM とコンパイラ自身のサンドボックスだけ

## DS-13 実行の相乗りガードと launch 事前検査

デモ凍結事故(ライブモニター稼働中のシムへ外部 run が相乗り→ launch ハング→ 60s watchdog で
ランナー死→ストリーム凍結)の再発防止として2つのガードを入れた。**うち占有ガードは後に撤去した**(13.1)。

### DS-13.1 MonitorLease(占有ガード、B1)は撤去済み

「モニターが見ているデバイスへの外部 run を lease で拒否する」占有ガードを一度入れたが、
**テスト実行をモニターより優先する**方針(ユーザー決定)により全廃した。
`MonitorLease` の実装も `.fleetest/monitor-*.lease` も現在は**存在しない**。
モニターは受動ビューアで、run に割り込まれても respawn で復帰する。**再提案しない**。

run → monitor 方向の `RunLease`(DS-12 の「監視と実行の協調」)は別物で**現役**
(watchdog が実行中デバイスを破壊的に再起動するのを抑える)。混同しないこと。

### DS-13.2 launch 事前検査(LaunchPreflightDriver)

未インストールの bundleID を `XCUIApplication.launch()` すると quiescence 待ちで main queue が
ハングし、60s watchdog でランナーごと死ぬ(XCUITest API はメインスレッド必須のため
サーバ側での非致死化は不可能と確認済み)。

- `launch` 前に `simctl get_app_container <udid> <bundleID>` で導入確認し、未導入は launch を
  呼ばず即時エラーにする(ランナーは生存)。システムアプリも判定可(実測)。確認済み
  bundleID はインスタンス内キャッシュ
- 配線: xcuitest モードのシナリオ実行時、`DriverConnection.udid` が届く場合のみ
  `ScenarioRunnerMain` が BridgeClient をラップ。udid 供給元は ProfileWorkerFactory / MCPServer
- 教訓: 当初「2ランナー競合」を凍結の主犯と推定したが、本番構成の通し run で監視中シムに
  第2ランナーが共存しても凍結しないことを確認。主犯は「未導入 app の launch」

### DS-13.3 ライブ操作(`api live serve`)の宛先決定と門

グリッドビューのライブ操作は常駐 CLI(`ApiLiveServe`。プロトコルは `Sources/fleetest/ApiLiveCommand.swift`
冒頭)で、run / MCP とは別に自分でブリッジへ繋ぎに行く。DS-13.1/13.2 と同じ「相乗り・未導入 launch」の
危険がここにも及ぶことが実地で分かったので、判定は既存の1箇所へ寄せた。

**(0a) 観測の最中の操作は捨てずに後で撃つ**: 画面の撮り直し(整定の撮り直し・グリッドビューの絵の変化・「更新」)と一覧の
取り直しは画面を変えない観測で、host は `busy` に `observing: true` を載せる(`MonitorLiveController.busyObserving`)。webview
(グリッドビュー)はこの間の画面の操作とデバイスを操作するボタンを捨てずに送り、host の `runGridAction` が
観測の終わりを待って撃つ(`OBSERVATION_DEFERRABLE_ACTIONS`。`handleGridAction` は切り替えや座標の操作の前にも待つ)。撮り直しは
操作の結果のたびに走る(1回 約 0.4 秒)ので、捨てていた頃は止まった画面へのタップが黙って空振りした(実地)。操作の最中(`runAction` =
observing なし)は従来どおり受け付けない(画面が変わる最中)。まだ撃っていない操作を後で撃つだけ = 撃ち直しではない。

**(0) 実行中も操作を止めない**: グリッドビューは DS-12.6 のとおり、選択中のデバイスがシナリオを回している間も
操作を受け付ける(利用者の自己責任。止めるのは整定のための自動の撮り直しだけ)。

**(0b) run 中の人の操作の台帳**(`FTCore.HumanOperationLedger`): run の実行中に人がライブ操作で触った事実を、
そのときそのデバイスで回っていたシナリオの結果へ時刻つきで残す(介入が原因の赤をアプリの不具合に見せない。
**分類はしない・事実だけ**)。契約:
- **置き場** `<RepoRoot>/.fleetest/human-ops/<UDID または adb serial>.ndjson`(鍵は run-lease と同じ)。
  1行 = `{"at"(ISO 8601・UTC・ミリ秒), "label", "ok"}`。リモートのランナー機では serve も run も同じ workDir で動くので同じ置き場
- **書き手は run がそのデバイスを使用中のときの serve だけ**(`RunLease.holderPID` が自分以外の生きた pid。判定は
  `LiveHumanOperation.shouldRecord`)。普段のライブ操作では台帳を育てない。操作の成否を問わず撃ち始めの時刻で1件
  (`ApiLiveServe.handle`)。**入力した文字列は残さない**(`type` は文字数だけ。`LiveHumanOperation.label`)。
  ref の要素名は直近の観測の表(`LiveScreenMemo.names`)から引く —— 操作の前に木を撮り直すと ref の番号を動かすので撮らない
- **読み手は `ScenarioHost.run` の確定点3つ**(起動前の失敗・タイムアウト・通常終了)。窓 [`startedAt`, 確定] の行を結果の
  `humanOperations` へ載せ(空なら欄ごと省く。Optional で足したので版は上げない)、通常終了では子が書いた Markdown レポートの末尾に
  `## Human operations` 節も足す(`HumanOperationReport`)。引くのは `ScenarioRecording.humanOperationsStateDir`(FTCore は `RepoRoot` を
  呼べないので呼び手が `HumanOperationStateDir.current` を渡す。渡し忘れは `HumanOperationWiringTests` が落とす)
- **保持** 24 時間(`retentionSeconds`)。追記のついでに古い行を flock の内側で間引き、一時ファイルから rename で書き直す
- **子に偽造させない**: `ScenarioSandbox.writeDeniedPaths` に `human-ops` がある

**(a) 宛先の本人確認**: `XCUIBridgeResolver.resolve` が返した宛先は `FTCore.BridgeIdentityCheck`
(F8b・2026-09-15。run 側の `RunOrchestrator.bridgeUnreachable` 再プローブと同じ判定)で `--udid` と
突き合わせる(inapp モードの in-app ブリッジ側は別ポート = 別ブリッジなので `composeDriver` がそちらも別に
確認する)。以前ライブ操作にはこの確認が無く、実害が出た(実地 2026-09-22): `api live serve
--udid <デバイスA>` を `--port` なしで起こすと既定 8123 に居た**別のデバイスのブリッジ**を掴み、
`actionResult.app` が別のデバイスで動いていたアプリを返した(操作もそちらへ飛んだ)。さらに
`LiveBridgeAutoStarter.checkAndRestartIfStale` がその**別のデバイスのブリッジを「旧版」として止め、
デバイスA の udid で同じポートに起動し直そうとした** —— 健全なブリッジが2本消えた。

不一致の扱いは**`--port` の明示/既定で分ける**(`DriverOptions.port` は `UInt16?` なので区別できる。
`BridgeDiscovery` の「`port:` を明示した呼び出しでは探索しない —— 宛先を利用者が決めているため」と
同じ切り分け):

- **`--port` 明示** → 断る(`DriverError.bridgeIdentityMismatch`。利用者が決めた宛先を勝手に変えない)
- **既定 8123 へのフォールバック** → 断らない。`BridgeDiscovery.scan` の `Found.udid` からその udid の
  ポートを探して乗り換え、見つからなければ**占有中の既定ポートには触れず**
  `XCUIBridgeResolver.freePort`(F8 と同じ台帳を見る採番。ライブ操作向けに public 化)で
  空きポートへ向け、最初の操作で自然に接続拒否 → `LiveBridgeAutoStarter` が新しいブリッジを起動する。
  **なぜ断ってはいけないか**: 拡張は port が分かるときだけ `--port` を渡す
  (`vscode-fleetest/src/liveModel.ts` の `buildDeviceArgs`)ので、**ブリッジのまだ無いデバイスをライブ操作で
  開く**場面では必ず既定にフォールバックする。そこで断ると、自動起動が想定しているまさにその場面で
  ライブ操作が開けなくなる
- **応答が無いとき(`PortIdentity.silent`)は「このデバイスのブリッジ」と読まない**(2026-09-23 に
  3値化。それまでは `/status` が答えなければ nil = 一致に畳んでいた)。ただし **busy は正常**
  —— 駆動中の XCUITest は `/status` に答えないので、単に「待受している」を根拠に他人扱いすると、
  自分の busy なブリッジを見捨てて同じデバイスに2本目のランナーを立ててしまう。判定は
  `/status` の代わりに**プロセスの実体**(`PortHolder.isHeldByAnotherDevice`。lsof → ps の
  コマンド行に出る UDID)で行い、**肯定的に別のデバイスと読めたときだけ**上の不一致と同じ扱いに
  落とす。**占有者を読めるのはループバックの宛先だけ**(`endpoint.isLoopback`)—— 実機の LAN bind
  (`FT_BIND_ALL`)は向こうの機械のポートなので、こちらの lsof が同じ番号で見つけるのは無関係な
  プロセス。読めない相手を根拠に宛先を変えない。畳んだままだと、別のデバイスのブリッジが居るポートを宛先に採り、その後の自動起動が
  そこへ自分のブリッジを立てて**占有者の生きたランナーを残骸として殺す**
  (実地 2026-09-23: 既定ポート 8123 で実機2台が殺し合った。MN-46.1/MN-46.3)。
  `--port` 明示の宛先は従来どおり素通し(利用者の指定を勝手に変えない)で、inapp モードの in-app ブリッジ側
  (`composeDriver`)も素通し —— in-app は背面へ回ると答えないので、ここで断ると通常の遷移で
  serve が開けなくなる
- `checkAndRestartIfStale`(DS-12.2 の自己修復と同系統だが、ライブ操作の宛先だけを見る)も
  **本人確認が取れた相手にだけ**版差の再起動を掛ける

**(b) launch / activate の門**: 判定は `FTBridgeClient.InstalledAppCheck.launchGuard` の1箇所で、
**MCP の `ft_launch`(判定材料は `installedVerdict` が集めて渡す)とライブ操作が共有**する
(「判定は1箇所・文言は呼び手ごと」)。**2026-09-22 まで MCP の `MCPServer.launchGuardDecision` は
同じ判定をこの関数の中に別実装で持っていた** —— 今は関数名はそのままに中身を
`InstalledAppCheck.launchGuard` への委譲へ差し替え、MCP 向けの文言(ft_install を指す等)を
組むだけにした。以前ライブ操作には門が無く、`{"cmd":"activate","bundle":""}` や
`{"cmd":"launch","bundle":"no.such.app.live"}` で**そのコマンドが30秒刺さり、
"A single command stalled for over 30s — force-quitting (command watchdog)" で serve が落ち、
再起動時に健全なランナーまで掃除して起動し直しになった**(実地 2026-09-22。`XCUIApplication` は
実在しない bundleID で返ってこない)。素通ししてよいのは Android と in-app ブリッジ(ランナーが
死なない経路)だけで、`com.apple.springboard` は門の外 —— DS-13.2/MCP と同じ切り分け
(`InstalledAppCheck.launchGuard`)。own app(inapp モードで in-app ブリッジが既に繋がっているアプリ)への
launch/activate はライブ操作側で門より前に素通しする(in-app は XCUITest を経由しないので
未導入検査そのものが要らない)。

**(c) NDJSON の型違いは黙殺しない**: プロトコルは「壊れた行(JSON でない・`cmd` が無い)は stderr に
1行ログして無視する」だが、**`cmd` が読めて値の型だけが違う行は黙殺しない** ——
`{"kind":"actionResult","ok":false,"error":"<欄> must be …"}` を返す(文言は MCP の
`intArgument`/`doubleArgument` と揃える)。以前は `ApiLiveServeCommand` を型付き `Decodable` で
組んでいたため1フィールドでも型が違うと decode 全体が失敗し、`cmd` さえ読めていた行も「JSON で
ない」行と見分けが付かず無応答のまま黙殺していた(実地 2026-09-22: `{"cmd":"pinch","scale":"2"}`
が無反応 → 拡張の `SERVE_REQUEST_TIMEOUT` で serve ごと再起動。原因は stderr にしか出ない)。
対策は `[String: Any]` から手で組み、cmd 以外の型違いを1件目だけ `decodeError` に残して
`handle` が `actionResult(ok:false)` で答える形にした。**答えは正常時と同じ終端イベントまで出す**
(frame は `frame(ok:false)` の1行だけ、他は `actionResult(ok:false)` → 観測 = snapshot。操作は撃たない)。
拡張は actionResult を保持して次の snapshot/frame で要求を解決するので、actionResult だけで終えると
結局 20 秒待って serve を起動し直す(実地 2026-09-24。MN-49.6)。

## DS-14 実行結果のファイルベース DB

シナリオ実行結果を git 管理下の `TestProjects/<name>/results/` に蓄積し、分散チーム(複数マシン・
複数ブランチ)の結果をコミット・マージで合流させる。サーバ DB は使わない。

### DS-14.1 マージ安全性(設計の核)

**1 run = 1 ディレクトリ、1 シナリオ実行 = 1 ファイルの追加専用レイアウト**。
runID = `<yyyyMMdd-HHmmss(UTC)>Z-<乱数8hex>`(マシン名は埋めない。埋めたホスト名が表示へ
漏れ続けるため 2026-09-01 に撤去し、代わりに乱数を 4hex→8hex(2^32)へ広げて衝突を避ける。
どの機械の run かは記録の `host` 欄が持つ)をディレクトリ名にするため、異なる実行は必ず
別パスに書き、git 上は常に純粋な追加になる(同一秒の二重起動も乱数で分離)。JSONL 追記型は
同一ファイルへの複数ブランチ追記で必ず衝突するため不採用。

検証済み(2026-07-17): 2 ブランチで同一シナリオ集合を同時刻に実行→マージで、
コンフリクトゼロ・全 run が合流・`fleetest results list` が統合結果を返すことを確認。

- レイアウト: `results/runs/<YYYY-MM>/<runID>/run.json + scenarios/<シナリオID>.json`
  (月別シャーディングで走査範囲を限定。間引きは月ディレクトリごと git rm)
- run.json のみ実行完了時に同一プロセスが 1 回上書き(finishedAt・集計)。finishedAt 欠落=
  未完了 run(クラッシュ検出に利用)。scenarios/ は追加専用(同一 run 内の再実行は `~2` 連番)
- スキーマ詳細・フィールド一覧は **docs/results-json.md**(唯一の定義元。DTO は `RunRecord.swift`)。
  **`results/` は .gitignore なので、その中に置いた README は受け手に届かない**
  (2026-08-20 まで design/ はそこを指していた)。ドキュメントは docs/ に置く
- **自動クローズの抑止は `StepExecutor.handlersSuppressed` の1箇所で判定する**(2026-08-21)。
  ブロック形(`handlerSuppressionDepth`)と命令形(`handlersDisabled`)を**別に持つ**のは、
  ブロック形が**1つの CAE ブロックの内側にしか置けない**ため —— 「`condition` で止めて
  `expectation` で戻す」は命令形でしか書けない。`enableHandler()` はブロック形を解除しない
  (ブロックは出口で必ず戻るので、内側から外すと入れ子の意味が壊れる)
- **宣言された割り込みを閉じるのは `StepExecutor.dismissInterruption` の1箇所**(2026-08-20)。
  `perform` を通らない条件判定(`ifCanSelect` / `repeatWhileCanSelect` = `FTDriveCore.canSelect`)は
  `dismissDeclaredInterruption(in:)` から**同じ実装**を呼ぶ。**2つ目の実装を書かない** ——
  判定が割れると「操作は閉じるのに条件判定は閉じない」という、失敗ではなく**誤った経路**として
  現れる形になる(受け手が実際に踏んだ)。条件判定は**1回を1ステップとして数え直す**
  (`beginInterruptionScope`)—— 直前のステップが上限まで閉じていると1回も閉じられない
- **失敗の素性は事実だけ**(2026-08-20): `failedSteps` に `section`(フェーズ)・`command`・
  `failureKind`(`StepFailureKind`)・`notes` を載せ、run.json に `workerAnomalies` を載せる。
  **「環境要因の失敗」の分類は置かない** —— アプリが重いのかマシンが混んでいるのかツールには
  区別できず、推測を混ぜると誤った緑・誤った赤を作る(受け手の方針。仕分けは読み手が行う)。
  `command` は**説明文から切り出さない**(group の前置・注記の括弧書きが付くので、書式を
  変えた瞬間に静かに壊れる)。渡し忘れはコンパイルも実行も通るので
  `CommandNamePlumbingTests` がソース走査で落とす

### DS-14.2 記録パス

全実行経路(api run 直列/プロファイル/並列、fleetest run 直列/並列/ProfileRunner)は
`ScenarioHost.run` に合流するため、レコード生成フックはそこ 1 点
(`ScenarioEvent` 列を `ScenarioRecordBuilder` で畳み込み)。run 単位のメタ(runID・プロファイル・
trigger)は CLI エントリでしか分からないため、`RunRecorder` を CLI エントリで生成して注入する。

- 実装: `Sources/FTCore/RunRecord.swift`(DTO+Builder)/ `RunResultsStore.swift`(I/O・月別走査)/
  `RunRecorder.swift`(発番・NSLock 直列化)。書き込みは全て best-effort(実行を止めない)
- dry-run・debug 実行は記録しない(last-results と同判断)。fleetest-scenarios 直叩き・MCP 経路は対象外
- レコード粒度: 成否・所要時間・worker・scene 別合否は常時、ステップ詳細・fixSuggestions・
  errorLogs(インフラ失敗の切り分け用)は失敗時のみ。スクリーンショットは含めない
  (reports/ への相対パス参照のみ。reports/ は gitignore のまま)

### DS-14.3 分析

- 集計は `Sources/FTCore/RunResultsQuery.swift` の純関数に集約(閾値定数も同ファイル冒頭)。
  CLI(`fleetest results list/summary/flaky/trend/devices/slow/insights/log/response`)と
  拡張向け `fleetest api results`(1 行 JSON)の両方がこれを使う
- ダッシュボード: デバイスモニターの「ダッシュボード」タブ
  (`vscode-fleetest/src/monitorDashboardController.ts` + `src/webview/dashboard/`。
  単独パネル `dashboardPanel.ts` は 2026-09-01 にこのタブへ統合して撤去した)。
  ペイロード契約は `ApiResultsCommand.swift` ⇔ `dashboardModel.ts` で同期
- スキーマ進化: 全ファイルに schemaVersion。フィールド追加は Optional でバージョン据え置き、
  読み側は自分より新しい version をスキップ。既存ファイルの書き換えマイグレーションは
  しない(git 履歴とマージ安全性を壊すため)
- `fleetest api results` の出力キャッシュと `RunRecordPack` がある(契約・無効化の条件は docs/results-json.md が唯一の定義元)

## DS-15 外部パッケージ配布と mint 配布の履歴

**現状(正典)**: onboarding の既定は**外部パッケージ構成**(受け手ディレクトリを `fleetest init` で
テストパッケージ化し、Projects は受け手側に住む。foundation-tester は横に clone した「ツール」=
TOOL_ROOT)。clone 構成(クローンの中で直接シナリオを管理)は保守者/PoC 向け。入口は**全エージェント共通の
プロンプト導入**(「<リポジトリ> を隣に clone して ../foundation-tester/.claude/skills/fleetest-setup/SKILL.md に
従ってセットアップして」)。エージェントはクローンの SKILL.md を読み、クローンの `Scripts/install.sh` を実行する。
Claude Code のスキル(`/fleetest-scenario` 等。名前空間なし)は install.sh のステップ7.8 が作業フォルダの
`.claude/skills/` へ**コピー**する(リンクにしない)。プラグイン配布と curl 取得の導入器は廃止した
(MN-2.3)。`/fleetest-setup` が構成を自動判定し、受け手ディレクトリは
外部構成へ分岐、クローン内は clone 構成。CLI・VSCode 拡張とも TOOL_ROOT の clone から `swift build` /
`npm run install-local` でビルドする(バイナリ配布はしない)。mint は廃止(VSIX はバイナリ配布しないため
clone がどのみち必須で、CLI だけ mint 経由にすると二重取得になるだけだったため)。

**配布の方針(2026-08-27。インストーラが面倒を見るのは Claude Code だけ)**: 導入
runbook の正典は `.claude/skills/<name>/SKILL.md`(ツール中立の markdown 手順書。特定エージェント
専用機能に依存させない)。**runbook 本体は複製しない** —— 正典はクローンの1箇所で、Claude Code 用の
コピーだけを install.sh が作業フォルダへ置く:

| | Claude Code |
|---|---|
| 正典スキル | `<TOOL_ROOT>/.claude/skills/`(実体) |
| 作業フォルダのスキル | `<WORK_DIR>/.claude/skills/`(install.sh ステップ7.8 のコピー。`fleetest-setup` は除く) |
| スキルの呼び出し | `/fleetest-setup` |
| 入口ファイル | `CLAUDE.md`(`@AGENTS.md` を読み込むだけ) |
| MCP 登録 | `.mcp.json`(プロジェクト) |
| コマンド単位の承認 allowlist | `.claude/settings.json` |

**他のエージェント(Codex・Cline・Cursor 等)には配布アダプタを置かない**(2026-08-27 に Codex の
アダプタ一式を撤去)。中核はどれもエージェント固有ではない —— 機械作業はインストーラ、`ft_*` は
標準の stdio MCP サーバ、runbook はツール中立の markdown。**エージェントごとに面倒を見ると、
規約位置・サブコマンド名・版照合の方法・設定ファイルの書式が全部そのエージェント
固有の分岐になり、増やすたびに複数箇所(Swift・install.sh・update.sh)へ手で
写す**ことになる。案内は docs/user-docs/reference/tools/other_agents.md に集約し、コードは
Claude Code の1系統だけを持つ。**受け手のグローバル設定(`~/.codex/config.toml` 等)には
1バイトも書かない** —— セキュリティ境界であり、TOML は同じテーブルの重複でファイル全体が
無効になるので、素朴な追記は受け手の設定を壊す。

規約位置の唯一の定義元は `Sources/FTCore/AgentIntegration.swift`。**install.sh は clone 前・
ビルド前に走るので Swift を呼べず、同じ規則を手で持つ** ——
`vscode-fleetest/test/agentIntegration.test.mjs` が両者のドリフトを落とし、
「インストーラが他エージェントの規約位置・設定へ書かない」ことも同じテストが固定する。
`agentAdapters.test.mjs` は廃止した配布口(プラグイン・curl 取得)の復活と、リポジトリ直下の
`.mcp.json` を落とす。**正典をシンボリックリンクにしない**(理由は MN-2.4)。

**Codex を使う受け手への案内(コードは持たない)**: サンドボックスに**縛られるのはシェル
コマンドだけで、MCP サーバはその外で動く**(2026-08-27 実測: `--sandbox read-only` でも MCP
プロセスはワークスペース外書込と loopback が通る)。したがって **`ft_*` 経由の作成・実行・
デバイス駆動は既定設定のまま動き**、通らないのは**シェル経由の導入・更新**だけ。原因は権限では
ない2つ: **①SwiftPM が自前の `sandbox-exec` を入れ子に使うため `swift build` / `swift package` が
`sandbox_apply: Operation not permitted` で起動できない ②`xcrun simctl` が CoreSimulatorService への
mach 接続を塞がれる**(`adb` は TCP 5037 なので network_access で通る)。
**`network_access` / `writable_roots` を積んでも直らない**ので、それらを根拠に「OK」と言うと
false green になる(以前 install.sh のステップ7.7 が実際に出していた)。

**ブランチの手順書を受け手経路で検証する**: そのブランチをチェックアウトしたクローンの SKILL.md を
エージェントに読ませ、そのクローンの `Scripts/` を使う(`FLEETEST_REF=<ブランチ>` は未クローンの clone 先を
そのブランチに揃える保守者の口。受け手には案内しない。指定すると `fleetest.channel` が外れる)。
以下は外部パッケージ構成(`fleetest init`)の実装詳細。

受け手が foundation-tester を clone せず、**自分の Swift パッケージが fleetest を SPM 依存として引いて**
自分のアプリのシナリオを書ける構成(以下「外部パッケージ構成」)。clone してその中でシナリオを管理する構成を「clone 構成」と呼ぶ。

- **公開 products**: `Package.swift` の `products:` に `.library`(FTScenarioRunner / FTDSL / FTCore)と
  `.executable`(fleetest)。受け手のシナリオターゲットはこれを `.product(package: "foundation-tester")` で引く。
- **`fleetest init`**: 受け手の Package.swift(空マーカー区間 + fleetest 依存。言語モードは tools-version 6.0 の既定 = Swift 6)を書き、
  `ProjectScaffold.createAndRegister` が最初のプロジェクトを登録。**`--no-project` ではプロジェクトを作らず空の
  `TestProjects/` だけ置く**(`fleetest.project` も `.vscode/settings.json` に書かない・受け手スキルも名前を焼かない。
  install.sh は `--name` 無しの新規導入でこちらを使い、プロジェクト `default` は `/fleetest-profiles` か VSCode 拡張が後から作る。
  `--name` ありの導入 = リモートランナーは従来どおり)。内外は `isExternalPackage`
  (`Sources/FTScenarioRunner` の有無)で自動判定し、`PackageManifestEditor` が内部=target 参照 /
  外部=`.product` 参照のスタンザを生成する(`project sync` も同じ判定)。
- **repoRoot の二役分離**: シナリオビルドは `ScenarioHost.packageRoot()`(= 受け手パッケージ。Package.swift
  のみ上方探索。`FT_PACKAGE_ROOT` で明示指定可)。ブリッジ資産(`Runner/`・`InAppBridge/`)は
  `RepoRoot.find()`。後者の解決順は ⓪ `FT_TOOL_ROOT`(明示指定。無効なら探索へ落とさず失敗)
  ① 実行ディレクトリ上方の Package.swift+Runner/(clone 構成)② 受け手パッケージの `.build/checkouts/*/Runner/`
  (外部パッケージ構成の git 依存。swift build が展開・CLI の導入方法に依らず永続)③ 実行中バイナリの位置
  (`<TOOL_ROOT>/.build/debug/fleetest-mcp` 等。cwd が受け手パッケージに固定される MCP・path 依存で
  checkouts が無い構成はここ)④ `#filePath` からのツールソース(自前ビルド)。
  **受け手パッケージのルートを渡してはいけない**(実害: MCP の profile 経路が `packageRoot()` を
  BridgeProvisioner へ渡しており、外部パッケージ構成で `InAppBridge/build.sh` が無く全 `ft_*` が
  失敗した)。両ルートの解決結果は `fleetest doctor --roots-only`(FM 判定に依存しない独立ゲート・
  ツール本体を解決できなければ exit 1)と `fleetest doctor` が表示する。
- **mint 配布(採用していたが廃止)**: `mint install wave1008/foundation-tester@<ver>`。**罠(記録)**: mint は
  temp でビルドしてバイナリのみ残しソースを消すため CLI の `#filePath` は死ぬ → ブリッジは上記②(受け手の
  checkout)で解決する必要があった。よって外部パッケージ構成は **git 依存必須**(ブリッジ用に Runner/ を含む
  checkout が要る)。ソース無し mint バイナリで bridge up→/status ready を実機実証済みだったが、CLI/VSIX の
  二重取得の無駄から mint 自体を廃止(現状は上記「正典」参照)。**制約(継続)**: XCUITest ブリッジは SPM
  ライブラリ化できないため「ソースビルド配布」前提(prebuilt をソースの無い別マシンへ運ぶと Runner/ 解決不能)。
- **拡張**: `binaryPath` は実在しなければ PATH フォールバック(`binaryPathResolve.ts`)で外部パッケージ構成の
  CLI(自前ビルドの PATH 登録先)を発見する。
- **版**: git タグ(受け手の配布口)/ 拡張 package.json / プロトコル版(compatCheck)は独立。リリースは
  `Scripts/release.sh <version> --notes-file <path>`(docs/releasing.md)。**受け手の配布口は最新リリースタグ**
  (`X.Y.Z` の semver 最大・注釈 = リリースノート)で、`main` は開発線。外部構成のクローンは最新タグに detached で置かれ、
  `.git/config` の `fleetest.channel=release` で記録される(install.sh / update.sh が毎回揃える)。
  SKILL.md ステップ0 の最初の `install.sh --align-release-only` が、clone 直後の `main` を最新リリースへ移して
  手順書を読み直させる(手順書・スクリプト・ビルドを同じリリースに揃える)。clone 構成はブランチ追従・
  channel 未設定の detached は `pinned` で動かさない(`update-check.sh` の `channel=`)。
  版を固定する導線は受け手に案内しない。`FLEETEST_REF` は保守者のブランチ検証・退避の口で、指定すると channel は外れる(タグ・SHA を渡したクローンは以後 pinned として留まる。ブランチは外部構成では次の `FLEETEST_REF` 無しの実行で最新リリースへ戻るので、検証中は毎回渡す)。
